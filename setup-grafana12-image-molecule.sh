#!/bin/bash
# setup-grafana12-image-molecule.sh - run as the ansible user on ansible-forge.
# Creates the Molecule scenario "grafana12-image" in configure_grafana_stack and its runner.
# The scenario stages the role's config (same converge as grafana12), then starts the newest saved weekly
# Prometheus and Grafana images on that config, set up like docker-compose.yml, and checks Grafana through its API.
set -euo pipefail
ROLE=/opt/ansible/nucleus/roles/configure_grafana_stack
SC="$ROLE/molecule/grafana12-image"
SRC="$ROLE/molecule/grafana12"
RUN=/opt/ansible/molecule/run-grafana12-image.sh
[ "$(id -un)" = "ansible" ] || { echo "Run as the ansible user"; exit 1; }
[ -f "$SRC/converge.yml" ] || { echo "Run setup-grafana12-molecule.sh first ($SRC missing)"; exit 1; }
mkdir -p "$SC" /opt/ansible/molecule/logs /opt/ansible/molecule/cache /opt/ansible/molecule/scratch/containers

cp "$SRC/converge.yml" "$SRC/Dockerfile.j2" "$SC/"

cat > "$SC/molecule.yml" <<'EOF'
---
prerun: false
# Same helper container as grafana12, but /var/lib/containers is a host folder, so the Grafana and Prometheus
# containers started by verify.yml can mount the files the role wrote (exactly like production does).
driver:
  name: docker
platforms:
  - name: std1
    groups:
      - grafana
    image: "${MOL_BASE_IMAGE:-debian:trixie}"
    dockerfile: Dockerfile.j2
    pre_build_image: false
    command: sleep infinity
    volumes:
      - /opt/ansible/molecule/scratch/containers:/var/lib/containers
provisioner:
  name: ansible
  env:
    ANSIBLE_VAULT_PASSWORD_FILE: /home/ansible/vault_pass.txt
    ANSIBLE_HOST_KEY_CHECKING: "false"
verifier:
  name: ansible
scenario:
  name: grafana12-image
  test_sequence:
    - dependency
    - create
    - prepare
    - converge
    - verify
    - destroy
EOF

cat > "$SC/verify.yml" <<'EOF'
---
# Loads the newest saved weekly images (class from MOL_IMAGE_CLASS: nucleus = hardened, ccop = functional),
# starts Prometheus and Grafana the way docker-compose.yml does, and checks what Grafana actually loaded.
- name: Verify the weekly images on the staged config
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    cls: "{{ lookup('env', 'MOL_IMAGE_CLASS') | default('nucleus', true) }}"
    scr: /opt/ansible/molecule/scratch/containers
    files_root: /opt/ansible/files/grafana
    net: mol_grafana_net
    expected_titles:
      - Nucleus Linux Servers
      - Nucleus Windows Servers
      - Nucleus IDRAC Servers
    auth:
      url_username: admin
      url_password: admin
  tasks:
    - name: Find the newest saved Grafana and Prometheus image for this class
      ansible.builtin.shell: "ls -t {{ files_root }}/weekly/*/images/{{ cls }}-{{ item }}-*.tar.gz 2>/dev/null | head -n 1"
      args:
        executable: /bin/bash
      changed_when: false
      loop:
        - grafana
        - prometheus
      register: tars

    - name: Both images must exist
      ansible.builtin.assert:
        that:
          - item.stdout | length > 0
        fail_msg: "No saved {{ item.item }} image for class {{ cls }} under {{ files_root }}/weekly/*/images"
      loop: "{{ tars.results }}"
      loop_control:
        label: "{{ item.item }}"

    - name: Load the images
      ansible.builtin.command: "docker load -i {{ item.stdout }}"
      loop: "{{ tars.results }}"
      loop_control:
        label: "{{ item.stdout }}"
      register: loaded
      changed_when: true

    - name: Work out the image tags
      ansible.builtin.set_fact:
        grafana_img: "{{ (loaded.results[0].stdout | regex_search('Loaded image: (\\S+)', '\\1'))[0] }}"
        prom_img: "{{ (loaded.results[1].stdout | regex_search('Loaded image: (\\S+)', '\\1'))[0] }}"

    - name: Use the production seccomp profile if this host has it
      ansible.builtin.stat:
        path: /usr/share/containers/seccomp.json
      register: seccomp

    - name: Run both images and check Grafana
      block:
        - name: Test network
          ansible.builtin.command: "docker network create {{ net }}"
          changed_when: true

        - name: Start Prometheus
          ansible.builtin.command:
            argv: >-
              {{ ['docker', 'run', '-d', '--name', 'mol-prometheus', '--network', net,
                  '--network-alias', 'prometheus', '--read-only', '--cap-drop', 'ALL',
                  '--security-opt', 'no-new-privileges:true']
                 + (['--security-opt', 'seccomp=/usr/share/containers/seccomp.json'] if seccomp.stat.exists else [])
                 + ['-p', '127.0.0.1::9191',
                    '-v', scr ~ '/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro',
                    '-v', scr ~ '/prometheus/data:/var/prometheus:rw',
                    prom_img,
                    '--config.file=/etc/prometheus/prometheus.yml',
                    '--storage.tsdb.path=/var/prometheus',
                    '--web.listen-address=:9191'] }}
          changed_when: true

        - name: Prometheus port
          ansible.builtin.command: docker port mol-prometheus 9191/tcp
          register: prom_port
          changed_when: false

        - name: Prometheus is ready
          ansible.builtin.uri:
            url: "http://127.0.0.1:{{ (prom_port.stdout_lines[0] | split(':'))[-1] }}/-/ready"
          register: prom_ready
          until: prom_ready.status == 200
          retries: 20
          delay: 3

        - name: Start Grafana
          ansible.builtin.command:
            argv: >-
              {{ ['docker', 'run', '-d', '--name', 'mol-grafana', '--network', net,
                  '--network-alias', 'grafana', '--read-only', '--cap-drop', 'ALL',
                  '--security-opt', 'no-new-privileges:true']
                 + (['--security-opt', 'seccomp=/usr/share/containers/seccomp.json'] if seccomp.stat.exists else [])
                 + ['-p', '127.0.0.1::3000',
                    '-v', scr ~ '/grafana/config/grafana.ini:/etc/grafana/grafana.ini:ro',
                    '-v', scr ~ '/grafana/provisioning:/etc/grafana/provisioning:ro',
                    '-v', scr ~ '/grafana/data:/usr/share/grafana/data:rw',
                    '--tmpfs', '/usr/share/grafana/data/log',
                    '--tmpfs', '/usr/share/grafana/data/plugins',
                    '--tmpfs', '/usr/share/grafana/data/plugins-bundled',
                    '-e', 'GF_PATHS_CONFIG=/etc/grafana/grafana.ini',
                    '-e', 'GF_PATHS_PROVISIONING=/etc/grafana/provisioning',
                    '-e', 'GF_SECURITY_ADMIN_USER=admin',
                    '-e', 'GF_SECURITY_ADMIN_PASSWORD=admin',
                    '-e', 'GF_SECURITY_DISABLE_INITIAL_ADMIN_PASSWORD_CHANGE=true',
                    '-e', 'GF_FEATURE_TOGGLES_provisioningService=true',
                    '-e', 'GF_PROVISIONING_DISABLE_PROVISIONING_DEFAULT_PLUGINS=true',
                    grafana_img] }}
          changed_when: true

        - name: Grafana port
          ansible.builtin.command: docker port mol-grafana 3000/tcp
          register: graf_port
          changed_when: false

        - name: Grafana is healthy
          ansible.builtin.uri:
            url: "http://127.0.0.1:{{ (graf_port.stdout_lines[0] | split(':'))[-1] }}/api/health"
            return_content: true
          register: health
          until: health.status == 200
          retries: 40
          delay: 3

        - name: Ask Grafana what it loaded
          ansible.builtin.uri:
            url: "http://127.0.0.1:{{ (graf_port.stdout_lines[0] | split(':'))[-1] }}{{ item.path }}"
            url_username: "{{ auth.url_username }}"
            url_password: "{{ auth.url_password }}"
            force_basic_auth: true
            return_content: true
          loop:
            - { name: datasources, path: /api/datasources }
            - { name: dashboards, path: /api/search?type=dash-db }
            - { name: alert_rules, path: /api/v1/provisioning/alert-rules }
            - { name: datasource_health, path: /api/datasources/uid/ds-prometheus/health }
          loop_control:
            label: "{{ item.name }}"
          register: api

        - name: Grafana loaded the provisioned datasource, dashboards and alert rules
          ansible.builtin.assert:
            that:
              - health.json.database == 'ok'
              - "'ds-prometheus' in (api.results[0].json | map(attribute='uid') | list)"
              - (expected_titles | difference(api.results[1].json | map(attribute='title') | list)) | length == 0
              - api.results[2].json | length > 0
              - api.results[3].json.status == 'OK'
            fail_msg: >-
              health={{ health.json | default('?') }}
              datasources={{ api.results[0].json | map(attribute='uid') | list }}
              dashboards={{ api.results[1].json | map(attribute='title') | list }}
              alert_rules={{ api.results[2].json | length }}
              datasource_health={{ api.results[3].json | default('?') }}

      rescue:
        - name: Container logs for the failed run
          ansible.builtin.shell: "docker logs --tail 60 {{ item }} 2>&1 || true"
          loop:
            - mol-prometheus
            - mol-grafana
          register: logs
          changed_when: false

        - name: Show the logs
          ansible.builtin.debug:
            msg: "{{ item.stdout_lines }}"
          loop: "{{ logs.results }}"
          loop_control:
            label: "{{ item.item }}"

        - name: Fail the scenario
          ansible.builtin.fail:
            msg: "The weekly images did not come up healthy on the staged config - see the logs above"

      always:
        - name: Remove the test containers and network
          ansible.builtin.shell: "docker rm -f mol-grafana mol-prometheus; docker network rm {{ net }}; true"
          changed_when: true
EOF

cat > "$RUN" <<'EOF'
#!/bin/bash
# run-grafana12-image.sh [nucleus|ccop] - image test of the weekly Grafana + Prometheus images (default: nucleus)
export MOL_IMAGE_CLASS="${1:-nucleus}"
source /opt/ansible/molecule/venv/bin/activate
export XDG_CACHE_HOME=/opt/ansible/molecule/cache
SCR=/opt/ansible/molecule/scratch/containers
mkdir -p "$SCR"
# the folder is written by containers (uid 65532), so clean it with a container too
clean() { docker run --rm -v "$SCR":/s "${MOL_BASE_IMAGE:-debian:trixie}" sh -c 'rm -rf /s/* /s/.[!.]* 2>/dev/null; true'; }
clean
cd /opt/ansible/nucleus/roles/configure_grafana_stack || exit 1
LOG=/opt/ansible/molecule/logs/grafana12-image-$MOL_IMAGE_CLASS-$(date +%F-%H%M).log
molecule test -s grafana12-image 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
clean
echo "log: $LOG (exit $rc)"
exit $rc
EOF
chmod 755 "$RUN"
echo "Created $SC and $RUN"
echo "Run it:  $RUN            (hardened images)"
echo "     or  $RUN ccop       (functional images)"

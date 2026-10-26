#!/bin/bash
# setup-grafana12-image-molecule.sh - run as the ansible user on ansible-forge.
# Creates the Molecule scenario "grafana12-image" in configure_grafana_stack and its runner.
# The scenario stages the role's config (same converge as grafana12), then starts the newest saved weekly
# Prometheus, iDRAC exporter, Grafana and nginx images on that config, set up like docker-compose.yml, and checks each one.
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
# starts the whole stack (Prometheus, iDRAC exporter, Grafana, nginx) the way docker-compose.yml does, on the
# config the role staged, and checks what each one actually did.
- name: Verify the weekly images on the staged config
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    cls: "{{ lookup('env', 'MOL_IMAGE_CLASS') | default('nucleus', true) }}"
    scr: /opt/ansible/molecule/scratch/containers
    files_root: /opt/ansible/files/grafana
    net: mol_grafana_net
    fqdn: std1.pt69.ccop.dev
    nginx_scheme: https
    image_names:
      - grafana
      - prometheus
      - nginx
      - idrac
    expected_titles:
      - Nucleus Linux Servers
      - Nucleus Windows Servers
      - Nucleus IDRAC Servers
    auth:
      url_username: admin
      url_password: admin
  tasks:
    - name: Find the newest saved image of each component for this class
      ansible.builtin.shell: "ls -t {{ files_root }}/weekly/*/images/{{ cls }}-{{ item }}-*.tar.gz 2>/dev/null | head -n 1"
      args:
        executable: /bin/bash
      changed_when: false
      loop: "{{ image_names }}"
      register: tars

    - name: All four images must exist
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
        nginx_img: "{{ (loaded.results[2].stdout | regex_search('Loaded image: (\\S+)', '\\1'))[0] }}"
        idrac_img: "{{ (loaded.results[3].stdout | regex_search('Loaded image: (\\S+)', '\\1'))[0] }}"

    - name: Use the production seccomp profile if this host has it
      ansible.builtin.stat:
        path: /usr/share/containers/seccomp.json
      register: seccomp

    - name: Run the stack and check it
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

        - name: Start the iDRAC exporter
          ansible.builtin.command:
            argv: >-
              {{ ['docker', 'run', '-d', '--name', 'mol-idrac', '--network', net,
                  '--network-alias', 'idrac_exporter', '--read-only', '--cap-drop', 'ALL',
                  '--security-opt', 'no-new-privileges:true']
                 + (['--security-opt', 'seccomp=/usr/share/containers/seccomp.json'] if seccomp.stat.exists else [])
                 + ['-p', '127.0.0.1::9348',
                    '-v', scr ~ '/idrac/idrac.yml:/etc/prometheus/idrac.yml:ro',
                    idrac_img,
                    '-config=/etc/prometheus/idrac.yml'] }}
          changed_when: true

        - name: Prometheus and exporter ports
          ansible.builtin.command: "docker port {{ item.c }} {{ item.p }}/tcp"
          loop:
            - { c: mol-prometheus, p: 9191 }
            - { c: mol-idrac, p: 9348 }
          loop_control:
            label: "{{ item.c }}"
          register: ports1
          changed_when: false

        - name: Prometheus is ready
          ansible.builtin.uri:
            url: "http://127.0.0.1:{{ (ports1.results[0].stdout_lines[0] | split(':'))[-1] }}/-/ready"
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
                    '-e', 'GF_PLUGINS_PREINSTALL_DISABLED=true',
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

        - name: Start nginx
          ansible.builtin.command:
            argv: >-
              {{ ['docker', 'run', '-d', '--name', 'mol-nginx', '--network', net,
                  '--network-alias', 'nginx', '--user', '65532:65532', '--read-only',
                  '--cap-drop', 'ALL', '--cap-add', 'NET_BIND_SERVICE',
                  '--security-opt', 'no-new-privileges:true']
                 + (['--security-opt', 'seccomp=/usr/share/containers/seccomp.json'] if seccomp.stat.exists else [])
                 + ['--tmpfs', '/run:uid=65532,gid=65532,mode=755',
                    '-p', '127.0.0.1::443', '-p', '127.0.0.1::80',
                    '-v', scr ~ '/nginx/nginx.conf:/etc/nginx/nginx.conf:ro',
                    '-v', scr ~ '/nginx/mime.types:/etc/nginx/mime.types:ro',
                    '-v', scr ~ '/nginx/options-ssl-nginx.conf:/etc/nginx/options-ssl-nginx.conf:ro',
                    '-v', scr ~ '/nginx/ssl-dhparams.pem:/etc/nginx/ssl-dhparams.pem:ro',
                    '-v', scr ~ '/nginx/certs:/etc/nginx/certs:ro',
                    '-v', scr ~ '/nginx/conf.d:/etc/nginx/conf.d:ro',
                    '-v', scr ~ '/nginx/nsswitch.conf:/etc/nsswitch.conf:ro',
                    '-v', scr ~ '/nginx/cache:/var/cache/nginx:rw',
                    '-v', scr ~ '/nginx/log:/var/log/nginx:rw',
                    nginx_img] }}
          changed_when: true

        - name: nginx ports
          ansible.builtin.command: "docker port mol-nginx {{ item }}/tcp"
          loop:
            - 443
            - 80
          register: ports2
          changed_when: false

        - name: Reach Grafana through nginx (TLS, certificate and proxy)
          ansible.builtin.uri:
            url: "{{ nginx_scheme }}://127.0.0.1:{{ (ports2.results[0].stdout_lines[0] | split(':'))[-1] }}/api/health"
            headers:
              Host: "{{ fqdn }}"
            validate_certs: false
            return_content: true
          register: via_nginx
          until: via_nginx.status == 200
          retries: 20
          delay: 3

        - name: Ask Prometheus, the exporter and Grafana what they loaded
          ansible.builtin.uri:
            url: "http://127.0.0.1:{{ (item.port | split(':'))[-1] }}{{ item.path }}"
            url_username: "{{ item.user | default(omit) }}"
            url_password: "{{ item.pass | default(omit) }}"
            force_basic_auth: "{{ item.user is defined }}"
            return_content: true
            status_code: "{{ item.ok | default([200]) }}"
          loop:
            - { name: prom_config, port: "{{ ports1.results[0].stdout_lines[0] }}", path: /api/v1/status/config }
            - { name: prom_targets, port: "{{ ports1.results[0].stdout_lines[0] }}", path: /api/v1/targets }
            - { name: idrac_metrics, port: "{{ ports1.results[1].stdout_lines[0] }}", path: /metrics, ok: [200, 400] }
            - { name: datasources, port: "{{ graf_port.stdout_lines[0] }}", path: /api/datasources, user: admin, pass: admin }
            - { name: dashboards, port: "{{ graf_port.stdout_lines[0] }}", path: "/api/search?type=dash-db", user: admin, pass: admin }
            - { name: alert_rules, port: "{{ graf_port.stdout_lines[0] }}", path: /api/v1/provisioning/alert-rules, user: admin, pass: admin }
            - { name: datasource_health, port: "{{ graf_port.stdout_lines[0] }}", path: /api/datasources/uid/ds-prometheus/health, user: admin, pass: admin }
          loop_control:
            label: "{{ item.name }}"
          register: api

        - name: Everything came up and loaded its config
          ansible.builtin.assert:
            that:
              - health.json.database == 'ok'
              - via_nginx.json.database == 'ok'
              - api.results[0].json.status == 'success'
              - api.results[1].json.data.activeTargets | length > 0
              - api.results[2].status == 200 or 'target' in (api.results[2].content | default(''))
              - "'ds-prometheus' in (api.results[3].json | map(attribute='uid') | list)"
              - (expected_titles | difference(api.results[4].json | map(attribute='title') | list)) | length == 0
              - api.results[5].json | length > 0
              - api.results[6].json.status == 'OK'
            fail_msg: >-
              grafana_health={{ health.json | default('?') }}
              via_nginx={{ via_nginx.json | default('?') }}
              prometheus_config={{ api.results[0].json.status | default('?') }}
              prometheus_targets={{ api.results[1].json.data.activeTargets | length | default('?') }}
              idrac_metrics_http={{ api.results[2].status | default('?') }}
              datasources={{ api.results[3].json | map(attribute='uid') | list }}
              dashboards={{ api.results[4].json | map(attribute='title') | list }}
              alert_rules={{ api.results[5].json | length }}
              datasource_health={{ api.results[6].json | default('?') }}

      rescue:
        - name: Container logs for the failed run
          ansible.builtin.shell: "docker logs --tail 40 {{ item }} 2>&1 || true"
          loop:
            - mol-prometheus
            - mol-idrac
            - mol-grafana
            - mol-nginx
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
          ansible.builtin.shell: "docker rm -f mol-nginx mol-grafana mol-idrac mol-prometheus; docker network rm {{ net }}; true"
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

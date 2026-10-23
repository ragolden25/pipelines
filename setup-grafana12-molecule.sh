#!/bin/bash
# setup-grafana12-molecule.sh - run as the ansible user on ansible-forge.
# Creates the Molecule scenario "grafana12" inside configure_grafana_stack and a runner script.
set -euo pipefail
ROLE=/opt/ansible/nucleus/roles/configure_grafana_stack
SC="$ROLE/molecule/grafana12"
RUN=/opt/ansible/molecule/run-grafana12.sh
[ "$(id -un)" = "ansible" ] || { echo "Run as the ansible user"; exit 1; }
[ -d "$ROLE" ] || { echo "Missing $ROLE"; exit 1; }
mkdir -p "$SC" /opt/ansible/molecule/logs /opt/ansible/molecule/cache

cat > "$SC/molecule.yml" <<'EOF'
---
# Grafana 12 scenario: file provisioning (dashboards, datasource, alerting, grafana.ini).
# The instance is named std1 (a key in grafana_fqdns) and sits in the grafana group, like production.
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
provisioner:
  name: ansible
  env:
    ANSIBLE_VAULT_PASSWORD_FILE: /home/ansible/vault_pass.txt
    ANSIBLE_HOST_KEY_CHECKING: "false"
verifier:
  name: ansible
scenario:
  name: grafana12
  # idempotence is left out on purpose: the role re-copies and re-edits the dashboards (jq/sed)
  # on every run, so a second pass always reports changes.
  test_sequence:
    - dependency
    - create
    - prepare
    - converge
    - verify
    - destroy
EOF

cat > "$SC/Dockerfile.j2" <<'EOF'
FROM {{ item.image }}
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 jq ca-certificates \
 && rm -rf /var/lib/apt/lists/*
EOF

cat > "$SC/converge.yml" <<'EOF'
---
# Runs the config half of configure_grafana_stack, in the same order as stage-environment.yml.
# Skipped on purpose (they need a real Docker host / firewalld): container-cleanup, nucleus-images,
# compose-setup, firewall, and the run.sh start-up in main.yml.
- name: Converge
  hosts: grafana
  gather_facts: true
  vars_files:
    - /opt/ansible/vars/master_vars.yml
    - /opt/ansible/vars/vault.yml
  tasks:
    - name: Resolve the current symlink
      ansible.builtin.include_role:
        name: /opt/ansible/nucleus/roles/configure_grafana_stack
        tasks_from: symlink-current.yml

    - name: Load versions and prepare logging
      ansible.builtin.include_role:
        name: /opt/ansible/nucleus/roles/configure_grafana_stack
        tasks_from: versions-and-logging.yml

    - name: Create container directories
      ansible.builtin.include_role:
        name: /opt/ansible/nucleus/roles/configure_grafana_stack
        tasks_from: directory-setup.yml

    - name: Stage Grafana application config
      ansible.builtin.include_role:
        name: /opt/ansible/nucleus/roles/configure_grafana_stack
        tasks_from: grafana-app-config.yml

    - name: Clean and normalize dashboards
      ansible.builtin.include_role:
        name: /opt/ansible/nucleus/roles/configure_grafana_stack
        tasks_from: clean-dashboards.yml

    - name: Fix final post-cleanup file bounds
      ansible.builtin.file:
        path: "/var/lib/containers/grafana/provisioning/dashboards/{{ item }}"
        mode: '0644'
        owner: '65532'
        group: '65532'
      loop:
        - nuc_idrac_dashboard.json
        - nuc_linux_dashboard.json
        - nuc_windows_dashboard.json
EOF

cat > "$SC/verify.yml" <<'EOF'
---
- name: Verify
  hosts: grafana
  gather_facts: false
  vars:
    prov: /var/lib/containers/grafana/provisioning
    dashboards:
      - { file: nuc_linux_dashboard.json, title: "Nucleus Linux Servers" }
      - { file: nuc_windows_dashboard.json, title: "Nucleus Windows Servers" }
      - { file: nuc_idrac_dashboard.json, title: "Nucleus IDRAC Servers" }
    alert_files:
      - contact-points.yml
      - idrac-alerts.yml
      - linux-alerts.yml
      - notification-policies.yml
      - windows-alerts.yml
  tasks:
    - name: Dashboards exist with the right owner and mode
      ansible.builtin.stat:
        path: "{{ prov }}/dashboards/{{ item.file }}"
      loop: "{{ dashboards }}"
      register: dash_stat

    - name: Check dashboard ownership and mode
      ansible.builtin.assert:
        that:
          - item.stat.exists
          - item.stat.uid == 65532
          - item.stat.gid == 65532
          - item.stat.mode == '0644'
        fail_msg: "{{ item.item.file }} missing or wrong owner/mode"
      loop: "{{ dash_stat.results }}"
      loop_control:
        label: "{{ item.item.file }}"

    - name: Read dashboards
      ansible.builtin.slurp:
        src: "{{ prov }}/dashboards/{{ item.file }}"
      loop: "{{ dashboards }}"
      register: dash_data

    - name: Dashboards are valid JSON, retitled, with id/uid stripped and datasource normalized
      ansible.builtin.assert:
        that:
          - (item.content | b64decode | from_json).title == item.item.title
          - "'uid' not in (item.content | b64decode | from_json)"
          - "'id' not in (item.content | b64decode | from_json)"
          - "'DS_PROMETHEUS' not in (item.content | b64decode)"
          - "'ds_prometheus' not in (item.content | b64decode)"
        fail_msg: "{{ item.item.file }} failed content checks"
      loop: "{{ dash_data.results }}"
      loop_control:
        label: "{{ item.item.file }}"

    - name: Read provider, datasource, alerting and grafana.ini
      ansible.builtin.slurp:
        src: "{{ item }}"
      loop:
        - "{{ prov }}/dashboards/default.yml"
        - "{{ prov }}/datasources/prometheus.yml"
        - "/var/lib/containers/grafana/config/grafana.ini"
      register: cfg

    - name: Provider and datasource are valid YAML, ini has no template leftovers
      ansible.builtin.assert:
        that:
          - (cfg.results[0].content | b64decode | from_yaml).providers is defined
          - (cfg.results[1].content | b64decode | from_yaml).datasources | length > 0
          - "'{{' not in (cfg.results[1].content | b64decode)"
          - (cfg.results[2].content | b64decode | length) > 0
          - "'{{' not in (cfg.results[2].content | b64decode)"
          - "'{%' not in (cfg.results[2].content | b64decode)"

    - name: Read alerting files
      ansible.builtin.slurp:
        src: "{{ prov }}/alerting/{{ item }}"
      loop: "{{ alert_files }}"
      register: alerts

    - name: Alerting files are valid YAML
      ansible.builtin.assert:
        that:
          - (item.content | b64decode | from_yaml) is mapping
        fail_msg: "{{ item.item }} is not valid YAML"
      loop: "{{ alerts.results }}"
      loop_control:
        label: "{{ item.item }}"
EOF

cat > "$RUN" <<'EOF'
#!/bin/bash
# run-grafana12.sh - run the grafana12 Molecule scenario; log in /opt/ansible/molecule/logs
source /opt/ansible/molecule/venv/bin/activate
export XDG_CACHE_HOME=/opt/ansible/molecule/cache
cd /opt/ansible/nucleus/roles/configure_grafana_stack || exit 1
LOG=/opt/ansible/molecule/logs/grafana12-$(date +%F-%H%M).log
molecule test -s grafana12 2>&1 | tee "$LOG"
echo "log: $LOG"
EOF
chmod 755 "$RUN"
echo "Created $SC and $RUN"
echo "Run it:  $RUN"

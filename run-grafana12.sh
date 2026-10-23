#!/bin/bash
# run-grafana12.sh - run the grafana12 Molecule scenario; log in /opt/ansible/molecule/logs
source /opt/ansible/molecule/venv/bin/activate
export XDG_CACHE_HOME=/opt/ansible/molecule/cache
cd /opt/ansible/nucleus/roles/configure_grafana_stack || exit 1
LOG=/opt/ansible/molecule/logs/grafana12-$(date +%F-%H%M).log
molecule test -s grafana12 2>&1 | tee "$LOG"
echo "log: $LOG"

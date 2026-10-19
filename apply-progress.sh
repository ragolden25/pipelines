#!/bin/bash
# apply-progress.sh - run as root on ansible-forge. Safe to run more than once.
# 1. Adds a live progress log for the weekly builds:
#      tail -f /opt/ansible/logs/weekly-progress.log
#    one line per step: component, version, and what it is doing (preparing, building ccop/nucleus,
#    scanning ccop/nucleus: SBOM+vulnerability / controls+OpenSCAP / metrics, finished: success|fail)
#    The same lines also appear as task names in the play output.
# 2. Lists files under the staged and current-quarter build directories that the ansible user
#    cannot read because they are owned by root (the idrac failure was
#    "tar: ./inventory.env: Permission denied"). --fix-perms gives those directories to ansible.
#    The weekly build itself keeps running as the ansible user.
# Files replaced are backed up first.
set -uo pipefail
FIXPERMS=0; [ "${1:-}" = "--fix-perms" ] && FIXPERMS=1
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
TS=$(date +%F-%H%M%S)
T=/opt/ansible/nucleus/roles/weekly_common/tasks
BK=/opt/ansible/nucleus/backup-apply-progress-$TS
mkdir -p "$BK"; rc=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
sed -n '1,/^__PAYLOAD__$/!p' "$0" | base64 -d | tar -xzf - -C "$TMP" || { echo "payload extract failed"; exit 1; }

echo "=== 1. Installing progress-log tasks (backups in $BK) ==="
for f in progress.yml build.yml build_image.yml scan_image.yml main.yml; do
  [ -f "$T/$f" ] && cp -p "$T/$f" "$BK/$f"
  if [ -f "$T/$f" ] && cmp -s "$TMP/$f" "$T/$f"; then echo "  unchanged  $f"
  else cp "$TMP/$f" "$T/$f" && echo "  installed  $f"; fi
done

echo "=== 2. Files the ansible user cannot read (cause of the idrac failure) ==="
Q=$(cat /opt/ansible/build/current_quarter 2>/dev/null)
DIRS="/opt/ansible/staged/grafana /opt/ansible/staged/prometheus /opt/ansible/staged/idrac /opt/ansible/staged/postgres"
for d in grafana_stack/grafana grafana_stack/prometheus grafana_stack/idrac grafana_stack/nginx guacamole guacd postgres nginx; do
  [ -n "$Q" ] && DIRS="$DIRS /opt/ansible/build/$d/$Q"
done
BAD=$(for d in $DIRS; do [ -d "$d" ] && find "$d" -mindepth 1 ! -user ansible -not -path '*/node_modules/*' 2>/dev/null; done)
if [ -z "$BAD" ]; then echo "  none - everything is owned by ansible"
else
  echo "  $(echo "$BAD" | wc -l) path(s) not owned by ansible, for example:"
  echo "$BAD" | head -8 | while read -r p; do ls -ld "$p" | sed 's/^/    /'; done
  if [ $FIXPERMS -eq 1 ]; then
    for d in $DIRS; do [ -d "$d" ] && chown -R ansible:ansible "$d"; done && echo "  chown -R ansible:ansible done on those directories"
  else echo "  Re-run with --fix-perms to give those directories to ansible."; fi
fi

echo "=== 3. Syntax check of weekly_builds.yml ==="
if (cd /opt/ansible/nucleus/playbooks && ansible-playbook --syntax-check -i /opt/ansible/vars/inventory.ini \
     --vault-password-file ~/vault_pass.txt weekly_builds.yml >/tmp/syn.$$ 2>&1); then echo "  OK"
else cat /tmp/syn.$$; echo "  SYNTAX CHECK FAILED"; rc=1; fi
rm -f /tmp/syn.$$

echo
echo "Run (as ansible): /opt/ansible/nucleus/playbooks/play_weekly_builds.sh idrac"
echo "Watch:    tail -f /opt/ansible/logs/weekly-progress.log"
echo "Backups:  $BK"
exit $rc
exit
__PAYLOAD__
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

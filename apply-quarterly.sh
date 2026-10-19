#!/bin/bash
# apply-quarterly.sh - run as root on ansible-forge. Safe to run more than once.
#   1. installs /usr/local/bin/emit_quarter_info.sh (embedded in this script)
#   2. runs it once AS THE ANSIBLE USER and shows the metrics it wrote
#   ./apply-quarterly.sh --cron   also adds the daily run to ansible's crontab (07:20)
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
DEST=/usr/local/bin/emit_quarter_info.sh
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
sed -n '1,/^__PAYLOAD__$/!p' "$0" | base64 -d | tar -xzf - -C "$TMP" || { echo "payload extract failed"; exit 1; }
rc=0

echo "=== 1. Installing $DEST ==="
[ -f "$DEST" ] && cp -p "$DEST" "$DEST.bak"
install -m 0755 -o root -g root "$TMP/emit_quarter_info.sh" "$DEST" && echo "  installed"

echo "=== 2. Running it as the ansible user ==="
sudo -u ansible "$DEST" || { echo "  FAILED to run"; rc=1; }
echo
ls -l /var/lib/node_exporter/textfile/pipeline_quarter_info.prom 2>&1 | sed 's/^/  /'
echo "  (the lines above are what the dashboard will show: quarter_current, quarter_locked_version, quarter_stack_build)"

if [ "${1:-}" = "--cron" ]; then
  echo "=== 3. ansible's crontab ==="
  if crontab -u ansible -l 2>/dev/null | grep -q emit_quarter_info; then echo "  already present"
  else
    (crontab -u ansible -l 2>/dev/null; echo "20 7 * * * $DEST >> /opt/ansible/logs/quarter-info.log 2>&1") | crontab -u ansible - && echo "  added: 20 7 * * *"
  fi
fi
exit $rc
exit
__PAYLOAD__
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

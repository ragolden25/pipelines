#!/bin/bash
# apply-ledger.sh - run as root on ansible-forge. Safe to run more than once.
#   1. installs /usr/local/bin/emit_release_ledger.sh (embedded): now reads the delivered images in
#      /opt/ansible/files/<grafana|avocado>/<quarter>/images/ first, so "what did this quarter release"
#      comes from the images that actually shipped
#   2. runs it and shows what it found for the current quarter
#   ./apply-ledger.sh --cron   also adds the daily run (07:15) to root's crontab if it is missing
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
DEST=/usr/local/bin/emit_release_ledger.sh
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
sed -n '1,/^__PAYLOAD__$/!p' "$0" | base64 -d | tar -xzf - -C "$TMP" || { echo "payload extract failed"; exit 1; }
rc=0

echo "=== 1. Installing $DEST ==="
[ -f "$DEST" ] && cp -p "$DEST" "$DEST.bak" && echo "  (previous version saved as $DEST.bak)"
install -m 0755 -o root -g root "$TMP/emit_release_ledger.sh" "$DEST" && echo "  installed"

echo "=== 2. Running it (current quarter rows) ==="
Q=$(cat /opt/ansible/build/current_quarter 2>/dev/null)
OUT=$("$DEST") || { echo "  FAILED to run"; rc=1; }
echo "$OUT" | grep "quarter=\"$Q\"" | sed -E 's/image="[^"]*",//; s/^release_build_info//' | sed 's/^/  /'
echo "  rows for $Q: $(echo "$OUT" | grep -c "quarter=\"$Q\"")   (not built yet = version \"-\": $(echo "$OUT" | grep "quarter=\"$Q\"" | grep -c 'version="-"'))"
ls -l /var/lib/node_exporter/textfile/release_ledger.prom 2>&1 | sed 's/^/  /'

echo "=== 3. root's crontab ==="
if crontab -l 2>/dev/null | grep -q emit_release_ledger; then echo "  ledger job present:"; crontab -l | grep emit_release_ledger | sed 's/^/    /'
elif [ "${1:-}" = "--cron" ]; then
  (crontab -l 2>/dev/null; echo "15 7 * * * $DEST >> /var/log/release-ledger.log 2>&1") | crontab - && echo "  added: 15 7 * * *"
else echo "  NO ledger job in root's crontab (this is why the QUARTER tables were empty if the run above found nothing before)"; echo "  re-run with --cron to add it"; fi
exit $rc
exit
__PAYLOAD__
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

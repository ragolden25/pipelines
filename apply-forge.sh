#!/bin/bash
# apply-forge.sh - run as root on ansible-forge. Safe to run more than once.
#   ./apply-forge.sh            install the fix files, check them, write a diagnostics report
#   ./apply-forge.sh --run      ... and then run the weekly build for grafana postgres idrac
#   ./apply-forge.sh --cron     ... and add any missing cron entries (weekly builds Thu 02:00,
#                               upstream release check 07:00, release ledger 07:15)
# 1. Backs up then installs the 6 weekly fix files (embedded in this script)
# 2. Syntax-checks the weekly playbook
# 3. Shows, per component, which staged version the weekly role will pick
# 4. Writes a diagnostics report (idrac failure, staged listings) you can send back
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

DO_RUN=0; DO_CRON=0
for a in "$@"; do case $a in --run) DO_RUN=1;; --cron) DO_CRON=1;; *) echo "unknown option $a"; exit 1;; esac; done

TS=$(date +%F-%H%M%S)
R=/opt/ansible/nucleus/roles
PB=/opt/ansible/nucleus/playbooks
BK=/opt/ansible/nucleus/backup-apply-forge-$TS
REPORT=/opt/ansible/logs/weekly-diagnostics-$TS.txt
rc=0

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
sed -n '1,/^__PAYLOAD__$/!p' "$0" | base64 -d | tar -xzf - -C "$TMP" || { echo "payload extract failed"; exit 1; }

echo "=== 1. Installing weekly fix files (backups in $BK) ==="
mkdir -p "$BK"
inst() {  # src dest
  if [ ! -d "$(dirname "$2")" ]; then echo "  MISSING DIR $(dirname "$2")"; rc=1; return; fi
  [ -f "$2" ] && cp -p "$2" "$BK/$(echo "$2" | tr / _)"
  if [ -f "$2" ] && cmp -s "$1" "$2"; then echo "  unchanged  $2"; else cp "$1" "$2" && echo "  installed  $2"; fi
}
for f in detect_staged.yml detect_version.yml prepare.yml; do inst "$TMP/$f" "$R/weekly_common/tasks/$f"; done
for c in grafana prometheus idrac; do inst "$TMP/weekly_build_${c}__defaults_main.yml" "$R/weekly_build_$c/defaults/main.yml"; done
if grep -q detect_staged_one "$R/weekly_common/tasks/detect_staged.yml"; then
  echo "  ERROR: detect_staged.yml still the old version"; rc=1
else echo "  OK: detect_staged.yml is the new version"; fi

echo "=== 2. Syntax check of weekly_builds.yml ==="
if (cd "$PB" && ansible-playbook --syntax-check -i /opt/ansible/vars/inventory.ini \
     --vault-password-file ~/vault_pass.txt weekly_builds.yml >/tmp/syn.$$ 2>&1); then
  echo "  OK"
else cat /tmp/syn.$$; echo "  SYNTAX CHECK FAILED"; rc=1; fi
rm -f /tmp/syn.$$

echo "=== 3. Staged versions the weekly role will use ==="
for c in grafana prometheus idrac postgres; do
  d=/opt/ansible/staged/$c
  v=$(ls -1 "$d" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+' | sort -V | tail -n1)
  if [ -z "$v" ]; then printf '  %-11s no version directory under %s\n' "$c" "$d"; 
  elif [ -d "$d/$v/staged" ]; then printf '  %-11s %s  (staged/ present)\n' "$c" "$v"
  else printf '  %-11s %s  NO staged/ folder - will show "waiting on staging"\n' "$c" "$v"; fi
done

echo "=== 4. Diagnostics report: $REPORT ==="
LOG=$(ls -1t /opt/ansible/logs/weekly_builds-*.log 2>/dev/null | head -1)
{
  echo "# weekly diagnostics $TS"; echo "# newest weekly log: ${LOG:-none}"
  echo; echo "## summary of that run"
  [ -n "$LOG" ] && grep -A12 '"weekly_results"' "$LOG" | head -16
  echo; echo "## idrac failure detail (full error)"
  if [ -n "$LOG" ]; then
    grep -A40 'TASK \[.*copy the quarter build directory' "$LOG" | grep -B4 -A30 -E 'fatal|stderr' | head -90
  fi
  echo; echo "## idrac dirs"
  ls -la /opt/ansible/build/grafana_stack/idrac/ /opt/ansible/staged/idrac/ 2>&1 | head -40
  echo; echo "## idrac quarter dir"
  ls -la "/opt/ansible/build/grafana_stack/idrac/$(cat /opt/ansible/build/current_quarter 2>/dev/null)" 2>&1 | head -40
  echo; echo "## staged listings"
  for c in grafana postgres; do ls -la /opt/ansible/staged/$c /opt/ansible/staged/$c/*/ 2>&1 | head -40; done
  echo; echo "## new-quarter script(s)"; find /opt/ansible -name 'new-quarter*' 2>/dev/null
  echo; echo "## quarter build dirs"
  ls /opt/ansible/build/guacamole /opt/ansible/build/guacd /opt/ansible/build/postgres /opt/ansible/build/nginx 2>&1
  echo; echo "## guac versions file (if any)"
  cat "/opt/ansible/files/avocado/$(cat /opt/ansible/build/current_quarter 2>/dev/null)/versions.env" 2>&1
} > "$REPORT" 2>&1
echo "  written - send this file back if anything below looks wrong"

if [ $DO_CRON -eq 1 ]; then
  echo "=== 5. Cron entries (root) ==="
  crontab -l > "$BK/root.crontab" 2>/dev/null || : > "$BK/root.crontab"
  cp "$BK/root.crontab" "$BK/root.crontab.new"
  addcron() {  # name line
    if grep -q "$1" "$BK/root.crontab"; then echo "  already present: $1"
    elif [ -x "$3" ]; then echo "$2" >> "$BK/root.crontab.new"; echo "  adding: $2"
    else echo "  skipped (script not executable/found: $3)"; fi
  }
  addcron play_weekly_builds "0 2 * * 4 $PB/play_weekly_builds.sh >> /opt/ansible/logs/weekly-cron.log 2>&1" "$PB/play_weekly_builds.sh"
  addcron check_upstream_releases "0 7 * * * /usr/local/bin/check_upstream_releases.sh >> /var/log/upstream-releases.log 2>&1" /usr/local/bin/check_upstream_releases.sh
  addcron emit_release_ledger "15 7 * * * /usr/local/bin/emit_release_ledger.sh >> /var/log/release-ledger.log 2>&1" /usr/local/bin/emit_release_ledger.sh
  cmp -s "$BK/root.crontab" "$BK/root.crontab.new" || crontab "$BK/root.crontab.new"
fi

if [ $DO_RUN -eq 1 ]; then
  echo "=== 6. Running weekly build: grafana postgres idrac ==="
  "$PB/play_weekly_builds.sh" grafana postgres idrac; echo "  exit $?"
fi

echo; echo "Done (rc=$rc). Backups: $BK"
exit $rc
exit
__PAYLOAD__
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

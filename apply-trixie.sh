#!/bin/bash
# apply-trixie.sh - run as root on the Trixie repo server. Safe to run more than once.
#  1. nginx + openssl package builds: Wednesday -> Thursday in root's crontab
#  2. auto-build-openssl.sh: refresh repo status on the "already built" early exit
#  3. check publish-nucleus-repo.sh already refreshes status (reported only, not changed)
#  4. refresh the repo status metrics now
# Every file changed is backed up first into /root/apply-trixie-backup-<timestamp>/
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

TS=$(date +%F-%H%M%S)
BK=/root/apply-trixie-backup-$TS
mkdir -p "$BK"
SCRIPTS=/home/ansible/scripts
CHECK=/usr/local/bin/check_upstream_versions.sh
rc=0

echo "=== 1. Crontab: nginx and openssl package builds to Thursday ==="
crontab -l > "$BK/root.crontab" 2>/dev/null || true
if [ ! -s "$BK/root.crontab" ]; then
  echo "  root has no crontab - nothing changed"; rc=1
else
  sed -E '/auto-build-(nginx|openssl)\.sh/ s/^([[:space:]]*[^#[:space:]][^[:space:]]*[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+)3([[:space:]])/\14\2/' \
    "$BK/root.crontab" > "$BK/root.crontab.new"
  if cmp -s "$BK/root.crontab" "$BK/root.crontab.new"; then
    echo "  already Thursday (or no matching lines)"
  else
    crontab "$BK/root.crontab.new" && echo "  updated"
  fi
  crontab -l | grep -E 'auto-build-(nginx|openssl)' | sed 's/^/  now: /'
fi

echo "=== 2. auto-build-openssl.sh: refresh status on early exit ==="
F=$SCRIPTS/auto-build-openssl.sh
if [ ! -f "$F" ]; then echo "  $F not found"; rc=1
elif grep -q 'check_upstream_versions' "$F"; then
  echo "  already has the refresh"
else
  cp -p "$F" "$BK/"
  awk '{print} /Already built/ && !d {print "    '"$CHECK"' || true"; d=1}' "$F" > "$F.new" \
    && cat "$F.new" > "$F" && rm -f "$F.new"
  bash -n "$F" && echo "  added (syntax OK)" || { echo "  SYNTAX ERROR - restoring"; cp -p "$BK/$(basename "$F")" "$F"; rc=1; }
  grep -n -B1 -A2 'check_upstream_versions' "$F" | sed 's/^/  /'
fi

echo "=== 3. publish-nucleus-repo.sh refresh (used by both build scripts) ==="
if grep -q 'check_upstream_versions' $SCRIPTS/publish-nucleus-repo.sh 2>/dev/null; then
  echo "  OK - it already calls check_upstream_versions.sh"
else
  echo "  WARNING: publish-nucleus-repo.sh does not call check_upstream_versions.sh"; rc=1
fi

echo "=== 4. Refreshing repo status metrics now ==="
if [ -x "$CHECK" ]; then "$CHECK" && echo "  done" || { echo "  check failed"; rc=1; }
else echo "  $CHECK missing or not executable"; rc=1; fi

echo
echo "Backups: $BK"
exit $rc

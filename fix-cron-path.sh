#!/bin/bash
# fix-cron-path.sh - run as root on container-forge.
#   ./fix-cron-path.sh          apply the fixes
#   ./fix-cron-path.sh --run    apply, then start the five builds in the background
#
# Fixes "chroot: command not found" under cron:
#   1. PATH line at the top of root's crontab
#   2. PATH export in /root/bin/mmdebstrap*.sh (the orchestrator and every build script)
#   3. logrotate for /root/bin/daily-build.log
# Safe to run twice. Originals are saved as <file>.bak-<date>.
set -u
BIN=${BIN:-/root/bin}
LOGF=$BIN/daily-build.log
P='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
MARK='# PATH for cron/non-login shells (fix-cron-path.sh)'
STAMP=$(date +%Y%m%d-%H%M)
RUN=0; [ "${1:-}" = "--run" ] && RUN=1

echo "== 1. root crontab =="
if command -v crontab >/dev/null 2>&1 && [ -z "${SKIP_CRON:-}" ]; then
  crontab -l > "/root/crontab.bak-$STAMP" 2>/dev/null
  if crontab -l 2>/dev/null | grep -q '^PATH='; then
    echo "already has a PATH line - left alone"
  else
    { echo "PATH=$P"; crontab -l 2>/dev/null; } | crontab - && echo "added PATH line (backup /root/crontab.bak-$STAMP)"
  fi
else
  echo "crontab not available - skipped"
fi

echo "== 2. scripts in $BIN =="
for f in "$BIN"/mmdebstrap*.sh; do
  [ -f "$f" ] || continue
  if grep -qF "$MARK" "$f"; then echo "ok (already fixed): $f"; continue; fi
  cp -p "$f" "$f.bak-$STAMP"
  if head -1 "$f" | grep -q '^#!'; then
    sed -i "1a $MARK\nexport PATH=$P" "$f"
  else
    sed -i "1i $MARK\nexport PATH=$P" "$f"
  fi
  if bash -n "$f"; then echo "fixed: $f"; else echo "SYNTAX ERROR after edit, restoring: $f"; cp -p "$f.bak-$STAMP" "$f"; fi
done
rm -f "$BIN"/*.bak-"$STAMP".keep 2>/dev/null

echo "== 3. logrotate for $LOGF =="
if [ -d /etc/logrotate.d ] || command -v logrotate >/dev/null 2>&1; then
  if [ -e /etc/logrotate.d/daily-build ]; then
    echo "already present - left alone"
  else
    cat > /etc/logrotate.d/daily-build <<EOF
$LOGF {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
    echo "created /etc/logrotate.d/daily-build"
  fi
  command -v logrotate >/dev/null 2>&1 && logrotate -d /etc/logrotate.d/daily-build >/dev/null 2>&1 \
    && echo "logrotate dry run ok" || echo "NOTE: logrotate missing or dry run failed - 'apt install logrotate' then 'logrotate -d /etc/logrotate.d/daily-build'"
else
  echo "no /etc/logrotate.d - skipped"
fi

echo "== check: chroot visible with the new PATH? =="
env -i PATH="$P" sh -c 'command -v chroot' || echo "WARNING: chroot still not found"

if [ "$RUN" = 1 ]; then
  echo "== starting builds in the background (log: $LOGF) =="
  env -i HOME=/root PATH="$P" IMAGES="base go node22 node24 postgres18" \
    nohup "$BIN/mmdebstrap-orchestrator.sh" >/dev/null 2>&1 &
  echo "started; watch with:  tail -f $LOGF | grep -E 'Building|succeeded|FAILED|complete'"
else
  echo; echo "Done. To run the builds now:  $0 --run   (or wait for 0500)"
fi

#!/bin/bash
# apply-upstream.sh - run as root on ansible-forge. Safe to run more than once.
#   1. checks curl and jq are installed (the check needs both)
#   2. installs /usr/local/bin/check_upstream_releases.sh (embedded): looks up the newest release of
#      Grafana (within 12.x; a newer major shows as Pre-release), Prometheus, iDRAC exporter,
#      PostgreSQL, Guacamole and guacd and writes
#      /var/lib/node_exporter/textfile/upstream_releases.prom for the dashboard UPSTREAM panel
#   3. runs it once and shows the result
#   4. adds the daily run (07:00) to root's crontab if it is missing
#   ./apply-upstream.sh --no-cron   skips step 4
# Optional: export GITHUB_TOKEN=... in root's crontab line to avoid GitHub's anonymous rate limit.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
DEST="${DEST:-/usr/local/bin/check_upstream_releases.sh}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
sed -n '1,/^__PAYLOAD__$/!p' "$0" | base64 -d | tar -xzf - -C "$TMP" || { echo "payload extract failed"; exit 1; }
rc=0

echo "=== 1. Prerequisites ==="
for t in curl jq; do
  if command -v "$t" >/dev/null 2>&1; then echo "  $t: ok"; else echo "  $t: MISSING  (dnf install -y $t)"; rc=1; fi
done
[ $rc -eq 0 ] || { echo "Install the missing tool(s) and run this again."; exit 1; }

echo "=== 2. Installing $DEST ==="
[ -f "$DEST" ] && cp -p "$DEST" "$DEST.bak" && echo "  (previous version saved as $DEST.bak)"
install -m 0755 -o root -g root "$TMP/check_upstream_releases.sh" "$DEST" && echo "  installed"
[ -x /usr/local/bin/emit_event.sh ] || echo "  note: /usr/local/bin/emit_event.sh not found - the check still works, it just skips the event line"

echo "=== 3. Running it ==="
"$DEST" | sed 's/^/  /' || { echo "  FAILED to run"; rc=1; }
echo "  (? after stable= means GitHub could not be reached; ? after ours= means no staged/built version was found)"
ls -l "${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}/upstream_releases.prom" 2>&1 | sed 's/^/  /'

echo "=== 4. root's crontab ==="
if crontab -l 2>/dev/null | grep -q check_upstream_releases; then echo "  job present:"; crontab -l | grep check_upstream_releases | sed 's/^/    /'
elif [ "${1:-}" = "--no-cron" ]; then echo "  skipped (--no-cron); no upstream job is scheduled"
else
  (crontab -l 2>/dev/null; echo "0 7 * * * $DEST >> /var/log/upstream-releases.log 2>&1") | crontab - && echo "  added: 0 7 * * *"
fi
exit $rc
exit
__PAYLOAD__
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

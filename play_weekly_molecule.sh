#!/bin/bash
# play_weekly_molecule.sh - run the Grafana Molecule scenarios after the weekly image builds.
#
# Save as /opt/ansible/nucleus/playbooks/play_weekly_molecule.sh (owner ansible, chmod 755), then as ansible:
# play_weekly_molecule.sh --install-cron adds the Thursday 04:00 crontab line (idempotent)
# play_weekly_molecule.sh run it now (waits if the weekly builds are still running)
#
# Runs, in order: grafana12 (role config) -> grafana12-image nucleus -> grafana12-image ccop
# Reports each to the pipeline dashboard: emit_event.sh check molecule-<name> success|fail "" 604800
# Also writes $TEXTFILE_DIR/pipeline_weekly_molecule.prom for the Nucleus Pipelines Status dashboard.
# An image class with no tarball built in the last 24 h is reported as NOT TESTED (status 2), not as a failure.
# Exit status 0 only if every scenario that ran passed.

set -u
RUN_DIR="${RUN_DIR:-/opt/ansible/molecule}"
LOG="${LOG:-/opt/ansible/logs/weekly-molecule.log}"
EMIT="${EMIT:-/usr/local/bin/emit_event.sh}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
CLASSES="${MOL_CLASSES:-nucleus ccop}" # image classes to test
IMG_DIR="${IMG_DIR:-/opt/ansible/files/grafana/weekly/images}" # weekly image tarballs
WAIT_MAX="${WAIT_MAX:-10800}" # give up waiting for the builds after 3 h
CRON_LINE='0 4 * * 4 /opt/ansible/nucleus/playbooks/play_weekly_molecule.sh >> /opt/ansible/logs/weekly-molecule-cron.log 2>&1'

if [ "${1:-}" = "--install-cron" ]; then
  if crontab -l 2>/dev/null | grep -qF 'play_weekly_molecule.sh'; then
    echo "crontab already has play_weekly_molecule.sh - left alone"
  else
    crontab -l > "$HOME/crontab.bak-$(date +%Y%m%d-%H%M)" 2>/dev/null
    { crontab -l 2>/dev/null; printf '\n# weekly molecule tests (after the weekly image builds)\n%s\n' "$CRON_LINE"; } | crontab - \
      && echo "added: $CRON_LINE"
  fi
  exit 0
fi

mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
log() { echo "$(date -Iseconds) $*"; }

# One run at a time (a manual run and the cron run must not overlap).
exec 9>/tmp/weekly-molecule.lock
flock -n 9 || { log "another weekly molecule run is active - exiting"; exit 1; }

log "=== weekly molecule start ==="

# Wait for the weekly builds to finish (they own the Docker daemon and the scratch dirs).
waited=0
BUILDS_RE="${BUILDS_RE:-^(/bin/|/usr/bin/)?(ba)?sh( -c)? +/opt/ansible/nucleus/playbooks/play_weekly_builds\.sh}"
while pgrep -f "$BUILDS_RE" >/dev/null 2>&1; do
  [ "$waited" -ge "$WAIT_MAX" ] && { log "weekly builds still running after ${WAIT_MAX}s - giving up"; "$EMIT" check molecule-weekly fail "" 604800 >/dev/null 2>&1 || true; exit 1; }
  [ $((waited % 600)) -eq 0 ] && log "weekly builds still running - waiting"
  sleep 60; waited=$((waited + 60))
done

rc=0
METRICS=""
run() { # run <event-name> <scenario> <class> <command...>
  local name=$1 scen=$2 cls=$3; shift 3
  local t0 t1 ok=0 lbl
  t0=$(date +%s); log "--- $name: start ---"
  if "$@"; then
    ok=1; log "--- $name: PASSED ---"; "$EMIT" check "molecule-$name" success "" 604800 >/dev/null 2>&1 || true
  else
    log "--- $name: FAILED (see /opt/ansible/molecule/logs/) ---"; "$EMIT" check "molecule-$name" fail "" 604800 >/dev/null 2>&1 || true
    rc=1
  fi
  t1=$(date +%s)
  lbl="stack=\"grafana\",test=\"$scen\""
  METRICS="$METRICS$(printf 'pipeline_weekly_molecule_status{%s} %s\npipeline_weekly_molecule_timestamp_seconds{%s} %s\npipeline_weekly_molecule_duration_seconds{%s} %s\n' "$lbl" "$ok" "$lbl" "$t1" "$lbl" "$((t1 - t0))")
"
}

skip() { # skip <event-name> <scenario> - no fresh image this week: status 2
  local name=$1 scen=$2 t1 lbl
  t1=$(date +%s); log "--- $name: NOT TESTED (no image built in the last 24h in $IMG_DIR) ---"
  lbl="stack=\"grafana\",test=\"$scen\""
  METRICS="$METRICS$(printf 'pipeline_weekly_molecule_status{%s} 2\npipeline_weekly_molecule_timestamp_seconds{%s} %s\npipeline_weekly_molecule_duration_seconds{%s} 0\n' "$lbl" "$lbl" "$t1" "$lbl")
"
}

run grafana12 role-config - "$RUN_DIR/run-grafana12.sh"
for c in $CLASSES; do
  if [ -n "$(find "$IMG_DIR" -maxdepth 1 -name "$c-grafana-*.tar.gz" -mmin -1440 2>/dev/null)" ]; then
    run "grafana12-image-$c" "image-$c" - "$RUN_DIR/run-grafana12-image.sh" "$c"
  else
    skip "grafana12-image-$c" "image-$c"
  fi
done

# Publish to the dashboard through node_exporter's textfile collector (same place the weekly build/CIS metrics go).
if [ -d "$TEXTFILE_DIR" ] && [ -w "$TEXTFILE_DIR" ]; then
  tmp=$(mktemp "$TEXTFILE_DIR/.pipeline_weekly_molecule.XXXXXX")
  {
    echo '# HELP pipeline_weekly_molecule_status Weekly Molecule test: 1 passed, 0 failed, 2 not tested.'
    echo '# TYPE pipeline_weekly_molecule_status gauge'
    echo '# HELP pipeline_weekly_molecule_timestamp_seconds Unix time this Molecule scenario finished.'
    echo '# TYPE pipeline_weekly_molecule_timestamp_seconds gauge'
    echo '# HELP pipeline_weekly_molecule_duration_seconds Run time of this Molecule scenario.'
    echo '# TYPE pipeline_weekly_molecule_duration_seconds gauge'
    printf '%s' "$METRICS" | sort -s -t'{' -k1,1
  } > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$TEXTFILE_DIR/pipeline_weekly_molecule.prom" \
    && log "metrics written to $TEXTFILE_DIR/pipeline_weekly_molecule.prom"
else
  log "WARNING: $TEXTFILE_DIR missing or not writable by $(id -un) - no metrics written (dashboard events were still sent)"
fi

log "=== weekly molecule done (rc=$rc) ==="
exit $rc

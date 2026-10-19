#!/bin/bash
# check_new_quarter.sh - run as the ansible user (cron). Safe to run as often as you like.
#
# Asks the fiscal calendar (determine_quarters.sh, which reads common/calendar.env) which quarter it
# is. For each pipeline, if that quarter has not been built yet, runs the pipeline's play script:
#     grafana     /opt/ansible/nucleus/playbooks/play_build_grafana_stack.sh   -> files/grafana/<quarter>
#     guacamole   /opt/ansible/nucleus/playbooks/play_build_guac_release.sh    -> files/avocado/<quarter>
# "Built" means <files dir>/<quarter>/provenance/build.log exists: the play script copies its signed
# build log there as its last step, so it is the record that a build was attempted for that quarter.
# A failed build is NOT retried automatically (a failed attempt also leaves a build.log); remove that
# build.log, or run the play script by hand, to try again.
#
#   check_new_quarter.sh            run whatever is due
#   check_new_quarter.sh --dry-run  only say what would be run
set -uo pipefail

ROOT=${ANSIBLE_ROOT:-/opt/ansible}
PLAYBOOKS=$ROOT/nucleus/playbooks
LOGDIR=$ROOT/logs
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

# stack name | files directory | play script
STACKS=(
  "grafana|$ROOT/files/grafana|play_build_grafana_stack.sh"
  "guacamole|$ROOT/files/avocado|play_build_guac_release.sh"
)

mkdir -p "$LOGDIR"
exec 9>"$LOGDIR/.check_new_quarter.lock"
flock -n 9 || { echo "another check_new_quarter.sh is running"; exit 0; }

eval "$($ROOT/files/common/scripts/determine_quarters.sh)"
if [ -z "${quarter:-}" ]; then echo "ERROR: determine_quarters.sh gave no quarter"; exit 1; fi
echo "$(date '+%F %T') calendar says current quarter: $quarter"

rc=0; ran=0
for s in "${STACKS[@]}"; do
  IFS='|' read -r name fdir play <<< "$s"
  blog="$fdir/$quarter/provenance/build.log"
  if [ -f "$blog" ]; then
    if grep -q "=== Build FAILED" "$blog"; then echo "  $name: $quarter was attempted and FAILED (see $blog) - not retrying"; rc=1
    else echo "  $name: $quarter already built"; fi
    continue
  fi
  if pgrep -f "^(/usr)?(/bin/)?bash (\\./|[^ ]*/)?${play}( |\$)" >/dev/null; then echo "  $name: build already running - skipping"; continue; fi
  if [ $DRY -eq 1 ]; then echo "  $name: NEW QUARTER - would run $PLAYBOOKS/$play"; continue; fi
  echo "  $name: NEW QUARTER $quarter - running $play"
  ran=1
  ( cd "$PLAYBOOKS" && "./$play" ) >> "$LOGDIR/new-quarter-$(date +%F).log" 2>&1
  st=$?
  echo "  $name: $play exit $st"
  [ $st -eq 0 ] || rc=1
done

if [ $ran -eq 1 ] && [ $DRY -eq 0 ]; then
  /usr/local/bin/emit_event.sh check new-quarter "$([ $rc -eq 0 ] && echo success || echo fail)" "$quarter" 0 >/dev/null 2>&1 || true
fi
exit $rc

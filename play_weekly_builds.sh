#!/bin/bash
# play_weekly_builds.sh [component ...]
# Weekly early-warning builds. With no arguments every component runs; each one is independent.
#   play_weekly_builds.sh                      all eight
#   play_weekly_builds.sh prometheus postgres  just those
# Components run in parallel, WEEKLY_JOBS at a time (default: half the CPUs = 6 on a 12-CPU server),
# the same way the quarterly scans run 6 at a time. Every component has its own log in
# /opt/ansible/logs/weekly_builds-<start>/<component>.log; the run log gets each component's result.
#   WEEKLY_JOBS=1 play_weekly_builds.sh        one component at a time (the old behaviour)
# Cron (after the Wednesday staging):  0 2 * * 4  /opt/ansible/nucleus/playbooks/play_weekly_builds.sh
set -uo pipefail
export TMPDIR="${WEEKLY_TMPDIR:-/opt/ansible/molecule/scans/tmp}"; mkdir -p "$TMPDIR"   # never the 4 GB /tmp
SECONDS=0
export PLAYBOOK_DIR="${PLAYBOOK_DIR:-/opt/ansible/nucleus/playbooks}"
export INVENTORY="${INVENTORY:-/home/ansible/inventory.ini}"
LOG_DIR="${LOG_DIR:-/opt/ansible/logs}"
ALL="grafana prometheus idrac nginx_grafana guacamole guacd postgres nginx_guac"
JOBS="${WEEKLY_JOBS:-$(( $(nproc) / 2 ))}"; [[ "$JOBS" -ge 1 ]] || JOBS=1

exec 9>"${LOCK_FILE:-/tmp/play_weekly_builds.lock}"
flock -n 9 || { echo "another weekly build run is in progress"; exit 0; }

start_time=$(date +%F-%T)
logfile="${LOG_DIR}/weekly_builds-${start_time}.log"
export compdir="${LOG_DIR}/weekly_builds-${start_time}"
mkdir -p "$compdir"

COMPONENTS=("$@")
[[ ${#COMPONENTS[@]} -gt 0 ]] || read -ra COMPONENTS <<<"$ALL"
echo "=== Weekly builds started at ${start_time} (${#COMPONENTS[@]} components, ${JOBS} at a time) ===" | tee -a "$logfile"
echo "Component logs: ${compdir}/" | tee -a "$logfile"

run_one() {
  local c="$1"
  ansible-playbook \
    -i "$INVENTORY" \
    "${PLAYBOOK_DIR}/weekly_builds.yml" \
    --vault-password-file ~/vault_pass.txt \
    -e "{\"weekly_only\": [\"${c}\"]}" \
    > "${compdir}/${c}.log" 2>&1
  echo $? > "${compdir}/${c}.rc"
}
export -f run_one

printf '%s\n' "${COMPONENTS[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one {}'

# ---- one summary for the whole run ---------------------------------------------------------
rc=0; attention=(); summary="weekly_results:"
for c in "${COMPONENTS[@]}"; do
  crc=$(cat "${compdir}/${c}.rc" 2>/dev/null || echo 99)
  line=$(grep -E "^ +\"${c}\": " "${compdir}/${c}.log" 2>/dev/null | tail -1 | sed 's/^ *//; s/,$//')
  [[ -n "$line" ]] || line="\"${c}\": \"NO RESULT (play exit ${crc}, see ${compdir}/${c}.log)\""
  summary+=$'\n'"    ${line}"
  if [[ "$crc" -ne 0 ]]; then rc=2; attention+=("$c"); fi
done
echo "$summary" | tee -a "$logfile"
[[ ${#attention[@]} -eq 0 ]] || echo "Need attention: ${attention[*]}" | tee -a "$logfile"

echo "=== Weekly builds finished at $(date +%F-%T) after ${SECONDS}s (exit ${rc}) ===" | tee -a "$logfile"
exit "$rc"

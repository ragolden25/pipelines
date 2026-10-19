#!/usr/bin/env bash
# =====================================================================
# emit_quarter_info.sh -- the CURRENT QUARTER's locked versions and stack build result, for the dashboard.
#
# READ-ONLY on the pipeline. For each stack it reads, for every quarter that has them:
#   <files dir>/<quarter>/versions.env            the versions that quarter was built with
#   <files dir>/<quarter>/provenance/build.log    the signed build log copied by play_build_*.sh
# and the fiscal calendar (common/calendar.env) to know which quarter is current.
#
#   grafana  -> /opt/ansible/files/grafana/<quarter>/
#   guac     -> /opt/ansible/files/avocado/<quarter>/
#
# Metrics (node_exporter textfile collector, one atomic file, pipeline_quarter_info.prom):
#   quarter_current{quarter}                                        1 for the quarter the calendar says it is now
#   quarter_locked_version{stack,quarter,component,version}         1 per KEY_VERSION line of versions.env
#   quarter_stack_build{stack,quarter,started,finished,duration,ignored}
#                                                                   1 built OK | 0 failed | 3 not built yet
#   quarter_stack_build_timestamp_seconds{stack,quarter}            when the build finished (unix seconds)
#
# Run as the ansible user (any user that can read /opt/ansible/files and write the textfile directory).
# Install:  /usr/local/bin/emit_quarter_info.sh   (0755)       Cron: 20 7 * * *   (ansible)
# =====================================================================
set -u
ROOT="${ANSIBLE_ROOT:-/opt/ansible}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
CALENDAR="${CALENDAR:-$ROOT/files/common/calendar.env}"
OUT="${TEXTFILE_DIR}/pipeline_quarter_info.prom"

# stack label | files directory
STACKS=( "grafana|$ROOT/files/grafana" "guac|$ROOT/files/avocado" )

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n'; }

# ---- which quarter is it now? (same rule as determine_quarters.sh, but without writing current_quarter)
current=""
if [[ -f "$CALENDAR" ]]; then
  today="$(date +%Y-%m-%d)"
  current="$( ( source "$CALENDAR"
      for v in $(grep -oP 'FY\d{2}Q[1-4]_START' "$CALENDAR" | sort); do
        q=${v%_START}; s=${!v}; e_var="${q}_END"; e=${!e_var}
        if [[ "$today" > "$s" || "$today" == "$s" ]] && [[ "$today" < "$e" || "$today" == "$e" ]]; then
          echo "$q" | tr 'A-Z' 'a-z'; break
        fi
      done ) )"
fi
[[ -z "$current" && -s "$ROOT/build/current_quarter" ]] && current="$(tr -d '[:space:]' < "$ROOT/build/current_quarter")"

body=""
[[ -n "$current" ]] && body+="quarter_current{quarter=\"$(esc "$current")\"} 1"$'\n'

for row in "${STACKS[@]}"; do
  IFS='|' read -r stack fdir <<<"$row"
  newest="$(ls -1d "$fdir"/fy[0-9][0-9]q[1-4] 2>/dev/null | sort | tail -n1)"
  for qdir in "$fdir"/fy[0-9][0-9]q[1-4]; do
    [[ -d "$qdir" ]] || continue
    quarter="$(basename "$qdir")"

    # --- locked versions: every KEY_VERSION=value line
    if [[ -f "$qdir/versions.env" ]]; then
      while IFS='=' read -r key val; do
        [[ "$key" =~ ^[A-Z0-9_]+_VERSION$ ]] || continue
        val="$(printf '%s' "$val" | tr -d "\"' \r")"
        [[ -n "$val" ]] || continue
        comp="$(printf '%s' "${key%_VERSION}" | tr 'A-Z' 'a-z')"
        [[ "$comp" == idrac_exporter ]] && comp=idrac
        body+="quarter_locked_version{stack=\"$stack\",quarter=\"$quarter\",component=\"$(esc "$comp")\",version=\"$(esc "$val")\"} 1"$'\n'
      done < "$qdir/versions.env"
    fi

    # --- stack build result from the signed build log
    blog="$qdir/provenance/build.log"
    if [[ -f "$blog" ]]; then
      started="$(grep -m1 -oP '^=== Build started at \K\S+' "$blog")"
      finished="$(grep -m1 -oP '^=== Build finished at \K\S+' "$blog")"
      dur="$(grep -m1 -oP '^=== Total time: \K[0-9]+ minutes [0-9]+ seconds' "$blog")"
      recap="$(grep -E '^[A-Za-z0-9_.-]+ +: ok=[0-9]+' "$blog" | tail -n1)"
      failed="$(grep -oP 'failed=\K[0-9]+' <<<"$recap" | head -n1)"
      ignored="$(grep -oP 'ignored=\K[0-9]+' <<<"$recap" | head -n1)"
      status=1
      if grep -q '^=== Build FAILED' "$blog" || [[ -n "$failed" && "$failed" != 0 ]]; then status=0
      elif [[ -z "$finished" ]]; then status=0; fi        # the play script always writes "finished"; a log without it is incomplete
      when="$(stat -c %Y "$blog" 2>/dev/null || echo 0)"
      body+="quarter_stack_build{stack=\"$stack\",quarter=\"$quarter\",started=\"$(esc "$started")\",finished=\"$(esc "$finished")\",duration=\"$(esc "$dur")\",ignored=\"${ignored:-0}\"} $status"$'\n'
      body+="quarter_stack_build_timestamp_seconds{stack=\"$stack\",quarter=\"$quarter\"} $when"$'\n'
    elif [[ "$qdir" == "$newest" ]]; then
      body+="quarter_stack_build{stack=\"$stack\",quarter=\"$quarter\",started=\"\",finished=\"\",duration=\"\",ignored=\"0\"} 3"$'\n'
      body+="quarter_stack_build_timestamp_seconds{stack=\"$stack\",quarter=\"$quarter\"} 0"$'\n'
    fi
  done
done

body="$(printf '%s' "$body" | sed '/^$/d')"
printf '%s\n' "$body"

mkdir -p "$TEXTFILE_DIR" 2>/dev/null
tmp="$(mktemp "${TEXTFILE_DIR}/.quarter_info.XXXXXX")" || { echo "cannot write metrics" >&2; exit 1; }
{
  echo "# HELP quarter_current The fiscal quarter it is now, from calendar.env."
  echo "# TYPE quarter_current gauge"
  echo "# HELP quarter_locked_version Versions each quarter was built with (versions.env)."
  echo "# TYPE quarter_locked_version gauge"
  echo "# HELP quarter_stack_build Result of each stack's quarterly build (build.log): 1 ok, 0 failed, 3 not built yet."
  echo "# TYPE quarter_stack_build gauge"
  echo "# HELP quarter_stack_build_timestamp_seconds When the quarterly build log was written (unix seconds)."
  echo "# TYPE quarter_stack_build_timestamp_seconds gauge"
  printf '%s\n' "$body"
} > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$OUT"

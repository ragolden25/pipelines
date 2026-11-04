#!/bin/bash
# investigate_compose_hardening.sh - answers the open questions before hardening the compose templates.
# Run as ansible on ansible-forge:   bash investigate_compose_hardening.sh
#
#   1. Guacamole: where does it get its database password (guacamole.properties, environment, or both)?
#   2. guacd: does anything need it to run as root (session recordings, drive redirection, file ownership)?
#      Then actually tries it: starts a SEPARATE test guacd from the same image as UID 65532 on a spare
#      localhost port, checks it starts and accepts connections, and removes it. The real stack is untouched.
#   3. Both stacks: current CPU / memory use per container, to size resource limits.
#
# Never prints a password: only whether one is set and its length. Report goes to the screen and to
# /opt/ansible/molecule/reports/compose-hardening-<date>.md
# Needs: hosts "guac" and "std1" in /home/ansible/inventory.ini (override with GUAC_HOST / GRAFANA_HOST).

set -u
INV="${INV:-/home/ansible/inventory.ini}"
GUAC_HOST="${GUAC_HOST:-guac}"
GRAFANA_HOST="${GRAFANA_HOST:-std1}"
TEST_UID="${TEST_UID:-65532:65532}"
TEST_PORT="${TEST_PORT:-14822}"

# ----------------------------------------------------------------------------------------------
# Remote parts (run on the target host as root, via ansible's script module)
# ----------------------------------------------------------------------------------------------
if [ "${1:-}" = --remote-guac ]; then
  TEST_UID=$2; TEST_PORT=$3
  len() { [ -n "$1" ] && echo "set (${#1} characters)" || echo "not set"; }

  echo "### 1. Guacamole database password source"
  P=/var/lib/containers/guacamole/guacamole.properties
  if [ -f "$P" ]; then
    echo "- guacamole.properties: $P"
    for k in postgresql-hostname postgresql-database postgresql-username enable-environment-properties; do
      v=$(grep -E "^[[:space:]]*$k[[:space:]]*:" "$P" | head -1 | cut -d: -f2- | xargs)
      echo "  - \`$k\`: ${v:-not set}"
    done
    v=$(grep -E '^[[:space:]]*postgresql-password[[:space:]]*:' "$P" | head -1 | cut -d: -f2- | xargs)
    echo "  - \`postgresql-password\`: $(len "$v")"
    echo "  - file mode/owner: $(stat -c '%a %U:%G' "$P")"
  else
    echo "- guacamole.properties: not found at $P"
  fi
  e=$(docker inspect guacamole --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^POSTGRESQL_PASSWORD=' | cut -d= -f2-)
  echo "- container environment \`POSTGRESQL_PASSWORD\`: $(len "$e")"
  echo "- (Guacamole only reads environment variables if \`enable-environment-properties: true\` is in guacamole.properties,"
  echo "  or if the image's startup script turns them into properties.)"
  echo
  echo "### 2a. Does guacd need root? What guacd is asked to write"
  q="SELECT p.parameter_name, count(*) AS connections, string_agg(DISTINCT p.parameter_value, ', ') AS paths
     FROM guacamole_connection_parameter p
     WHERE p.parameter_name IN ('recording-path','typescript-path','drive-path','create-recording-path','create-drive-path','enable-drive','enable-sftp','sftp-root-directory')
     GROUP BY p.parameter_name ORDER BY 1;"
  out=$(docker exec guac-db bash -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -A -F " | " -c "$0"' "$q" 2>&1)
  if [ -n "$out" ]; then echo '```'; echo "$out"; echo '```'; else echo "- no recording / drive / SFTP parameters on any connection"; fi
  echo "- files guacd sees under /etc/guacamole (owner and mode):"
  echo '```'; ls -ln /var/lib/containers/guacamole 2>&1 | head -20; echo '```'
  echo "- guacd's user inside the running container: $(docker exec guacd id 2>&1 || echo 'cannot exec (no id binary)')"
  echo
  echo "### 2b. Test: same guacd image as UID $TEST_UID (separate container, port 127.0.0.1:$TEST_PORT)"
  img=$(docker inspect guacd --format '{{.Config.Image}}' 2>/dev/null)
  if [ -z "$img" ]; then echo "- guacd is not running here - test skipped"; else
    seccomp=(); [ -f /usr/share/containers/seccomp.json ] && seccomp=(--security-opt seccomp=/usr/share/containers/seccomp.json)
    docker rm -f guacd-uid-test >/dev/null 2>&1
    docker run -d --name guacd-uid-test --user "$TEST_UID" --read-only --tmpfs /tmp \
      --cap-drop ALL --security-opt no-new-privileges:true "${seccomp[@]}" \
      -v /var/lib/containers/fonts:/usr/share/fonts/truetype/custom:ro \
      -v /var/lib/containers/guacamole:/etc/guacamole:ro \
      -p 127.0.0.1:"$TEST_PORT":4822 "$img" >/dev/null 2>&1
    sleep 6
    run=$(docker inspect guacd-uid-test --format '{{.State.Running}}' 2>/dev/null)
    if timeout 3 bash -c "</dev/tcp/127.0.0.1/$TEST_PORT" 2>/dev/null; then port=accepting; else port="not accepting"; fi
    echo "- image: \`$img\`"
    echo "- still running after 6 s: ${run:-no}"
    echo "- port $TEST_PORT: $port connections"
    echo "- its log:"
    echo '```'; docker logs guacd-uid-test 2>&1 | tail -15; echo '```'
    docker rm -f guacd-uid-test >/dev/null 2>&1 && echo "- test container removed"
  fi
  echo
fi

if [ "${1:-}" = --remote-stats ]; then
  echo "| Container | CPU now | Memory now | Memory limit | Peak memory since start |"
  echo "|---|---|---|---|---|"
  for c in $(docker ps --format '{{.Names}}' | sort); do
    s=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' "$c")
    cpu=${s%%|*}; mem=${s#*|}
    cg=$(docker inspect "$c" --format '{{.Id}}')
    peak=$(cat /sys/fs/cgroup/system.slice/docker-"$cg".scope/memory.peak 2>/dev/null \
           || cat /sys/fs/cgroup/memory/docker/"$cg"/memory.max_usage_in_bytes 2>/dev/null)
    [ -n "$peak" ] && peak="$((peak / 1048576)) MiB" || peak="n/a"
    echo "| $c | $cpu | ${mem% / *} | ${mem#* / } | $peak |"
  done
  echo
  echo "Host: $(nproc) CPUs, $(free -m | awk '/^Mem:/ {print $2}') MiB RAM, up $(uptime -p)"
fi
case "${1:-}" in --remote-*) exit 0 ;; esac

# ----------------------------------------------------------------------------------------------
# Local part (ansible-forge)
# ----------------------------------------------------------------------------------------------
OUT=/opt/ansible/molecule/reports/compose-hardening-$(date +%F).md
mkdir -p "$(dirname "$OUT")"
remote() { # remote <host> <args...> : run this script's remote part there, print only its output
  ansible "$1" -i "$INV" -b -m ansible.builtin.script -a "$0 ${*:2}" 2>/dev/null \
    | python3 -c '
import json, re, sys
raw = sys.stdin.read()
m = re.search(r"=>\s*(\{.*\})\s*$", raw, re.S)
try: print(json.loads(m.group(1)).get("stdout", "").rstrip())
except Exception: print("could not reach host or parse output:\n" + raw[-800:])'
}
{
  echo "# Compose hardening: investigation"
  echo
  echo "Generated $(date -Iseconds). Passwords are never shown, only whether they are set."
  echo
  echo "## Guacamole host ($GUAC_HOST)"
  echo
  remote "$GUAC_HOST" --remote-guac "$TEST_UID" "$TEST_PORT"
  echo
  echo "### 3. Resource use: Guacamole stack"
  echo
  remote "$GUAC_HOST" --remote-stats
  echo
  echo "## Grafana host ($GRAFANA_HOST)"
  echo
  echo "### 3. Resource use: Grafana stack (no limits set today)"
  echo
  remote "$GRAFANA_HOST" --remote-stats
} | tee "$OUT"
echo; echo "written: $OUT"

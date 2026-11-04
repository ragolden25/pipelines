#!/bin/bash
# inspect_hardened_images.sh - READ-ONLY fact sheet for the IA standing statements.
#
# For every image tarball in a release, reports what is really inside it and how it is run:
#   user, entrypoint, shells, network/download tools, package manager, setuid/setgid files,
#   dpkg package count; plus each service's runtime settings from the stack's compose file.
#
# Usage (as ansible on ansible-forge):
#   inspect_hardened_images.sh <images dir> [compose file] [output.md]
# e.g.
#   inspect_hardened_images.sh /opt/ansible/files/avocado/fy27q1/images /opt/ansible/files/avocado/fy27q1/docker-compose.yml
#   inspect_hardened_images.sh /opt/ansible/files/grafana/fy27q1/images /opt/ansible/nucleus/roles/configure_grafana_stack/templates/docker-compose.yml.j2
# Default classes inspected: nucleus (set CLASSES="nucleus ccop" for both).
# Output: markdown, to the screen and to the output file (default /opt/ansible/molecule/reports/).
# Images are loaded only for inspection; nothing is run and every image/container it loads is removed.

set -u
IMG_DIR="${1:-}"; COMPOSE="${2:-}"
[ -d "$IMG_DIR" ] || { echo "usage: $0 <images dir> [compose file] [output.md]"; exit 2; }
CLASSES="${CLASSES:-nucleus}"
STACK=$(basename "$(dirname "$(dirname "$IMG_DIR")")")/$(basename "$(dirname "$IMG_DIR")")
OUT="${3:-/opt/ansible/molecule/reports/hardened-images-$(echo "$STACK" | tr / -)-$(date +%F).md}"
mkdir -p "$(dirname "$OUT")"
PY=/opt/ansible/molecule/venv/bin/python3; [ -x "$PY" ] || PY=python3

CHECK_SHELLS="bin/sh bin/bash bin/dash bin/ash usr/bin/sh usr/bin/bash usr/bin/dash"
CHECK_NET="usr/bin/curl usr/bin/wget bin/nc usr/bin/nc usr/bin/ncat usr/bin/socat usr/bin/ssh usr/bin/scp"
CHECK_PKG="usr/bin/apt usr/bin/apt-get usr/bin/dpkg usr/bin/dnf usr/bin/rpm usr/bin/pip3"
CHECK_ADMIN="bin/su usr/bin/su usr/bin/sudo usr/bin/passwd bin/mount usr/bin/mount"

present() { # present <listing file> <candidate paths...>  -> names found
  local l=$1; shift; local found=""
  for p in "$@"; do grep -qxF "$p" "$l" && found="$found $(basename "$p")"; done
  found=$(echo "$found" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')
  echo "${found:-none}"
}

{
echo "# Hardened image facts: $STACK"
echo
echo "Generated $(date -Iseconds) on $(hostname -s) from \`$IMG_DIR\`. Read from the image files themselves."
echo
echo "| Image | User | Entrypoint | Shells | Network/download tools | Package managers | Admin/setuid tools | setuid/setgid files | dpkg database |"
echo "|---|---|---|---|---|---|---|---|---|"
} | tee "$OUT"

for cls in $CLASSES; do
  for f in $(ls "$IMG_DIR"/"$cls"-*.tar.gz 2>/dev/null | sort); do
    tag=$(docker load -i "$f" 2>/dev/null | sed -n 's/^Loaded image: //p' | head -1)
    [ -n "$tag" ] || { echo "| $(basename "$f") | could not load | | | | | | | |" | tee -a "$OUT"; continue; }
    user=$(docker image inspect --format '{{.Config.User}}' "$tag"); user=${user:-root (unset)}
    ep=$(docker image inspect --format '{{join .Config.Entrypoint " "}} {{join .Config.Cmd " "}}' "$tag" | sed 's/  */ /g;s/^ //')
    cid=$(docker create "$tag" 2>/dev/null)
    L=$(mktemp -p /opt/ansible/molecule/scratch 2>/dev/null || mktemp)
    V=$(mktemp -p /opt/ansible/molecule/scratch 2>/dev/null || mktemp)
    docker export "$cid" | tar -tvf - > "$V" 2>/dev/null
    awk '{ if ($1 ~ /^l/) print $(NF-2); else print $NF }' "$V" | sed 's|^\./||;s|/$||' > "$L"
    # merged-usr images: /bin is a symlink to usr/bin, so usr/bin/x is also reachable as bin/x
    if grep -qE '^l.* (\./)?bin -> /?usr/bin$' "$V"; then sed -n 's|^usr/bin/|bin/|p' "$L" > "$L.b"; cat "$L.b" >> "$L"; rm -f "$L.b"; fi
    suid=$(awk '$1 ~ /^-..[sS]|^-.....[sS]/ {print $NF}' "$V" | sed 's|^\./||' | xargs -r -n1 basename | sort -u | tr '\n' ' ')
    # dpkg database: present (scanners can see OS packages) or removed (they can't)
    if grep -qxF 'var/lib/dpkg/status' "$L"; then
      n=$(docker cp "$cid":/var/lib/dpkg/status - 2>/dev/null | tar -xOf - 2>/dev/null | grep -c '^Package:')
      dpkg="present (${n:-?} packages)"
    else
      dpkg="removed"
    fi
    [ -s "$V" ] || dpkg="?"
    echo "| \`$tag\` | $user | \`$ep\` | $(present "$L" $CHECK_SHELLS) | $(present "$L" $CHECK_NET) | $(present "$L" $CHECK_PKG) | $(present "$L" $CHECK_ADMIN) | ${suid:-none} | ${dpkg:-0} |" | tee -a "$OUT"
    docker rm -f "$cid" >/dev/null 2>&1; docker rmi "$tag" >/dev/null 2>&1; rm -f "$L" "$V"
  done
done

if [ -n "$COMPOSE" ] && [ -f "$COMPOSE" ]; then
  {
  echo
  echo "## Runtime settings from \`$COMPOSE\`"
  echo
  "$PY" - "$COMPOSE" <<'PY'
import re, sys, yaml
txt = open(sys.argv[1]).read()
txt = re.sub(r"\{#.*?#\}", "", txt, flags=re.S)             # template comments
txt = re.sub(r"\{%.*?%\}", "", txt)                       # template control lines
txt = re.sub(r"\{\{\s*([^}]*?)\s*\}\}", r"<\1>", txt)      # template variables -> <name>
d = yaml.safe_load(txt) or {}
print("| Service | User | Read-only root | cap_drop | cap_add | security_opt | Published ports | CPU / memory limit |")
print("|---|---|---|---|---|---|---|---|")
for name, s in (d.get("services") or {}).items():
    lim = ((s.get("deploy") or {}).get("resources") or {}).get("limits") or {}
    j = lambda v: ", ".join(map(str, v)) if isinstance(v, list) else (str(v) if v not in (None, "") else "—")
    print("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
        name, s.get("user", "image default"), "yes" if s.get("read_only") else "no",
        j(s.get("cap_drop")), j(s.get("cap_add")), j(s.get("security_opt")), j(s.get("ports")),
        ("%s CPU / %s" % (lim.get("cpus", "—"), lim.get("memory", "—"))) if lim else "none"))
PY
  } | tee -a "$OUT"
fi

echo; echo "written: $OUT"

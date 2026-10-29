#!/bin/bash
# collect_molecule_info.sh - READ-ONLY. Gathers what is needed to build the Guacamole Molecule
# scenarios (modeled on the Grafana ones) into one text report. Changes nothing.
#
# Run as root on ansible-forge (needed to read ansible's crontab):
#   bash collect_molecule_info.sh
# Output: /opt/ansible/molecule/collect-<date>.txt
# Secrets are redacted (password/secret/token/key values) and vault-encrypted files are skipped,
# but skim the report before sending it anywhere.

set -u
OUT="/opt/ansible/molecule/collect-$(date +%F-%H%M).txt"
ROLES=/opt/ansible/nucleus/roles
PLAYBOOKS=/opt/ansible/nucleus/playbooks
MOL=/opt/ansible/molecule
TEXTFILE_DIR=/var/lib/node_exporter/textfile
MAXSIZE=200000   # skip any single file bigger than this (bytes)
PRUNE=( -path '*/.git' -prune -o -path '*/venv' -prune -o -path '*/cache' -prune -o -path '*/scratch' -prune -o -path '*/.cache' -prune -o )

section() { printf '\n\n##################### %s #####################\n' "$*"; }

redact() {
  sed -E 's/((pass(word|wd)?|secret|token|api_?key|private_?key)[^:=]*[:=][[:space:]]*)[^[:space:]].*/\1<REDACTED>/I'
}

dump() { # dump <file>
  local f=$1 sz
  printf '\n=== FILE: %s ===\n' "$f"
  [ -r "$f" ] || { echo "[not readable]"; return; }
  sz=$(stat -c %s "$f")
  [ "$sz" -gt "$MAXSIZE" ] && { echo "[skipped: $sz bytes]"; return; }
  head -c 14 "$f" | grep -q '^\$ANSIBLE_VAULT' && { echo "[vault-encrypted, skipped]"; return; }
  grep -Iq . "$f" 2>/dev/null || { echo "[binary or empty, skipped]"; return; }
  redact < "$f"
}

tree_of() { # perms owner size date path, for every file under a directory
  find "$1" "${PRUNE[@]}" -type f -printf '%M %u:%g %10s %TY-%Tm-%Td %p\n' 2>/dev/null | sort -k5
}

dump_text_under() { # dump every text file under a directory (pruned)
  find "$1" "${PRUNE[@]}" -type f -print 2>/dev/null | sort | while read -r f; do dump "$f"; done
}

{
  echo "collect_molecule_info.sh report - $(hostname -s) - $(date -Iseconds)"

  section "1. Weekly molecule scheduling and metrics"
  echo "--- ansible crontab ---"
  crontab -l -u ansible 2>&1 | redact
  echo "--- textfile collector files mentioning molecule ---"
  grep -l molecule "$TEXTFILE_DIR"/*.prom 2>/dev/null | while read -r f; do ls -l "$f"; done
  echo "--- molecule metric lines (all files) ---"
  grep -H 'molecule' "$TEXTFILE_DIR"/*.prom 2>/dev/null | grep -v '^[^:]*:#'
  echo "--- everything else referencing the metric ---"
  grep -rl pipeline_weekly_molecule /opt/ansible /home/ansible/scripts /root/bin /usr/local/bin 2>/dev/null

  section "2. Molecule install and runner scripts"
  "$MOL/venv/bin/molecule" --version 2>&1
  echo "--- $MOL top level ---"
  ls -la "$MOL" 2>&1
  find "$MOL" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.yml' -o -name '*.cfg' -o -name '*.txt' \) | sort | while read -r f; do dump "$f"; done

  section "3. Grafana Molecule scenarios (the pattern to copy)"
  for d in $(find "$ROLES" -maxdepth 2 -type d -name molecule 2>/dev/null | sort); do
    echo "--- tree: $d ---"; tree_of "$d"
  done
  for d in $(find "$ROLES" -maxdepth 2 -type d -name molecule 2>/dev/null | sort); do
    dump_text_under "$d"
  done
  echo "--- roles/playbooks that mention molecule ---"
  grep -rli molecule "$ROLES" "$PLAYBOOKS" 2>/dev/null | grep -v '/molecule/' | sort

  section "4. Latest Molecule logs (tail)"
  for p in 'grafana12-2' 'grafana12-image-nucleus-' 'grafana12-image-ccop-'; do
    f=$(ls -t "$MOL/logs/$p"*.log 2>/dev/null | head -1)
    [ -n "$f" ] && { printf '\n=== LOG (last 80 lines): %s ===\n' "$f"; tail -n 80 "$f" | redact; }
  done

  section "5. configure_grafana_stack role (what the role scenario verifies)"
  tree_of "$ROLES/configure_grafana_stack" | grep -v '/molecule/'
  for sub in tasks defaults vars handlers meta; do
    [ -d "$ROLES/configure_grafana_stack/$sub" ] && dump_text_under "$ROLES/configure_grafana_stack/$sub"
  done

  section "6. Guacamole roles"
  find "$ROLES" -maxdepth 1 -type d \( -iname '*guac*' -o -iname '*avocado*' \) | sort
  for r in $(find "$ROLES" -maxdepth 1 -type d \( -iname 'configure_guac*' -o -iname 'deploy_guac*' \) | sort); do
    echo "--- tree: $r ---"; tree_of "$r"
    dump_text_under "$r"
  done

  section "7. Weekly build roles (guac side + grafana for comparison)"
  for r in weekly_common weekly_build_grafana weekly_build_guacamole weekly_build_guacd weekly_build_postgres weekly_build_nginx_guac; do
    [ -d "$ROLES/$r" ] || continue
    echo "--- tree: $ROLES/$r ---"; tree_of "$ROLES/$r"
    for sub in tasks defaults vars; do
      [ -d "$ROLES/$r/$sub" ] && dump_text_under "$ROLES/$r/$sub"
    done
  done
  echo "--- weekly playbooks/scripts ---"
  find "$PLAYBOOKS" -maxdepth 1 -type f -iname '*weekly*' | sort | while read -r f; do dump "$f"; done

  section "8. Weekly images and versions"
  find /opt/ansible/files -maxdepth 5 -path '*weekly*' -type f -printf '%TY-%Tm-%Td %TH:%TM %10s %p\n' 2>/dev/null | sort -k4
  echo "--- version env files (newest 6) ---"
  find /opt/ansible -maxdepth 6 -type f -iname 'version*.env' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -6 | cut -d' ' -f2- | while read -r f; do dump "$f"; done
  echo "--- docker images on this host ---"
  docker images --format '{{.Repository}}:{{.Tag}}  {{.ID}}  {{.CreatedSince}}' 2>&1 \
    | grep -Ei 'guac|grafana|prometheus|postgres|nginx|idrac' | sort

  section "9. Guacamole stack Dockerfiles (newest 6)"
  find /opt/ansible -type f -name 'Dockerfile*' -not -path '*/fy*' -printf '%T@ %p\n' 2>/dev/null \
    | grep -Ei 'guac|postgres' | sort -rn | head -6 | cut -d' ' -f2- | while read -r f; do dump "$f"; done

  echo; echo "=== end of report ==="
} > "$OUT" 2>&1

chmod 0640 "$OUT"
echo "report: $OUT ($(wc -l < "$OUT") lines, $(du -h "$OUT" | cut -f1))"

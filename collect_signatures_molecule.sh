#!/bin/bash
# collect_signatures_molecule.sh - bundles what is needed to move every signature into
# provenance/signatures (both stacks, in concert with deploy roles and Molecule) and to find why
# Thursday's Guacamole nucleus Molecule test failed.
# Run as ansible on ansible-forge:   bash collect_signatures_molecule.sh
# Output: /home/ansible/sig-molecule-collect.tar.gz  (text files under 1 MB; no images, tarballs,
# keys or vault files). Follows symlinks. Refuses to write an empty tarball and says why.

set -u
R=/opt/ansible/nucleus
OUT=/home/ansible/sig-molecule-collect.tar.gz
WORK=$(mktemp -d -p /opt/ansible/molecule/scratch 2>/dev/null || mktemp -d -p /home/ansible)
LIST=$WORK/list
FILES=$WORK/files

{
  # daily base image sync and every other pipeline script
  find -L /opt/ansible/scripts -maxdepth 2 -type f
  # scan / signing helpers used by the builds
  find -L /opt/ansible/files/common/scripts -maxdepth 2 -type f
  ls -d /usr/local/bin/emit_event.sh
  # deployment roles (they verify signatures) and their Molecule scenarios
  find -L "$R"/roles -mindepth 1 -maxdepth 1 \( -name 'configure_grafana_stack' -o -name 'configure_guacamole*' \)
  # Molecule runners
  find -L /opt/ansible/molecule -maxdepth 1 -type f -name '*.sh'
  find -L "$R"/playbooks -maxdepth 1 -type f -iname '*molecule*'
  # Thursday's Molecule logs (scenario logs + the runner's own)
  find -L /opt/ansible/molecule/logs -maxdepth 1 -type f -name '*.log' -mtime -3
  ls -d /opt/ansible/logs/weekly-molecule.log /opt/ansible/logs/weekly-molecule-cron.log
  # what the dashboard currently gets
  find -L /var/lib/node_exporter/textfile -maxdepth 1 -type f -name '*.prom'
} 2>/dev/null | sort -u > "$LIST"

while read -r p; do
  find -L "$p" -type f -size -1024k \
    ! -name '*.tar*' ! -name '*.gz' ! -name '*.xz' ! -name '*.zst' ! -name '*.sig' ! -name '*.asc' \
    ! -name '*.gpg' ! -iname '*vault*' ! -name '*.key' ! -name '*.pem' ! -name '*.crt' \
    ! -name '*.jar' ! -name '*.ttf' ! -name '*.otf' ! -path '*/.git/*' ! -path '*/.cache/*' 2>/dev/null
done < "$LIST" | sort -u > "$FILES"

# names only (no contents) of the current provenance trees and the newest weekly trees,
# so the real file naming can be seen
for s in grafana avocado; do
  for d in /opt/ansible/files/$s/current/provenance \
           "$(ls -td /opt/ansible/molecule/weekly/$s/*/ 2>/dev/null | head -1)"; do
    [ -n "$d" ] && [ -d "$d" ] && { echo "### $d"; find -L "$d" -maxdepth 3 | sort; echo; }
  done
done > "$WORK/provenance-listing.txt" 2>&1
crontab -l > "$WORK/ansible-crontab.txt" 2>/dev/null
sudo -n crontab -l -u root > "$WORK/root-crontab.txt" 2>/dev/null || echo "(root crontab not readable without a password)" > "$WORK/root-crontab.txt"
printf '%s\n' "$WORK/provenance-listing.txt" "$WORK/ansible-crontab.txt" "$WORK/root-crontab.txt" >> "$FILES"

echo "searched: $(wc -l < "$LIST") locations, found $(wc -l < "$FILES") files"
if [ "$(wc -l < "$FILES")" -le 3 ]; then
  echo "Nothing to bundle. Locations searched:"; cat "$LIST"; rm -rf "$WORK"; exit 1
fi
tar -czf "$OUT" -T "$FILES" || echo "tar reported errors above"
rm -rf "$WORK"
echo "written: $OUT ($(du -h "$OUT" | cut -f1), $(tar -tzf "$OUT" | wc -l) files)"
echo "Upload it under a new name if an older one is still attached."

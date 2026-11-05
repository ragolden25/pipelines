#!/bin/bash
# collect_grafana_build.sh - bundles the Grafana quarterly build role and what it calls, so it can be
# split into one role per component following the weekly_build_<component> / weekly_common pattern.
# Run as ansible on ansible-forge:   bash collect_grafana_build.sh
# Output: /home/ansible/grafana-build-collect.tar.gz  (text files under 1 MB; no images, tarballs,
# signatures, keys or vault files). Follows symlinks. Refuses to write an empty tarball and says why.

set -u
R=/opt/ansible/nucleus
OUT=/home/ansible/grafana-build-collect.tar.gz
WORK=$(mktemp -d -p /opt/ansible/molecule/scratch 2>/dev/null || mktemp -d -p /home/ansible)
LIST=$WORK/list
FILES=$WORK/files

# ansible's crontab, for the schedule
crontab -l > "$WORK/ansible-crontab.txt" 2>/dev/null || echo "(no crontab for $(whoami))" > "$WORK/ansible-crontab.txt"

{
  # the quarterly Grafana build role(s), build_guac_release (for the second split), weekly roles
  find -L "$R"/roles -mindepth 1 -maxdepth 1 \( -name 'build_grafana*' -o -name 'build_guac_release' \
       -o -name 'weekly_build_*' -o -name 'weekly_common' \)
  # playbooks and play scripts that run the quarterly and weekly builds
  find -L "$R"/playbooks -maxdepth 1 -type f \( -iname '*grafana*' -o -iname '*build*' -o -iname '*weekly*' \
       -o -iname '*quarter*' -o -iname '*stag*' \)
  # staging / detection / scan / signing scripts
  find -L /opt/ansible/scripts /home/ansible/scripts "$R"/scripts -maxdepth 3 -type f \
       | grep -iE 'grafana|prometheus|idrac|nginx|stag|detect|scan|sign|version'
  # this quarter's versions.env and build log
  ls -d /opt/ansible/files/grafana/fy27q1/versions.env /opt/ansible/files/grafana/fy27q1/provenance/build.log
  # newest idrac staging/build logs, wherever they are
  find -L /opt/ansible/staged/idrac* /opt/ansible/build/idrac* /opt/ansible/logs -maxdepth 2 -type f \
       \( -iname '*.log' -o -iname '*.env' -o -iname '*version*' \) -mtime -14
  echo "$WORK/ansible-crontab.txt"
} 2>/dev/null | sort -u > "$LIST"

while read -r p; do
  find -L "$p" -type f -size -1024k \
    ! -name '*.tar*' ! -name '*.gz' ! -name '*.xz' ! -name '*.zst' ! -name '*.sig' ! -name '*.asc' \
    ! -name '*.gpg' ! -iname '*vault*' ! -name '*.key' ! -name '*.pem' ! -path '*/.git/*' 2>/dev/null
done < "$LIST" | sort -u > "$FILES"

echo "searched: $(wc -l < "$LIST") locations, found $(wc -l < "$FILES") files"
# what is in staged/ for idrac (names and dates only), so the missing build can be traced
ls -la --time-style=long-iso /opt/ansible/staged/ /opt/ansible/staged/idrac* > "$WORK/staged-listing.txt" 2>&1
echo "$WORK/staged-listing.txt" >> "$FILES"

if [ "$(wc -l < "$FILES")" -le 2 ]; then
  echo "Nothing to bundle - the roles were not found where expected. Locations searched:"
  cat "$LIST"; echo "Check: ls -la $R $R/roles | head"
  rm -rf "$WORK"; exit 1
fi

tar -czf "$OUT" -T "$FILES" || echo "tar reported errors above"
rm -rf "$WORK"
echo "written: $OUT ($(du -h "$OUT" | cut -f1), $(tar -tzf "$OUT" | wc -l) files)"

#!/bin/bash
# collect_grafana_build.sh - bundles the Grafana quarterly build role and what it calls, so it can be
# split into one role per component following the weekly_build_<component> / weekly_common pattern.
# Run as ansible on ansible-forge:   bash collect_grafana_build.sh
# Output: /home/ansible/grafana-build-collect.tar.gz  (text files only, under 1 MB each; no images,
# tarballs, binaries, keys or vault files)

set -u
R=/opt/ansible/nucleus
OUT=/home/ansible/grafana-build-collect.tar.gz
LIST=$(mktemp -p /opt/ansible/molecule/scratch 2>/dev/null || mktemp)

{
  # the quarterly Grafana build role(s) and the Guacamole one, for the second split
  find "$R"/roles -maxdepth 1 -type d \( -name 'build_grafana*' -o -name 'build_guac_release' \
       -o -name 'weekly_build_*' -o -name 'weekly_common' \)
  # the playbooks and play scripts that run the quarterly and weekly builds
  find "$R"/playbooks -maxdepth 1 -type f \( -name '*grafana*' -o -name '*build*' -o -name '*weekly*' \
       -o -name '*quarter*' \)
  # staging / detection / scan scripts the builds call
  find /opt/ansible/scripts /home/ansible/scripts -maxdepth 2 -type f 2>/dev/null \
       | grep -iE 'grafana|prometheus|idrac|nginx|stage|detect|scan|sign|version'
  # this quarter's versions.env and build log, to see what a release records
  ls /opt/ansible/files/grafana/fy27q1/versions.env /opt/ansible/files/grafana/fy27q1/provenance/build.log 2>/dev/null
  # ansible's crontab, for the schedule
} 2>/dev/null | sort -u > "$LIST"

crontab -l > /home/ansible/ansible-crontab.txt 2>/dev/null && echo /home/ansible/ansible-crontab.txt >> "$LIST"

tar -czf "$OUT" --files-from=<(
  while read -r p; do
    find "$p" -type f -size -1M \
      ! -name '*.tar*' ! -name '*.gz' ! -name '*.xz' ! -name '*.sig' ! -name '*.asc' ! -name '*.gpg' \
      ! -name '*vault*' ! -name '*.key' ! -name '*.pem' ! -path '*/.git/*' 2>/dev/null
  done < "$LIST" | sort -u
) 2>/dev/null

rm -f "$LIST" /home/ansible/ansible-crontab.txt
echo "written: $OUT ($(du -h "$OUT" | cut -f1), $(tar -tzf "$OUT" | wc -l) files)"

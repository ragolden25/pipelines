#!/bin/bash
# migrate_weekly.sh - move the weekly build trees off /opt onto the Molecule partition.
#
#   /opt/ansible/files/avocado/weekly  ->  data in /opt/ansible/molecule/weekly/avocado
#   /opt/ansible/files/grafana/weekly  ->  data in /opt/ansible/molecule/weekly/grafana
#
# The old paths stay exactly where they are as bind mounts (added to /etc/fstab), so every build
# role, script and Molecule test keeps using the same paths with no changes.
# Run as root while no weekly build or Molecule run is active. Safe to re-run: a stack that is
# already migrated is skipped. Source data is only deleted after the copy is verified.

set -u
NEW_ROOT=/opt/ansible/molecule/weekly
STACKS="avocado grafana"
say() { echo "[$(date +%H:%M:%S)] $*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
mountpoint -q /opt/ansible/molecule || { echo "/opt/ansible/molecule is not a mounted partition - stopping"; exit 1; }
if pgrep -f 'play_weekly_builds|play_weekly_molecule|molecule (test|converge|verify)' >/dev/null; then
  echo "a weekly build or Molecule run is active - run this when it has finished"; exit 1
fi

say "before:"; df -h /opt /opt/ansible/molecule | sed 's/^/    /'

for s in $STACKS; do
  OLD=/opt/ansible/files/$s/weekly
  NEW=$NEW_ROOT/$s
  say "--- $s"
  if mountpoint -q "$OLD"; then say "already a bind mount - skipped"; continue; fi
  [ -d "$OLD" ] || { say "$OLD does not exist - skipped"; continue; }

  mkdir -p "$NEW"
  chown --reference="$OLD" "$NEW"; chmod --reference="$OLD" "$NEW"
  say "copying $(du -sh "$OLD" | cut -f1) to $NEW"
  if command -v rsync >/dev/null; then
    rsync -aHAX "$OLD"/ "$NEW"/ || { say "copy failed - $OLD left untouched"; exit 1; }
  else
    cp -a "$OLD"/. "$NEW"/ || { say "copy failed - $OLD left untouched"; exit 1; }
  fi

  # verify: same files, same total bytes
  a=$(cd "$OLD" && find . -type f | wc -l); b=$(cd "$NEW" && find . -type f | wc -l)
  x=$(du -sb "$OLD" | cut -f1);              y=$(du -sb "$NEW" | cut -f1)
  if [ "$a" != "$b" ] || [ "$(( x > y ? x - y : y - x ))" -gt 1048576 ]; then
    say "verify FAILED (files $a vs $b, bytes $x vs $y) - $OLD left untouched"; exit 1
  fi
  say "verified: $a files"

  find "$OLD" -mindepth 1 -delete
  grep -qE "^[^#]*[[:space:]]$OLD[[:space:]]" /etc/fstab || {
    cp -p /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d-%H%M%S)"
    echo "$NEW  $OLD  none  bind,x-systemd.requires-mounts-for=/opt/ansible/molecule  0 0" >> /etc/fstab
    say "added bind mount to /etc/fstab"
  }
  systemctl daemon-reload
  mount "$OLD" && say "mounted: $OLD -> $NEW ($(ls "$OLD" | tr '\n' ' '))"
done

say "after:"; df -h /opt /opt/ansible/molecule | sed 's/^/    /'

#!/bin/bash
# install_signatures.sh - installs signatures-in-one-place + provenance reset (both stacks), the
# Grafana per-component quarterly split, and two one-line fixes. Run as ansible on ansible-forge,
# from the folder holding signatures-and-split.tar.gz:
#   bash install_signatures.sh
#
#   1. backs up every file it replaces to /opt/ansible/molecule/backups/signatures-<date>/
#   2. installs the files from signatures-and-split.tar.gz (all under /opt/ansible)
#   3. moves the CURRENT quarter's existing signatures into provenance/signatures, both stacks:
#      image signatures from ccop/ and nucleus/, container-forge's synced .asc and digest files
#      (scan results stay; the next build resets those folders)
#   4. guacamole service: removes read_only + tmpfs from the Guacamole compose template
#      (Tomcat cannot start with a read-only root - the nucleus Molecule 404 since Nov 4)
#   5. ansible's crontab: the 1st-of-month quarter check pointed at a script that does not exist
#      (check_new_quarter.sh); points it at /opt/ansible/scripts/new-quarter.sh
# Safe to run twice.

set -euo pipefail
TARBALL="${1:-signatures-and-split.tar.gz}"
[ "$(id -un)" = ansible ] || { echo "run this as ansible"; exit 1; }
[ -f "$TARBALL" ] || { echo "missing $TARBALL"; exit 1; }
BK=/opt/ansible/molecule/backups/signatures-$(date +%F-%H%M)
mkdir -p "$BK"

echo "== 1. backup to $BK"
tar -tzf "$TARBALL" | grep -v '/$' | while read -r f; do
  [ -f "/$f" ] && { mkdir -p "$BK/$(dirname "$f")"; cp -p "/$f" "$BK/$f"; echo "  backed up /$f"; }
done
cp -p /opt/ansible/files/avocado/docker-compose.yml.j2 "$BK/" 2>/dev/null || true
crontab -l > "$BK/ansible-crontab.txt" 2>/dev/null || true

echo "== 2. install"
# sync-base-image.sh runs as root from root's crontab: keep its owner, only replace the content
tar -xzf "$TARBALL" -C / --no-same-owner --no-overwrite-dir -m --exclude=opt/ansible/scripts/sync-base-image.sh
tar -xzOf "$TARBALL" opt/ansible/scripts/sync-base-image.sh | sudo tee /opt/ansible/scripts/sync-base-image.sh >/dev/null
sudo chmod 0755 /opt/ansible/scripts/sync-base-image.sh
chmod +x /opt/ansible/nucleus/playbooks/play_build_grafana_stack.sh /opt/ansible/nucleus/playbooks/play_build_guac_release.sh
echo "  installed $(tar -tzf "$TARBALL" | grep -vc '/$') files"

echo "== 3. move current quarter signatures into provenance/signatures"
for stack in grafana avocado; do
  P=$(readlink -f /opt/ansible/files/$stack/current)/provenance
  [ -d "$P" ] || { echo "  $stack: no current provenance - skipped"; continue; }
  sudo mkdir -p "$P/signatures"
  n=0
  for f in "$P"/ccop/*.asc "$P"/nucleus/*.asc "$P"/container-forge/*.asc "$P"/container-forge/debian13-*-digest-latest.txt "$P"/build.log.asc; do
    [ -f "$f" ] || continue
    sudo mv -f "$f" "$P/signatures/"; n=$((n + 1))
  done
  sudo chown -R ansible:ansible "$P/signatures"
  echo "  $stack ($(basename "$(dirname "$P")")): moved $n file(s) to $P/signatures"
done

echo "== 4. guacamole service: no read-only root"
python3 - <<'EOF'
p = '/opt/ansible/files/avocado/docker-compose.yml.j2'
s = open(p).read()
old = """    read_only: true
    tmpfs:
      - /tmp
      - /usr/local/tomcat/temp
      - /usr/local/tomcat/work
      - /usr/local/tomcat/logs
"""
n = s.count(old)
if n == 1:
    open(p, 'w').write(s.replace(old, '')); print('  removed read_only + tmpfs from the guacamole service')
elif n == 0:
    print('  already removed - nothing to do')
else:
    print('  WARNING: block found %d times - left unchanged, check the template' % n)
EOF

echo "== 5. ansible crontab: quarter check"
if crontab -l 2>/dev/null | grep -q '/opt/ansible/scripts/check_new_quarter.sh'; then
  crontab -l | sed 's#/opt/ansible/scripts/check_new_quarter.sh#/opt/ansible/scripts/new-quarter.sh#' | crontab -
  echo "  now: $(crontab -l | grep 'new-quarter.sh')"
else
  echo "  no check_new_quarter.sh line - left as is: $(crontab -l 2>/dev/null | grep -i quarter || echo none)"
fi
[ -x /opt/ansible/scripts/new-quarter.sh ] || echo "  NOTE: /opt/ansible/scripts/new-quarter.sh is not executable: chmod +x it"

echo
echo "done. Backups: $BK"

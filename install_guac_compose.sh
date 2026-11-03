#!/bin/bash
# install_guac_compose.sh [path/to/guac-compose-weekly.tar.gz]
# Installs the one-template / weekly-compose changes and renders this week's compose files.
# Run as root. Finds the tarball itself if no path is given (current folder, /home/ansible, /root).
# Every step is checked; it stops at the first problem and says what it was.

set -u
say()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "STOPPED: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

TB="${1:-}"
if [ -z "$TB" ]; then
  for d in "$PWD" /home/ansible /root; do
    [ -f "$d/guac-compose-weekly.tar.gz" ] && { TB="$d/guac-compose-weekly.tar.gz"; break; }
  done
fi
[ -n "$TB" ] && [ -f "$TB" ] || die "guac-compose-weekly.tar.gz not found (give its path as the first argument)"
say "using $TB"
tar -tzf "$TB" >/dev/null 2>&1 || die "$TB is not a readable tarball"

# 1. backup (once per run, timestamped)
BK=/root/pre-compose-backup-$(date +%F-%H%M%S).tar.gz
tar -czf "$BK" -C / \
  opt/ansible/files/avocado/docker-compose.yml.j2 \
  opt/ansible/nucleus/roles/weekly_common/tasks \
  opt/ansible/nucleus/roles/configure_guacamole/vars \
  opt/ansible/nucleus/roles/configure_guacamole/molecule/guac16/prepare.yml 2>/dev/null \
  || die "backup failed"
say "backup: $BK"

# 2. install
tar -xzf "$TB" -C / || die "extract failed"
say "installed:"; tar -tzf "$TB" | grep -v '/$' | sed 's|^|    /|'

# 3. remove the unused ccop template added to the role earlier
rm -f /opt/ansible/nucleus/roles/configure_guacamole/templates/docker-compose-ccop.yml.j2

# 4. ownership
chown -R ansible:ansible-admin \
  /opt/ansible/files/avocado/docker-compose.yml.j2 \
  /opt/ansible/nucleus/roles/weekly_common \
  /opt/ansible/nucleus/roles/configure_guacamole \
  /opt/ansible/nucleus/playbooks/render_weekly_compose_now.yml || die "chown failed"
say "ownership set to ansible:ansible-admin"

# 5. sanity checks on what was installed
grep -q 'render_weekly_compose.yml' /opt/ansible/nucleus/roles/weekly_common/tasks/main.yml || die "weekly_common main.yml does not include the render step"
grep -q 'sign_weekly_images.yml'   /opt/ansible/nucleus/roles/weekly_common/tasks/main.yml || die "weekly_common main.yml does not include the signing step"
grep -q 'compose_hardened'         /opt/ansible/files/avocado/docker-compose.yml.j2        || die "template is not the new version"
[ -f /opt/ansible/nucleus/roles/build_guac_release/vars/main.yml ] \
  || die "/opt/ansible/nucleus/roles/build_guac_release/vars/main.yml not found - fix the include_vars path in render_weekly_compose.yml"
say "checks passed"

# 6. render this week's compose files (as ansible, like the builds)
say "rendering this week's Guacamole compose files"
su - ansible -c 'ansible-playbook /opt/ansible/nucleus/playbooks/render_weekly_compose_now.yml' || die "render failed (see output above)"
W=$(ls -td /opt/ansible/files/avocado/weekly/*/images 2>/dev/null | head -1 | xargs -r dirname)
ls -l "$W"/docker-compose.yml "$W"/docker-compose-ccop.yml "$W"/.env 2>/dev/null || die "compose files were not produced in $W"
say "image lines:"; grep -h 'image:' "$W"/docker-compose.yml "$W"/docker-compose-ccop.yml | sed 's/^ */    /'

echo
say "done. Next, as ansible:"
echo "    /opt/ansible/molecule/run-guac16.sh deploy ccop && /opt/ansible/molecule/run-guac16.sh verify ccop; /opt/ansible/molecule/run-guac16.sh deploy && /opt/ansible/molecule/run-guac16.sh verify"

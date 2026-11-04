#!/bin/bash
# install_compose_hardening.sh [path/to/compose-hardening.tar.gz]
# Installs the compose hardening changes, checks them, and re-renders this week's Guacamole compose files.
# Run as root. Finds the tarball itself (current folder, /home/ansible, /root) if no path is given.
set -u
say() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "STOPPED: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"
TB="${1:-}"
[ -n "$TB" ] || for d in "$PWD" /home/ansible /root; do [ -f "$d/compose-hardening.tar.gz" ] && { TB="$d/compose-hardening.tar.gz"; break; }; done
[ -n "$TB" ] && [ -f "$TB" ] || die "compose-hardening.tar.gz not found (give its path as the first argument)"
say "using $TB"

BK=/root/pre-hardening-backup-$(date +%F-%H%M%S).tar.gz
tar -czf "$BK" -C / $(tar -tzf "$TB" | grep -v '/$' | while read -r f; do [ -e "/$f" ] && echo "$f"; done) 2>/dev/null || die "backup failed"
say "backup of the files being replaced: $BK"

tar -xzf "$TB" -C / || die "extract failed"
tar -tzf "$TB" | grep -v '/$' | sed 's|^|    installed /|'
chown ansible:ansible-admin /opt/ansible/files/avocado/docker-compose.yml.j2 /opt/ansible/files/grafana/docker-compose.yml.j2
chown -R ansible:ansible-admin /opt/ansible/nucleus/roles/configure_guacamole /opt/ansible/nucleus/roles/configure_grafana_stack/molecule

grep -q 'POSTGRES_PASSWORD_FILE' /opt/ansible/files/avocado/docker-compose.yml.j2 || die "Guacamole template is not the new version"
grep -q 'db-secret.yml' /opt/ansible/nucleus/roles/configure_guacamole/tasks/main.yml || die "role main.yml does not include db-secret.yml"
say "checks passed"

# The database import runs psql inside the postgres container. If any role file still relies on the
# POSTGRES_PASSWORD variable (now replaced by POSTGRES_PASSWORD_FILE), show it so it can be fixed first.
hits=$(grep -rnE 'POSTGRES_PASSWORD([^_]|$)' /opt/ansible/nucleus/roles/configure_guacamole --include=*.sh --include=*.j2 --include=*.yml 2>/dev/null | grep -v '/molecule/')
if [ -n "$hits" ]; then
  echo; echo "ATTENTION - these role files still use POSTGRES_PASSWORD (paste them to Claude before testing):"
  echo "$hits" | sed 's/^/    /'; echo
else
  say "no role file relies on POSTGRES_PASSWORD - the import should work with the secrets file"
fi

say "re-rendering this week's Guacamole compose files"
su - ansible -c 'ansible-playbook /opt/ansible/nucleus/playbooks/render_weekly_compose_now.yml' >/dev/null || die "render failed"
W=$(ls -td /opt/ansible/files/avocado/weekly/*/images 2>/dev/null | head -1 | xargs -r dirname)
grep -c 'POSTGRES_PASSWORD_FILE' "$W/docker-compose.yml" >/dev/null && say "rendered $W/docker-compose.yml (and -ccop) with the new settings" || die "render did not pick up the new template"
grep -q guacpass "$W/docker-compose.yml" "$W/docker-compose-ccop.yml" && echo "WARNING: a password is still in the rendered compose files" || say "no password in the rendered compose files"

echo
say "done. Next, as ansible:"
echo "    /opt/ansible/molecule/run-guac16.sh deploy ccop && /opt/ansible/molecule/run-guac16.sh verify ccop; /opt/ansible/molecule/run-guac16.sh deploy && /opt/ansible/molecule/run-guac16.sh verify"
echo "    /opt/ansible/molecule/run-grafana12-image.sh nucleus"

#!/usr/bin/env bash
# fix-ansible-permissions.sh - run as root (root's crontab).
# Replaces the old version, which stopped at its first line because /opt/ansible/roles does not exist
# (set -e), so it never fixed anything. Changes:
#   - code directories now point at /opt/ansible/nucleus/roles and /opt/ansible/nucleus/playbooks
#   - a missing directory is skipped, not fatal
#   - the data directories root-run jobs write into (staged, build, files, logs) are given back to
#     ansible: ownership only, no chmod, so staged binaries keep their permissions
set -uo pipefail
ROOT=${ANSIBLE_ROOT:-/opt/ansible}

echo "=== Normalizing permissions for $ROOT ($(date '+%F %T')) ==="

# --- code: owner ansible, group ansible-admin, dirs 770, files 664 (as before) ---
CODE_DIRS=( "$ROOT/nucleus/roles" "$ROOT/nucleus/playbooks" "$ROOT/scripts" )
for dir in "${CODE_DIRS[@]}"; do
  if [ ! -d "$dir" ]; then echo "skip (missing): $dir"; continue; fi
  echo "code: $dir"
  chown -R ansible:ansible-admin "$dir"
  find "$dir" -type d -exec chmod 770 {} \;
  find "$dir" -type f -exec chmod 664 {} \;
done
echo "Ensuring scripts are executable"
[ -d "$ROOT/scripts" ] && find "$ROOT/scripts" -type f -name "*.sh" -exec chmod 775 {} \;
[ -d "$ROOT/nucleus/playbooks" ] && find "$ROOT/nucleus/playbooks" -type f -name "*.sh" -exec chmod 775 {} \;

# --- data: only what is not already owned by ansible; ownership only ---
DATA_DIRS=( "$ROOT/staged" "$ROOT/build" "$ROOT/files" "$ROOT/logs" )
for dir in "${DATA_DIRS[@]}"; do
  if [ ! -d "$dir" ]; then echo "skip (missing): $dir"; continue; fi
  n=$(find "$dir" ! -user ansible 2>/dev/null | wc -l)
  echo "data: $dir  ($n not owned by ansible)"
  [ "$n" -gt 0 ] && find "$dir" ! -user ansible -exec chown ansible:ansible {} + 2>/dev/null
  # the ansible user must be able to read and traverse everything it builds from
  find "$dir" -type d ! -perm -u+rwx -exec chmod u+rwx {} + 2>/dev/null
  find "$dir" -type f ! -perm -u+r -exec chmod u+r {} + 2>/dev/null
done

echo "=== Permission normalization complete ==="

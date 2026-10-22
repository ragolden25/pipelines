#!/bin/bash
# install-molecule.sh - run as root on ansible-forge. Installs Molecule (Docker driver) in its own venv
# on the molecule disk, pinned to the same ansible-core as production (2.15.13).
set -euo pipefail
VENV="${VENV:-/opt/ansible/molecule/venv}"
OWNER="${OWNER:-ansible}"
PY="${PY:-python3.11}"

[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
command -v "$PY" >/dev/null || { echo "Installing $PY"; dnf -y install "$PY" "$PY-pip"; }

if [ ! -x "$VENV/bin/python" ]; then
  mkdir -p "$(dirname "$VENV")"
  "$PY" -m venv "$VENV"
fi
"$VENV/bin/pip" install --upgrade pip
"$VENV/bin/pip" install "ansible-core==2.15.13" molecule "molecule-plugins[docker]"
chown -R "$OWNER":"$OWNER" "$VENV"

# the ansible user must reach the Docker daemon (note: docker group access is root-equivalent)
id -nG "$OWNER" | grep -qw docker || { usermod -aG docker "$OWNER"; echo "added $OWNER to the docker group (log out/in as $OWNER to apply)"; }

echo; echo "---- result"
"$VENV/bin/molecule" --version
"$VENV/bin/ansible" --version | head -1
echo "Use it as $OWNER:  source $VENV/bin/activate"

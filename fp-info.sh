#!/bin/bash
# fp-info.sh - read-only preflight report. Run as root on kvm26 first, then kvm25.
OUT="/root/fp-info-$(hostname -s).txt"
{
echo "=== HOST $(hostname) ==="
echo "--- mem/cpu"; free -g | sed -n 1,2p; nproc
echo "--- network"; ip -br addr | grep -vE '^(lo|veth|vnet)'
virsh net-list --all
for d in ansible-forge ansible; do
  if virsh dominfo "$d" >/dev/null 2>&1; then
    echo "--- domain $d"
    virsh dominfo "$d" | grep -E 'State|CPU\(s\)|Max memory|Used memory'
    virsh dumpxml "$d" | grep -E "<interface|mac address|source (bridge|network)|<model type"
    virsh domblklist "$d" --details
  fi
done
F="$(dirname "$(readlink -f "$0")")/forge-backup-full.sh"
if [ "$(hostname -s)" = "kvm26" ] && [ -x "$F" ]; then
  echo "--- backup dry run"; "$F" --dry-run 2>&1
fi
} 2>&1 | tee "$OUT"
echo "Saved to $OUT"

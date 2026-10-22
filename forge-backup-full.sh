#!/bin/bash
# forge-backup-full.sh [--dry-run]
# FIRST full live backup of the ansible-forge VM. No shutdown, no pause: libvirt copies all disks
# at one consistent instant while the VM keeps running, and starts a checkpoint so that later
# backups can be incremental. Run as root on the hypervisor that runs the VM (the R640).
#   Output: $BASE/<date>-full/<disk>.qcow2 for every disk, plus domain.xml and manifest.txt
#   --dry-run  shows the XML and the commands without starting anything
set -euo pipefail
DOM="${DOM:-ansible-forge}"
BASE="${BASE:-/var/lib/libvirt/images/ansible-forge-backup}"
QUIESCE="${QUIESCE:-1}"        # 1 = ask the guest agent to freeze filesystems for the instant of the copy
STAMP=$(date +%Y%m%d-%H%M)
DEST="$BASE/$STAMP-full"
CHK="ckpt-$STAMP"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
virsh domstate "$DOM" | grep -q running || { echo "$DOM is not running"; exit 1; }
if virsh checkpoint-list "$DOM" --name 2>/dev/null | grep -q .; then
  echo "$DOM already has checkpoints, so a first full backup was already taken. Use the incremental script."; exit 1
fi

# ---- the disks: target (vda..), original name, size on the host --------------------------
mapfile -t ROWS < <(virsh domblklist "$DOM" --details | awk '$2=="disk" {print $3, $4}')
[ ${#ROWS[@]} -gt 0 ] || { echo "no disks found"; exit 1; }
need=0
echo "Disks of $DOM:"
for r in "${ROWS[@]}"; do
  t=${r%% *}; src=${r#* }
  phys=$(virsh domblkinfo "$DOM" "$t" | awk '/^Physical/ {print $2}')
  need=$((need + phys))
  printf '  %-4s %-45s %6d GB on the host\n' "$t" "$src" $((phys / 1000000000))
done
mkdir -p "$BASE"
avail=$(df --output=avail -B1 "$BASE" | tail -1 | tr -d ' ')
echo "Needed about $((need / 1000000000)) GB, free $((avail / 1000000000)) GB in $BASE"
[ "$avail" -gt $((need * 11 / 10)) ] || { echo "Not enough free space (needs 10% headroom)"; exit 1; }

# ---- backup and checkpoint XML --------------------------------------------------------------
{
  echo "<domainbackup mode='push'>"; echo "  <disks>"
  for r in "${ROWS[@]}"; do
    t=${r%% *}; src=${r#* }; name=${src##*/}; [[ "$name" == *.qcow2 ]] || name="$name.qcow2"
    echo "    <disk name='$t' backup='yes' type='file'><target file='$DEST/$name'/><driver type='qcow2'/></disk>"
  done
  echo "  </disks>"; echo "</domainbackup>"
} > "$WORK/backup.xml"
{
  echo "<domaincheckpoint><name>$CHK</name><description>first full backup $STAMP</description><disks>"
  for r in "${ROWS[@]}"; do echo "  <disk name='${r%% *}' checkpoint='bitmap'/>"; done
  echo "</disks></domaincheckpoint>"
} > "$WORK/checkpoint.xml"

if [ $DRY -eq 1 ]; then
  echo; echo "---- backup.xml"; cat "$WORK/backup.xml"; echo "---- checkpoint.xml"; cat "$WORK/checkpoint.xml"
  echo "---- would run: virsh backup-begin $DOM backup.xml checkpoint.xml$([ "$QUIESCE" = 1 ] && echo ' --quiesce')"
  exit 0
fi

# ---- the destination must be writable by the user QEMU runs as -------------------------
first=$(virsh domblklist "$DOM" --details | awk '$1=="file" && $2=="disk" {print $4; exit}')
OWN=$(stat -c %U:%G "$first" 2>/dev/null || echo root:root)
mkdir -p "$DEST"; chown "$OWN" "$BASE" "$DEST"; chmod 750 "$BASE" "$DEST"

# ---- go ---------------------------------------------------------------------------------------
echo; echo "Starting the backup of $DOM at $(date +%T) into $DEST"
virsh backup-begin "$DOM" "$WORK/backup.xml" "$WORK/checkpoint.xml" $([ "$QUIESCE" = 1 ] && echo --quiesce) \
  || { echo "backup-begin failed. If the message mentions the guest agent or freezing, try again with QUIESCE=0"; exit 1; }

jobtype() { virsh domjobinfo "$DOM" 2>/dev/null | awk -F: '/^Job type/ {gsub(/ /,"",$2); print $2}'; }
while t=$(jobtype); [[ "$t" == "Unbounded" || "$t" == "Bounded" ]]; do
  echo "$(date +%T)  $(virsh domjobinfo "$DOM" 2>/dev/null | grep -E 'Data (processed|remaining)' | tr -s ' ' | paste -sd' ')"
  sleep 30
done
echo "Job finished at $(date +%T). Result:"; virsh domjobinfo "$DOM" --completed 2>&1 | grep -E 'Job type|Operation|Time elapsed|Data processed' | sed 's/^/  /'

# ---- check what was written ---------------------------------------------------------------
rc=0; : > "$DEST/manifest.txt"
virsh dumpxml "$DOM" > "$DEST/domain.xml"
for r in "${ROWS[@]}"; do
  t=${r%% *}; src=${r#* }; name=${src##*/}; [[ "$name" == *.qcow2 ]] || name="$name.qcow2"
  f="$DEST/$name"
  if [ -s "$f" ] && qemu-img check -f qcow2 "$f" 2>&1 | grep -q 'No errors were found'; then res=OK; else res=BAD; rc=1; fi
  line=$(printf '%-4s %-22s %6d GB  %s' "$t" "$name" $(( $(stat -c %s "$f" 2>/dev/null || echo 0) / 1000000000 )) "$res")
  echo "  $line"; echo "$line" >> "$DEST/manifest.txt"
done
echo "checkpoint: $CHK"; virsh checkpoint-list "$DOM"
echo "checkpoint $CHK" >> "$DEST/manifest.txt"
[ $rc -eq 0 ] && echo "BACKUP OK: $DEST" || echo "BACKUP HAS PROBLEMS - do not rely on it, send me the output"
exit $rc

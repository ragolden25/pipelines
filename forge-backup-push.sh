#!/bin/bash
# forge-backup-push.sh [dest-host]   (run as root on kvm26)
# Copies the newest ansible-forge full backup to the other hypervisor, throttled so the 1 Gb link
# is never saturated, then checks every disk copy there. Resumable: just run it again.
#   BWLIMIT=60000 (KB/s, about 480 Mb/s)   DEST_HOST=kvm25
set -uo pipefail
DEST_HOST="${1:-${DEST_HOST:-kvm25}}"
BASE="${BASE:-/var/lib/libvirt/images/ansible-forge-backup}"
BWLIMIT="${BWLIMIT:-60000}"

[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
SRC=$(ls -1d "$BASE"/*-full 2>/dev/null | sort | tail -1)
[ -n "$SRC" ] && [ -f "$SRC/manifest.txt" ] || { echo "No finished backup found in $BASE"; exit 1; }
grep -q BAD "$SRC/manifest.txt" && { echo "Manifest has BAD disks - not copying"; exit 1; }
NAME=$(basename "$SRC")

ssh -o BatchMode=yes "$DEST_HOST" true 2>/dev/null || { echo "No passwordless ssh to $DEST_HOST (run: ssh-copy-id root@$DEST_HOST)"; exit 1; }
ssh "$DEST_HOST" "command -v rsync >/dev/null && command -v qemu-img >/dev/null" || { echo "rsync and qemu-img are needed on $DEST_HOST"; exit 1; }

need=$(du -sB1 "$SRC" | cut -f1)
avail=$(ssh "$DEST_HOST" "mkdir -p '$BASE' && df --output=avail -B1 '$BASE' | tail -1" | tr -d ' ')
echo "Copying $NAME ($((need/1000000000)) GB) to $DEST_HOST, free there $((avail/1000000000)) GB, limit $((BWLIMIT/1000)) MB/s"
[ "$avail" -gt $((need * 11 / 10)) ] || { echo "Not enough space on $DEST_HOST"; exit 1; }

rsync -a --partial --inplace --bwlimit="$BWLIMIT" --info=progress2 -e ssh "$SRC/" "$DEST_HOST:$BASE/$NAME/" || { echo "rsync failed - run again to resume"; exit 1; }

echo; echo "Checking the copies on $DEST_HOST"
rc=0
while read -r line; do
  f=$(echo "$line" | awk '{print $2}'); [ -n "$f" ] || continue
  if ssh "$DEST_HOST" "qemu-img check -f qcow2 '$BASE/$NAME/$f' 2>&1 | grep -q 'No errors were found'"; then echo "  $f OK"; else echo "  $f BAD"; rc=1; fi
done < <(grep -E ' (OK|BAD)$' "$SRC/manifest.txt")
[ $rc -eq 0 ] && echo "COPY OK: $DEST_HOST:$BASE/$NAME" || echo "COPY HAS PROBLEMS - do not rely on it"
exit $rc

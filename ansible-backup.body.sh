#!/bin/bash
# backup.body.sh - weekly file-level backup to shares1 as dated hard-link snapshots.
# Layout: /nfs/CND/ansible/<YYYY-MM-DD-HHMM>/{root,home,opt,etc,cron}  and  latest -> newest good snapshot

MOUNTPOINT="${MOUNTPOINT:-/nfs}"
DEST_ROOT="${DEST_ROOT:-$MOUNTPOINT/CND/ansible}"
KEEP="${KEEP:-6}"                                   # snapshots to keep
EMIT="${EMIT:-/usr/local/bin/emit_event.sh}"
EXCLUDES="${EXCLUDES:-/root/bin/backup.excludes}"   # optional, one rsync pattern per line
SOURCES=("/root/:root" "/home/ansible/:home" "/opt/:opt" "/etc/:etc" "/var/spool/cron/:cron")

mountpoint -q "$MOUNTPOINT" || { echo "ERROR: $MOUNTPOINT is not mounted - aborting backup"; exit 1; }
mkdir -p "$DEST_ROOT" || exit 1

SNAP="$DEST_ROOT/$(date +%F-%H%M)"
WORK="$SNAP.inprogress"
mkdir -p "$WORK" || exit 1

OPTS=(-aH --numeric-ids)
# ACLs/xattrs only if the share accepts them (NFS often does not)
T="$WORK/.xtest"; : > "$T"
if setfattr -n user.fptest -v 1 "$T" 2>/dev/null; then OPTS+=(-AX); echo "xattrs/ACLs: preserving"; else echo "xattrs/ACLs: not supported on share (run restorecon -R after a restore)"; fi
rm -f "$T"
[ -f "$EXCLUDES" ] && OPTS+=(--exclude-from="$EXCLUDES")

fails=0
for s in "${SOURCES[@]}"; do
  src=${s%%:*}; name=${s##*:}
  [ -d "$src" ] || { echo "skip $src (missing)"; continue; }
  LD=()
  [ -d "$DEST_ROOT/latest/$name" ] && LD=(--link-dest="$DEST_ROOT/latest/$name")
  mkdir -p "$WORK/$name"
  rsync "${OPTS[@]}" "${LD[@]}" "$src" "$WORK/$name/"
  rc=$?
  # 24 = files vanished while copying (builds/scans running): not a failure
  if [ $rc -ne 0 ] && [ $rc -ne 24 ]; then echo "ERROR: rsync of $src failed (rc=$rc)"; fails=$((fails+1)); fi
done

if [ $fails -gt 0 ]; then
  mv "$WORK" "$SNAP.FAILED"
  echo "Backup FAILED ($fails source(s)); kept $SNAP.FAILED, 'latest' unchanged"
  [ -x "$EMIT" ] && "$EMIT" backup ansible-files fail "" 691200
  exit 1
fi

mv "$WORK" "$SNAP" && ln -sfn "$(basename "$SNAP")" "$DEST_ROOT/latest"

# prune: keep newest $KEEP completed snapshots, and clear old failed attempts
ls -1d "$DEST_ROOT"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9] 2>/dev/null \
  | sort | head -n -"$KEEP" | while read -r old; do rm -rf "$old"; done
find "$DEST_ROOT" -maxdepth 1 -name '*.FAILED' -mtime +14 -exec rm -rf {} + 2>/dev/null

echo "Backup OK: $SNAP"
[ -x "$EMIT" ] && "$EMIT" backup ansible-files success "$(basename "$SNAP")" 691200
exit 0

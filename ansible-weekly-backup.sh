#!/bin/bash

MOUNTPOINT="/nfs"
EXPECTED_SOURCE="192.168.110.166:/data/nfs"

# Check if /nfs is actually mounted
if ! mountpoint -q "$MOUNTPOINT"; then
    echo "ERROR: $MOUNTPOINT is NOT mounted"
    echo "Backup failed on $(date +%F-%H%M)" >> /root/failures.log
    exit 1
fi

# Verify correct remote source
ACTUAL_SOURCE=$(mount | grep "on $MOUNTPOINT " | awk '{print $1}')
if [[ "$ACTUAL_SOURCE" != "$EXPECTED_SOURCE" ]]; then
    echo "ERROR: $MOUNTPOINT is mounted, but to the WRONG source"
    echo "Expected: $EXPECTED_SOURCE"
    echo "Found:    $ACTUAL_SOURCE"
    echo "Backup failed on $(date +%F-%H%M)" >> /root/failures.log
    exit 1
fi

echo "filesystem mounted correctly"
echo "conducted weekly backups from $(hostname -f) to shares server on $(date +%F-%H%M)" >> /root/backups.log

/bin/bash /root/bin/backup.body.sh

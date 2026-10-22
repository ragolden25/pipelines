#!/bin/bash
set -e

MOUNTPOINT="/nfs"

# Safety: ensure /nfs is mounted before doing anything
mountpoint -q "$MOUNTPOINT" || {
    echo "ERROR: /nfs is not mounted — aborting backup"
    exit 1
}

mkdir -p /nfs/CND/ansible

# root
mkdir -p /nfs/CND/ansible/root
rsync -avz --delete /root/ /nfs/CND/ansible/root/

# root crontab
mkdir -p /nfs/CND/ansible/crontab
rsync -avz /var/spool/cron/root /nfs/CND/ansible/crontab/

# ansible home
mkdir -p /nfs/CND/ansible/home
rsync -avz --delete /home/ansible/ /nfs/CND/ansible/home/

# opt
mkdir -p /nfs/CND/ansible/opt
rsync -avz --delete /opt/ /nfs/CND/ansible/opt/

#!/bin/bash
# boot-triage.sh - read-only. Run as root on container-forge AND on kvm26.
# Report: /root/boot-triage-<host>.txt   (changes nothing)
OUT=/root/boot-triage-$(hostname -s).txt
exec > >(tee "$OUT") 2>&1
sec() { printf '\n===== %s =====\n' "$1"; }

sec "host / time"
hostname; date; uptime -s 2>/dev/null; timedatectl 2>/dev/null | grep -Ei 'local time|synchronized|NTP|zone'

sec "reboots (last 8)"
last -x -n 40 2>/dev/null | grep -Ei 'reboot|shutdown' | head -8

sec "journal boots (persistent?)"
journalctl --list-boots 2>/dev/null | tail -6

sec "cron daemon status"
systemctl is-active cron crond 2>/dev/null
systemctl list-timers --all 2>/dev/null | grep -Ei 'apt|dnf|update|upgrade' | head

sec "crontabs (root + users)"
echo "--- root"; crontab -l 2>/dev/null
for u in $(cut -d: -f1 /etc/passwd); do
  c=$(crontab -l -u "$u" 2>/dev/null | grep -v '^#' | grep -v '^$') && [ -n "$c" ] && [ "$u" != root ] && { echo "--- $u"; echo "$c"; }
done
ls /etc/cron.d 2>/dev/null

sec "cron activity Sun-Mon this week (container-forge side)"
journalctl --since "3 days ago" -u cron -u crond --no-pager 2>/dev/null | grep -Ei 'CMD|error|start|stop' | head -60

sec "docker"
systemctl is-active docker 2>/dev/null
systemctl show docker -p ActiveEnterTimestamp 2>/dev/null

sec "mounts that failed / dependencies at boot"
systemctl --failed --no-pager 2>/dev/null | head -20
findmnt -t nfs,nfs4 2>/dev/null | head

sec "boot-time errors, this boot (first 60)"
journalctl -b -p err --no-pager 2>/dev/null | head -60

sec "previous boot, last 15 lines before shutdown"
journalctl -b -1 --no-pager 2>/dev/null | tail -15

sec "recent build logs (newest 8 under common locations)"
ls -lt /var/log/container-forge* /opt/*/logs /opt/*/log /root/logs /home/*/logs 2>/dev/null | head -20

# ---- hypervisor-only sections (skipped when virsh is absent) ----
if command -v virsh >/dev/null 2>&1; then
  sec "libvirt: guests, autostart, state"
  virsh list --all
  virsh list --all --name --autostart 2>/dev/null | sed 's/^/autostart: /'
  sec "libvirt-guests service"
  systemctl is-enabled libvirt-guests 2>/dev/null; systemctl is-active libvirt-guests 2>/dev/null
  grep -vE '^\s*#|^\s*$' /etc/default/libvirt-guests /etc/sysconfig/libvirt-guests 2>/dev/null
  sec "libvirt: guest start times after last boot"
  journalctl -b --no-pager 2>/dev/null | grep -Ei 'libvirt-guests|autostart|Starting.*guest|guest.*start|virtqemud' | head -40
  sec "update + reboot job"
  grep -rEl 'reboot|dnf|automatic' /etc/cron* /var/spool/cron 2>/dev/null
  systemctl list-timers --all 2>/dev/null | grep -Ei 'dnf|automatic|update'
  grep -vE '^\s*#|^\s*$' /etc/dnf/automatic.conf 2>/dev/null | head -20
fi

echo; echo "Report saved to $OUT"

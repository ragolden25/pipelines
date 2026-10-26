#!/bin/bash
# crash-triage.sh - read-only. Run as root inside each RHEL 9 VM that crashes. Output: /root/crash-triage-<host>.txt
OUT="/root/crash-triage-$(hostname -s).txt"
PAT='out of memory|oom-kill|hung task|blocked for more than|i/o error|soft lockup|hard lockup|call trace|kernel panic|not responding|task abort|rejecting i/o|xfs.*(error|corrupt|shutdown)|ext4-fs error|mce:|watchdog|vmw_|vmwgfx|BUG:'
{
echo "=== $(hostname -f)  $(date)"
echo "--- kernel / tools"; uname -r; cat /etc/redhat-release
vmware-toolbox-cmd -v 2>&1 | head -1; systemctl is-active vmtoolsd
echo "--- uptime and reboot history"; uptime -s; last -x -n 12 reboot shutdown 2>&1 | head -16
echo "--- journal persistent?"; journalctl --list-boots 2>&1 | tail -4
echo "--- crash dumps"; systemctl is-active kdump; ls -la /var/crash 2>&1 | head
echo "--- weekly timers"; systemctl list-timers --all --no-pager 2>&1 | head -20
systemctl is-enabled fstrim.timer 2>&1; mount | grep -c discard | sed 's/^/mounts with discard: /'
echo "--- cron"; ls /etc/cron.d /etc/cron.weekly 2>&1; crontab -l 2>&1 | grep -v '^#' | head -20
echo "--- memory / swap / dirty"; free -m; swapon --show; sysctl vm.swappiness vm.dirty_ratio vm.dirty_background_ratio vm.overcommit_memory 2>&1
echo "--- disks"; df -hT -x tmpfs -x devtmpfs | head -20; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,DISC-MAX | head -20
echo "--- errors in this boot (journal)"; journalctl -b -k --no-pager 2>/dev/null | grep -i -E "$PAT" | tail -20
echo "--- errors in previous boots and old logs"
journalctl -b -1 --no-pager 2>/dev/null | grep -i -E "$PAT" | tail -20
grep -i -E "$PAT" /var/log/messages* 2>/dev/null | tail -30
echo "--- last 15 lines before each reboot (messages)"
for f in /var/log/messages; do grep -n -E 'rsyslogd.*start|kernel: Linux version' "$f" 2>/dev/null | tail -4; done
echo "--- NFS"; exportfs -v 2>&1 | head; ss -s | head -3
echo "--- top memory"; ps -eo pid,comm,%mem,rss --sort=-%mem | head -6
} 2>&1 | tee "$OUT"
echo; echo "Saved to $OUT"

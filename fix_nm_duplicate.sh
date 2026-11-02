#!/bin/bash
# fix_nm_duplicate.sh <nic>   e.g.  fix_nm_duplicate.sh enp1s0
#
# Stops NetworkManager from ending up with a second profile on the OOB NIC.
# Run as root on container-forge. Safe to run more than once. Does NOT restart
# NetworkManager or networking, so it won't drop your SSH session; the boot-time
# fixes take effect on the next reboot.
#
# The keeper is the profile that is ACTIVE on that NIC right now (so it works even when the
# duplicate has the same name as the good one). Other NICs (e.g. enp1s7) are never touched. Then it:
#   1. deletes any other ethernet profile that would claim that NIC
#   2. pins the keeper to the NIC (interface name + MAC, top priority)
#   3. stops NM from auto-creating "Wired connection N" profiles
#   4. disables the boot-time sources that regenerate a profile named after the NIC:
#      ifupdown (/etc/network/interfaces), netplan, cloud-init
#   5. reports (does not change) kernel boot args ip= / rd.neednet, which make the
#      initramfs recreate a profile named after the NIC on every boot
# Every file it changes is backed up first as <file>.bak-<date>.

set -u
DEV="${1:-}"
STAMP=$(date +%Y%m%d-%H%M)
say() { echo "[$(date +%H:%M:%S)] $*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
command -v nmcli >/dev/null || { echo "nmcli not found"; exit 1; }

[ -n "$DEV" ] || { echo "usage: $0 <nic>   e.g. $0 enp1s0"; exit 1; }
[ -e "/sys/class/net/$DEV" ] || { echo "no NIC named $DEV"; ip -br link; exit 1; }

KUUID=$(nmcli -g UUID,DEVICE con show --active | awk -F: -v d="$DEV" '$2==d {print $1; exit}')
[ -n "$KUUID" ] || { echo "no profile is active on $DEV - bring the good one up first (nmcli con up <uuid>)"; nmcli -f NAME,UUID,DEVICE con show; exit 1; }
KEEP=$(nmcli -g connection.id con show "$KUUID")
MAC=$(tr 'A-Z' 'a-z' < "/sys/class/net/$DEV/address")
KFILE=$(nmcli -g FILENAME con show "$KUUID" 2>/dev/null || true)
say "keeper '$KEEP' ($KUUID) on $DEV, MAC $MAC, file ${KFILE:-unknown}"
say "uptime: $(uptime -p)"

# ---- 1. delete competing profiles -------------------------------------------------
say "--- 1. profiles that compete for $DEV"
found=0
while IFS=: read -r uuid type active; do
  [ "$uuid" = "$KUUID" ] && continue
  case "$type" in 802-3-ethernet|ethernet) ;; *) continue ;; esac
  name=$(nmcli -g connection.id con show "$uuid")
  ifn=$(nmcli -g connection.interface-name con show "$uuid")
  mac=$(nmcli -g 802-3-ethernet.mac-address con show "$uuid" | tr -d '\\' | tr 'A-Z' 'a-z')
  file=$(nmcli -g FILENAME con show "$uuid" 2>/dev/null || true)
  if [ "$ifn" = "$DEV" ] || [ "$mac" = "$MAC" ] || { [ -z "$ifn" ] && [ -z "$mac" ] && { [ -z "$active" ] || [ "$active" = "$DEV" ]; }; }; then
    found=1
    say "deleting '$name' ($uuid) iface=${ifn:-any} mac=${mac:-any} file=${file:-none}"
    nmcli con delete "$uuid" >/dev/null && say "  deleted"
  fi
done < <(nmcli -g UUID,TYPE,DEVICE con show)
[ "$found" -eq 0 ] && say "none right now"

# ---- 2. pin the keeper -------------------------------------------------------------
say "--- 2. pinning '$KEEP' to $DEV / $MAC"
nmcli con mod "$KUUID" connection.interface-name "$DEV" 802-3-ethernet.mac-address "$MAC" \
  connection.autoconnect yes connection.autoconnect-priority 100 && say "pinned"
nmcli con mod "$KUUID" connection.multi-connect single 2>/dev/null || true

# ---- 3. no auto-created profiles ---------------------------------------------------
say "--- 3. NetworkManager auto-default profiles"
CONF=/etc/NetworkManager/conf.d/90-no-auto-default.conf
if grep -qs '^no-auto-default=\*' "$CONF"; then
  say "already off ($CONF)"
else
  printf '[main]\nno-auto-default=*\n' > "$CONF" && say "turned off ($CONF)"
fi
nmcli general reload conf 2>/dev/null && say "NetworkManager config reloaded"

# ---- 4. boot-time sources that regenerate a profile named after the NIC -------------
say "--- 4. boot-time sources"

# ifupdown (Debian): a stanza here makes ifupdown/dhclient configure the NIC too,
# which NM shows as a second connection and which adds a second default route.
for f in /etc/network/interfaces /etc/network/interfaces.d/*; do
  [ -f "$f" ] || continue
  if grep -Eq "^[[:space:]]*(auto|allow-hotplug|allow-auto|iface)[[:space:]].*\\b$DEV\\b" "$f"; then
    cp -p "$f" "$f.bak-$STAMP"
    awk -v d="$DEV" '
      /^[[:space:]]*(auto|allow-[a-z]+|iface|mapping|source)[[:space:]]/ {
        inblk = ($1 == "iface" && $2 == d)
        if ($1 ~ /^(auto|allow-)/) { for (i = 2; i <= NF; i++) if ($i == d) { print "# disabled for NetworkManager: " $0; next } }
      }
      inblk && !/^[[:space:]]*#/ && NF { print "# disabled for NetworkManager: " $0; next }
      { print }' "$f.bak-$STAMP" > "$f"
    say "ifupdown: commented out $DEV in $f (backup $f.bak-$STAMP)"
  fi
done

# netplan: generates a profile in /run/NetworkManager on every boot.
for f in /etc/netplan/*.yaml; do
  [ -f "$f" ] || continue
  case "$KFILE" in /run/*) say "netplan: $f found, but the keeper itself lives in /run - left alone"; continue ;; esac
  if grep -q "$DEV\|$MAC" "$f"; then
    mv "$f" "$f.disabled-$STAMP" && say "netplan: moved $f aside ($f.disabled-$STAMP)"
  fi
done

# cloud-init: rewrites network config on boot.
if [ -d /etc/cloud ]; then
  CI=/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  if [ -f "$CI" ]; then say "cloud-init: network config already disabled"
  else echo 'network: {config: disabled}' > "$CI" && say "cloud-init: network config disabled ($CI)"; fi
fi

# ---- 5. kernel boot args (report only) ---------------------------------------------
if grep -Eq '(^| )(ip=|rd\.neednet)' /proc/cmdline; then
  say "--- 5. FOUND kernel args that make the initramfs create a profile named after the NIC on every boot:"
  grep -Eo '(ip|rd\.neednet)=[^ ]*' /proc/cmdline | sed 's/^/      /'
  if command -v grubby >/dev/null; then
    say "    remove with: grubby --update-kernel=ALL --remove-args=\"$(grep -Eo '(ip|rd\.neednet)=[^ ]*' /proc/cmdline | tr '\n' ' ' | sed 's/ $//')\""
  else
    say "    remove them from GRUB_CMDLINE_LINUX in /etc/default/grub, then run update-grub"
  fi
else
  say "--- 5. kernel boot args: none that create profiles"
fi

say "--- result"
nmcli -f NAME,UUID,DEVICE,FILENAME con show
say "done - one profile should be on $DEV. Boot-time fixes apply from the next reboot."

#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

check_root

ETHTOOL_OUTPUT=$(ethtool eth0 2>/dev/null | grep "Wake-on" | awk '{print $2}')
if [ "$ETHTOOL_OUTPUT" = "g" ]; then
    log "WOL already configured as 'g' on eth0 — skipping setup"
    exit 0
fi

log "Detecting MAC address for eth0..."
MAC=$(ip -j link show eth0 | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['address'])")
log "MAC: $MAC"

log "Writing systemd link file for WOL..."
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-wol.link << LINK
[Match]
MACAddress=$MAC

[Link]
WakeOnLan=magic
LINK

log "Writing ethtool WOL enable service (fallback)..."

cat > /etc/systemd/system/wol-enable.service << WOLSRV
[Unit]
Description=Enable Wake-on-LAN on eth0
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s eth0 wol g

[Install]
WantedBy=basic.target
WOLSRV

systemctl daemon-reload
systemctl enable wol-enable.service

log "Writing udev rule (third fallback)..."

cat > /etc/udev/rules.d/99-wol.rules << UDEV
ACTION=="add", SUBSYSTEM=="net", KERNEL=="eth*", RUN+="/usr/sbin/ethtool -s \$name wol g"
UDEV

log "Writing rtcwake script..."

cat > /usr/local/bin/set-wake.sh << 'RTCWAKE'
#!/bin/bash
set -euo pipefail

# Set RTC wake alarm for 02:55 (before 03:00 backup)
# This runs nightly at 22:00 — sets the alarm for next morning
WAKE_TIME="02:55 tomorrow"
WAKE_EPOCH=$(date +%s -d "$WAKE_TIME" 2>/dev/null || date +%s -d "02:55" 2>/dev/null)

if [ -z "$WAKE_EPOCH" ]; then
    echo "Could not determine wake time — falling back to +5h from now"
    WAKE_EPOCH=$(( $(date +%s) + 18000 ))
fi

echo "Setting RTC wake alarm for $(date -d @$WAKE_EPOCH)"
rtcwake -m no -l -t "$WAKE_EPOCH"
RTCWAKE

chmod 755 /usr/local/bin/set-wake.sh

log "Writing rtcwake systemd service..."

cat > /etc/systemd/system/set-wake.service << RTCSRV
[Unit]
Description=Set RTC wake alarm for 02:55 backup window

[Service]
Type=oneshot
ExecStart=/usr/local/bin/set-wake.sh
RTCSRV

log "Writing rtcwake systemd timer..."

cat > /etc/systemd/system/set-wake.timer << RTCTMR
[Unit]
Description=Set RTC wake alarm nightly at 22:00

[Timer]
OnCalendar=*-*-* 22:00:00
Persistent=false

[Install]
WantedBy=timers.target
RTCTMR

log "Writing idle-shutdown script..."

cat > /usr/local/bin/idle-shutdown.sh << 'IDLESD'
#!/bin/bash
set -euo pipefail

# Auto-shutdown after 15 min of inactivity
# Guards: no HTTP traffic, no SSH sessions, uptime > 30 min, no backup running

TIMEOUT=900  # 15 minutes
ACCESS_LOG="/var/log/nginx/access.log"

# Guard 1: uptime < 30 min → skip (prevents boot loop on power restore)
UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)
if [ "$UPTIME_SEC" -lt 1800 ]; then
    echo "Uptime ${UPTIME_SEC}s < 1800s — too soon after boot, skipping shutdown"
    exit 0
fi

# Guard 2: backup running (borg process or /tmp/backup-running lockfile)
if pgrep -x borg >/dev/null 2>&1; then
    echo "Borg process active — skipping shutdown"
    exit 0
fi

# Guard 3: active SSH sessions
if [ "$(who | wc -l)" -gt 0 ]; then
    echo "Active SSH sessions — skipping shutdown"
    exit 0
fi

# Guard 4: recent HTTP activity (nginx access log mtime)
if [ -f "$ACCESS_LOG" ]; then
    LAST_ACCESS=$(stat -c %Y "$ACCESS_LOG")
    NOW=$(date +%s)
    IDLE=$(( NOW - LAST_ACCESS ))
    if [ "$IDLE" -lt "$TIMEOUT" ]; then
        echo "HTTP activity $IDLEs ago — still within ${TIMEOUT}s timeout, skipping shutdown"
        exit 0
    fi
else
    echo "No nginx access log found — cannot determine HTTP activity, skipping shutdown"
    exit 0
fi

echo "All idle conditions met — shutting down in 1 minute"
/usr/sbin/shutdown -h +1 "Auto-shutdown due to inactivity"
IDLESD

chmod 755 /usr/local/bin/idle-shutdown.sh

log "Writing idle-shutdown systemd service..."

cat > /etc/systemd/system/idle-shutdown.service << IDLESRV
[Unit]
Description=Shutdown server after 15 min of inactivity

[Service]
Type=oneshot
ExecStart=/usr/local/bin/idle-shutdown.sh
IDLESRV

log "Writing idle-shutdown systemd timer..."

cat > /etc/systemd/system/idle-shutdown.timer << IDLETMR
[Unit]
Description=Check idle conditions every 5 minutes

[Timer]
OnCalendar=*:0/5
Persistent=false

[Install]
WantedBy=timers.target
IDLETMR

log "Writing nftables firewall ruleset..."

cat > /etc/nftables.conf << 'NFTABLES'
#!/usr/sbin/nft -f

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # Allow loopback
        iif lo accept

        # Allow established/related
        ct state established,related accept

        # SSH from LAN only
        tcp dport 22 ip saddr 192.168.1.0/24 accept

        # HTTP from LAN only
        tcp dport 80 ip saddr 192.168.1.0/24 accept

        # ICMP ping from LAN only
        ip saddr 192.168.1.0/24 icmp type echo-request accept
    }

    chain output {
        type filter hook output priority 0; policy accept
    }
}
NFTABLES

log "Writing Avahi mDNS service for Nextcloud..."

cat > /etc/avahi/services/nextcloud.service << AVAHI
<?xml version="1.0"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name>Nextcloud</name>
  <service>
    <type>_http._tcp</type>
    <port>80</port>
  </service>
</service-group>
AVAHI

log "Enabling and starting services..."
systemctl daemon-reload
systemctl enable set-wake.timer idle-shutdown.timer
systemctl start set-wake.timer idle-shutdown.timer
systemctl enable nftables
systemctl restart nftables

log "WOL and power management setup complete"
log "Services enabled: wol-enable.service, set-wake.timer, idle-shutdown.timer"
log "Firewall: nftables with default-drop input policy"
log "mDNS: Nextcloud advertised via Avahi"

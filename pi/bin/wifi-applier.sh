#!/usr/bin/env bash
# Apply a pending WiFi profile from wifi-update.txt on the boot partition.
# Runs as a systemd oneshot at early boot (Before=network-online.target).
set -euo pipefail

DEFAULTS="${PICAM_DEFAULTS:-/etc/picam/defaults.conf}"
# shellcheck source=/dev/null
source <(sed 's/\r//g' "$DEFAULTS" 2>/dev/null || true)

BOOT_PICAM="${PICAM_BOOT_DIR:-/boot/firmware/picam}"
STATUS_LOG="${STATUS_LOG:-/boot/firmware/picam/status.log}"
NMCLI="${PICAM_NMCLI:-nmcli}"
WIFI_UPDATE="$BOOT_PICAM/wifi-update.txt"

_log() {
  echo "[wifi-applier] $*"
  echo "$(date -u '+%Y-%m-%d %H:%M:%S') | $*" >> "$STATUS_LOG"
}

# Nothing to do when no update file is present
[ -f "$WIFI_UPDATE" ] || exit 0

# Parse file — CRLF-tolerant
SSID=""
PASS=""
PRIORITY=0
while IFS='=' read -r key val; do
  key="${key//$'\r'/}"
  val="${val//$'\r'/}"
  case "$key" in
    SSID)     SSID="$val" ;;
    PASS)     PASS="$val" ;;
    PRIORITY) PRIORITY="$val" ;;
  esac
done < "$WIFI_UPDATE"

# Write .failed record and exit non-zero
_fail() {
  local reason="$1"
  {
    printf 'ERROR: %s\n' "$reason"
    grep -v '^PASS=' "$WIFI_UPDATE" || true
  } > "$BOOT_PICAM/wifi-update.failed"
  rm -f "$WIFI_UPDATE"
  _log "WIFI FAIL | reason=$reason"
  exit 1
}

# Validate
[ -n "$SSID" ]         || _fail "SSID is empty"
[ "${#PASS}" -ge 8 ]   || _fail "PASS must be at least 8 characters"

# Add or modify profile — never delete other profiles
if "$NMCLI" connection show "$SSID" >/dev/null 2>&1; then
  "$NMCLI" connection modify "$SSID" \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "$PASS" \
    connection.autoconnect yes \
    connection.autoconnect-priority "$PRIORITY"
else
  "$NMCLI" connection add \
    type wifi \
    ifname wlan0 \
    con-name "$SSID" \
    ssid "$SSID" \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "$PASS" \
    connection.autoconnect yes \
    connection.autoconnect-priority "$PRIORITY"
fi

# Attempt activation (60 s timeout)
if "$NMCLI" --wait 60 connection up "$SSID"; then
  grep -v '^PASS=' "$WIFI_UPDATE" > "$BOOT_PICAM/wifi-update.applied"
  rm -f "$WIFI_UPDATE"
  _log "WIFI OK | ssid=$SSID"
else
  _fail "activation failed (nmcli connection up returned non-zero)"
fi

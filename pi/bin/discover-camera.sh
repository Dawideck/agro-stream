#!/usr/bin/env bash
# Find camera IP by MAC; manage IP cache.
# Exit codes: 0=found (IP on stdout), 2=no network, 3=camera not found.
# NEVER uses ICMP ping — camera is confirmed to ignore it.
set -euo pipefail

DEFAULTS="${PICAM_DEFAULTS:-/etc/picam/defaults.conf}"
# shellcheck source=/dev/null
source <(sed 's/\r//g' "$DEFAULTS" 2>/dev/null || true)

CAMERA_MAC="${CAMERA_MAC:-00:46:b8:28:e2:55}"
CAMERA_IP_CACHE="${CAMERA_IP_CACHE:-/var/lib/picam/camera_ip}"
STATUS_LOG="${STATUS_LOG:-/boot/firmware/picam/status.log}"
ARPSCAN="${PICAM_ARPSCAN:-arp-scan}"
IP_CMD="${PICAM_IP_CMD:-ip}"
TCP_CHECK="${PICAM_TCP_CHECK:-}"

_log() {
  echo "[discover-camera] $*" >&2
  echo "$(date -u '+%Y-%m-%d %H:%M:%S') | $*" >> "$STATUS_LOG" 2>/dev/null || true
}

# Normalize MAC to lowercase colon-separated with two-digit octets.
# Handles: dashes, uppercase, stripped leading zeros.
normalize_mac() {
  local mac="$1" result='' octet padded
  mac="${mac//-/:}"
  local IFS=':'
  for octet in $mac; do
    printf -v padded '%02x' "0x${octet}"
    result="${result:+$result:}$padded"
  done
  printf '%s' "$result"
}

# TCP liveness check — never ICMP (camera ignores ping).
tcp_alive() {
  local ip="$1" port="$2"
  if [ -n "$TCP_CHECK" ]; then
    "$TCP_CHECK" "$ip" "$port"
  else
    timeout 2 bash -c ">/dev/tcp/$ip/$port" 2>/dev/null
  fi
}

# Check network availability via default route.
if ! "$IP_CMD" route show default 2>/dev/null | grep -q .; then
  _log "DISCOVER FAIL | reason=no default route (no network)"
  exit 2
fi

TARGET_MAC=$(normalize_mac "$CAMERA_MAC")

# 1. Try cached IP first (TCP connect, not ping).
if [ -f "$CAMERA_IP_CACHE" ]; then
  cached_ip=$(cat "$CAMERA_IP_CACHE")
  if [ -n "$cached_ip" ] && \
     { tcp_alive "$cached_ip" 80 || tcp_alive "$cached_ip" 554; }; then
    echo "$cached_ip"
    exit 0
  fi
fi

# 2. ARP scan the local network and match by MAC.
found_ip=""
while IFS=$'\t' read -r ip mac _vendor; do
  if [ "$(normalize_mac "$mac")" = "$TARGET_MAC" ]; then
    found_ip="$ip"
    break
  fi
done < <("$ARPSCAN" --localnet 2>/dev/null \
          | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')

if [ -n "$found_ip" ]; then
  echo "$found_ip" > "$CAMERA_IP_CACHE"
  echo "$found_ip"
  _log "DISCOVER OK | ip=$found_ip mac=$TARGET_MAC"
  exit 0
fi

_log "DISCOVER FAIL | reason=camera not found (mac=$TARGET_MAC)"
exit 3

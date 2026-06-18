#!/usr/bin/env bash
# Capture one JPEG snapshot from the camera and save it.
# Injections for testing: PICAM_DEFAULTS, PICAM_BOOT_DIR,
#   PICAM_CURL, PICAM_DISCOVER.
set -euo pipefail

DEFAULTS="${PICAM_DEFAULTS:-/etc/picam/defaults.conf}"
# shellcheck source=/dev/null
source <(sed 's/\r//g' "$DEFAULTS" 2>/dev/null || true)

BOOT_PICAM="${PICAM_BOOT_DIR:-/boot/firmware/picam}"
for _conf in "$BOOT_PICAM/capture.conf" "$BOOT_PICAM/camera.conf"; do
  # shellcheck source=/dev/null
  source <(sed 's/\r//g' "$_conf" 2>/dev/null || true)
done
unset _conf

CURL="${PICAM_CURL:-curl}"
DISCOVER="${PICAM_DISCOVER:-discover-camera.sh}"

_log() {
  echo "[capture] $*"
  status-write.sh "capture | $*" 2>/dev/null || true
}

_inc_fail() {
  local n=0
  n=$(grep -oE '^[0-9]+' "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
  printf '%d\n' $(( n + 1 )) > "$FAIL_COUNT_FILE"
}

_fail() {
  _log "FAIL: $*"
  _inc_fail
  exit 1
}

_get_ip() {
  [ "${1:-}" = force ] && rm -f "$CAMERA_IP_CACHE"
  $DISCOVER
}

_shoot() {
  local ip="$1"
  local url="${SNAPSHOT_URL//\{IP\}/$ip}"
  local ts_dir ts_file
  ts_dir=$(date -u +%Y-%m-%d)
  ts_file=$(date -u +%H%M%S)
  local dest_dir="$JPEG_DIR/$ts_dir"
  local dest="$dest_dir/$ts_file.jpg"

  mkdir -p "$dest_dir"

  local tmp
  tmp=$(mktemp)

  $CURL --silent --show-error --max-time 15 \
    --digest --user "$CAMERA_USER:$CAMERA_PASS" \
    -o "$tmp" "$url" || { rm -f "$tmp"; return 1; }

  local magic size
  magic=$(od -A n -N 2 -t x1 "$tmp" | tr -d ' \n')
  size=$(wc -c < "$tmp" | tr -d ' ')

  if [ "$magic" != "ffd8" ] || [ "$size" -lt 10240 ]; then
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$dest"
  printf '%d\n' "$(date -u +%s)" > "$LAST_SHOT_STAMP"
  printf '0\n' > "$FAIL_COUNT_FILE"
  _log "OK: $dest ($size bytes)"
  cp "$dest" "$BOOT_PICAM/last_photo.jpg" 2>/dev/null || true
  return 0
}

_cleanup() {
  local today_epoch
  today_epoch=$(date -u +%s)
  for dir in "$JPEG_DIR"/????-??-??; do
    [ -d "$dir" ] || continue
    local name="${dir##*/}"
    local dir_epoch
    # Try GNU date first, fall back to BSD date (macOS).
    dir_epoch=$(date -u -d "$name 00:00:00" +%s 2>/dev/null) \
      || dir_epoch=$(date -u -j -f '%Y-%m-%d %H:%M:%S' "$name 00:00:00" +%s 2>/dev/null) \
      || continue
    local age=$(( (today_epoch - dir_epoch) / 86400 ))
    if [ "$age" -gt "${RETENTION_DAYS:-30}" ]; then
      rm -rf "$dir"
      _log "pruned $name (>${RETENTION_DAYS:-30}d)"
    fi
  done
}

# --- main ---
ip=$(_get_ip) || _fail "camera not found"

if ! _shoot "$ip"; then
  _log "retry after forced rediscovery"
  ip=$(_get_ip force) || _fail "camera not found on retry"
  _shoot "$ip" || _fail "snapshot failed after rediscovery"
fi

_cleanup

#!/usr/bin/env bash
# Boot + hourly health check.
# Boot mode (first run after power-on): network + live camera snapshot.
# Hourly mode: network + last-photo age within schedule slack.
#   Inside window: stale if age > 3×INTERVAL_MIN (tight — camera is expected live).
#   Outside window: stale only if age > overnight_gap + slack (no false alerts).
# Both modes: disk space > 500 MB; R2 reachable (if enabled).
# Injections for testing: PICAM_DEFAULTS, PICAM_BOOT_DIR, PICAM_HC_MODE,
#   PICAM_BOOT_MARKER, PICAM_IP_CMD, PICAM_PING, PICAM_DISCOVER, PICAM_CURL,
#   PICAM_SYSTEMCTL, PICAM_ALERT, PICAM_DISK_AVAIL_KB, PICAM_LIB, PICAM_NOW_HHMM.
set -euo pipefail

DEFAULTS="${PICAM_DEFAULTS:-/etc/picam/defaults.conf}"
# shellcheck source=/dev/null
source <(sed 's/\r//g' "$DEFAULTS" 2>/dev/null || true)

BOOT_PICAM="${PICAM_BOOT_DIR:-/boot/firmware/picam}"
for _conf in "$BOOT_PICAM/capture.conf" "$BOOT_PICAM/camera.conf" \
             "$BOOT_PICAM/r2.conf"; do
  # shellcheck source=/dev/null
  source <(sed 's/\r//g' "$_conf" 2>/dev/null || true)
done
unset _conf

LIBSH="${PICAM_LIB:-/usr/local/bin/picam-lib.sh}"
# shellcheck source=/dev/null
source "$LIBSH"

CURL="${PICAM_CURL:-curl}"
DISCOVER="${PICAM_DISCOVER:-discover-camera.sh}"
IP_CMD="${PICAM_IP_CMD:-ip}"
PING="${PICAM_PING:-ping}"
SYSTEMCTL="${PICAM_SYSTEMCTL:-systemctl}"
ALERT="${PICAM_ALERT:-alert.sh}"

# Detect boot vs hourly via a tmpfs marker (cleared on each reboot).
BOOT_MARKER="${PICAM_BOOT_MARKER:-/run/picam/hc_booted}"
if [ "${PICAM_HC_MODE:-auto}" = "auto" ]; then
  if [ ! -f "$BOOT_MARKER" ]; then
    mode=boot
    touch "$BOOT_MARKER" 2>/dev/null || true
  else
    mode=hourly
  fi
else
  mode="$PICAM_HC_MODE"
fi

_log() {
  echo "[healthcheck/$mode] $*"
  status-write.sh "healthcheck | $*" 2>/dev/null || true
}

# ---- Counters ----
_read_n() { grep -oE '^[0-9]+' "$1" 2>/dev/null || echo 0; }
_inc_n()   { printf '%d\n' "$(( $(_read_n "$1") + 1 ))" > "$1"; }
_reset_n() { printf '0\n' > "$1"; }

# ---- Check 1: Network ----
_check_network() {
  local gw
  gw=$($IP_CMD route show default 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  [ -n "$gw" ] || return 1
  $PING -c1 -W2 "$gw" >/dev/null 2>&1
}

# ---- Check 2a: Camera — live snapshot (boot) ----
_check_camera_boot() {
  local ip url tmp magic
  ip=$($DISCOVER 2>/dev/null) || return 1
  url="${SNAPSHOT_URL//\{IP\}/$ip}"
  tmp=$(mktemp)
  $CURL --silent --max-time 15 --digest \
    --user "$CAMERA_USER:$CAMERA_PASS" -o "$tmp" "$url" \
    || { rm -f "$tmp"; return 1; }
  magic=$(od -A n -N 2 -t x1 "$tmp" | tr -d ' \n')
  rm -f "$tmp"
  [ "$magic" = "ffd8" ]
}

# ---- Check 2b: Camera — last photo age (hourly) ----
_check_camera_hourly() {
  local last=0 age_sec max_age
  [ -f "$LAST_SHOT_STAMP" ] \
    && last=$(grep -oE '^[0-9]+' "$LAST_SHOT_STAMP" 2>/dev/null || echo 0)
  age_sec=$(( $(date -u +%s) - last ))

  local now_hm
  now_hm="${PICAM_NOW_HHMM:-$(date -u +%H:%M)}"

  if _in_window "$now_hm"; then
    # Inside window: camera should be shooting — tolerate at most 3 missed intervals.
    max_age=$(( ${INTERVAL_MIN:-30} * 3 * 60 ))
  else
    # Outside window: tolerate overnight gap + 2 intervals + 1h slack.
    local ws we wdur overnight
    ws=$(_to_min "${WINDOW_START:-07:00}")
    we=$(_to_min "${WINDOW_END:-18:00}")
    if [ "$ws" -le "$we" ]; then
      wdur=$(( (we - ws) * 60 ))
    else
      wdur=$(( (1440 - ws + we) * 60 ))
    fi
    overnight=$(( 86400 - wdur ))
    max_age=$(( overnight + ${INTERVAL_MIN:-30} * 120 + 3600 ))
  fi

  [ "$age_sec" -le "$max_age" ]
}

# ---- Check 3: Disk ----
_check_disk() {
  local avail_kb
  if [ -n "${PICAM_DISK_AVAIL_KB:-}" ]; then
    avail_kb="$PICAM_DISK_AVAIL_KB"
  else
    mkdir -p "$JPEG_DIR"
    avail_kb=$(df -k "$JPEG_DIR" 2>/dev/null | awk 'NR==2{print $4}' || echo 999999)
  fi
  [ "$avail_kb" -ge $(( 500 * 1024 )) ]
}

_prune_oldest_day() {
  local oldest
  oldest=$(find "$JPEG_DIR" -maxdepth 1 -type d -name '????-??-??' 2>/dev/null \
    | sort | head -1 || true)
  if [ -n "$oldest" ]; then
    rm -rf "$oldest"
    _log "disk low: pruned ${oldest##*/}"
  fi
}

# ---- Network escalation ----
_escalate_network() {
  local n
  n=$(_read_n "$NETWORK_FAIL_COUNT_FILE")
  if [ "$n" -ge "${HEALTH_FAIL_REBOOT_THRESHOLD:-6}" ]; then
    local last_reboot=0 now cooldown
    [ -f "$LAST_REBOOT_FILE" ] \
      && last_reboot=$(grep -oE '^[0-9]+' "$LAST_REBOOT_FILE" 2>/dev/null || echo 0)
    now=$(date -u +%s)
    cooldown=$(( now - last_reboot ))
    if [ "$cooldown" -ge "${HEALTH_REBOOT_COOLDOWN_SEC:-21600}" ]; then
      _log "FAIL: network (${n}x) → rebooting"
      printf '%d\n' "$now" > "$LAST_REBOOT_FILE"
      $SYSTEMCTL reboot
    else
      _log "WARN: network (${n}x), reboot in cooldown (${cooldown}s < ${HEALTH_REBOOT_COOLDOWN_SEC:-21600}s)"
    fi
  elif [ "$n" -ge "${HEALTH_FAIL_NETWORK_RESTART_THRESHOLD:-3}" ]; then
    _log "WARN: network (${n}x) → restarting NetworkManager"
    $SYSTEMCTL restart NetworkManager 2>/dev/null || true
  fi
}

# ============================================================
overall=OK

# ---- Network ----
if _check_network; then
  _reset_n "$NETWORK_FAIL_COUNT_FILE"
  _log "OK: network up"
else
  overall=FAIL
  _inc_n "$NETWORK_FAIL_COUNT_FILE"
  local_n=$(_read_n "$NETWORK_FAIL_COUNT_FILE")
  _log "FAIL: network down (${local_n}x)"
  _escalate_network
fi

# ---- Camera ----
cam_ok=0
if [ "$mode" = "boot" ]; then
  if _check_camera_boot; then
    cam_ok=1
    _log "OK: camera snapshot verified"
  else
    overall=FAIL
    _log "FAIL: camera unreachable or snapshot invalid"
  fi
else
  if _check_camera_hourly; then
    cam_ok=1
    _log "OK: last photo within expected age"
  else
    overall=FAIL
    stale_sec=$(( $(date -u +%s) - \
      $(grep -oE '^[0-9]+' "$LAST_SHOT_STAMP" 2>/dev/null || echo 0) ))
    _log "WARN: last photo stale (${stale_sec}s)"
  fi
fi

_cam_alert_file="${LAST_CAMERA_ALERT_FILE:-/var/lib/picam/last_camera_alert}"
if [ "$cam_ok" -eq 0 ]; then
  _inc_n "$FAIL_COUNT_FILE"
  cam_n=$(_read_n "$FAIL_COUNT_FILE")
  if [ "$cam_n" -ge "${HEALTH_CAMERA_ALERT_THRESHOLD:-2}" ]; then
    last_alerted=0
    [ -f "$_cam_alert_file" ] \
      && last_alerted=$(grep -oE '^[0-9]+' "$_cam_alert_file" 2>/dev/null || echo 0)
    alert_elapsed=$(( $(date -u +%s) - last_alerted ))
    if [ "$alert_elapsed" -ge "${CAMERA_ALERT_COOLDOWN_SEC:-3600}" ]; then
      _log "WARN: camera fail (${cam_n}x) → sending alert"
      $ALERT "PiCam: camera unavailable (${cam_n}x consecutive)" 2>/dev/null || true
      printf '%d\n' "$(date -u +%s)" > "$_cam_alert_file"
    else
      _log "WARN: camera fail (${cam_n}x), alert cooldown (${alert_elapsed}s)"
    fi
  fi
else
  prev_cam_n=$(_read_n "$FAIL_COUNT_FILE")
  if [ -f "$_cam_alert_file" ]; then
    _log "OK: camera recovered (after ${prev_cam_n}x failures) → sending recovery alert"
    $ALERT "PiCam: camera recovered (was unavailable for ${prev_cam_n} consecutive checks)" \
      2>/dev/null || true
    rm -f "$_cam_alert_file"
  fi
  _reset_n "$FAIL_COUNT_FILE"
fi

# ---- Disk ----
if _check_disk; then
  _log "OK: disk space sufficient"
else
  _log "WARN: disk low (<500 MB), pruning oldest day"
  _prune_oldest_day
  [ "$overall" = "OK" ] && overall=WARN
fi

# ---- R2 reachability (if enabled) ----
if [ "${R2_ENABLED:-false}" = "true" ] && [ -n "${R2_ACCOUNT_ID:-}" ]; then
  r2_url="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET:-agrosfera}/"
  r2_code=$("$CURL" -s -o /dev/null -w '%{http_code}' \
    --connect-timeout 10 "$r2_url" 2>/dev/null || echo 0)
  case "$r2_code" in
    2*|400|403|404) _log "OK: R2 reachable (HTTP $r2_code)" ;;
    *) _log "WARN: R2 unreachable (HTTP $r2_code)"
       [ "$overall" = "OK" ] && overall=WARN ;;
  esac
fi

_log "summary: $overall"
[ "$overall" != "FAIL" ] || exit 1

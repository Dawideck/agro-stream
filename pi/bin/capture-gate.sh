#!/usr/bin/env bash
# Decide once per minute whether it is time to take a photo.
# If yes: exec capture.sh (replaces this process).
# Injections for testing: PICAM_DEFAULTS, PICAM_CAPTURE_CONF,
#   PICAM_NOW_HHMM, PICAM_NOW_EPOCH, PICAM_CAPTURE.
set -euo pipefail

DEFAULTS="${PICAM_DEFAULTS:-/etc/picam/defaults.conf}"
# shellcheck source=/dev/null
source <(sed 's/\r//g' "$DEFAULTS" 2>/dev/null || true)

CAPTURE_CONF="${PICAM_CAPTURE_CONF:-/boot/firmware/picam/capture.conf}"
# shellcheck source=/dev/null
source <(sed 's/\r//g' "$CAPTURE_CONF" 2>/dev/null || true)

LIBSH="${PICAM_LIB:-/usr/local/bin/picam-lib.sh}"
# shellcheck source=/dev/null
source "$LIBSH"

CAPTURE="${PICAM_CAPTURE:-/usr/local/bin/capture.sh}"
now_hm="${PICAM_NOW_HHMM:-$(date -u +%H:%M)}"
now_epoch="${PICAM_NOW_EPOCH:-$(date -u +%s)}"

_last_shot_epoch() {
  local f="${LAST_SHOT_STAMP:-/run/picam/last_shot}"
  if [ -f "$f" ]; then
    grep -oE '^[0-9]+' "$f" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

should_fire=0

case "${MODE:-interval}" in
  times)
    IFS=',' read -ra tlist <<< "${TIMES:-}"
    for t in "${tlist[@]}"; do
      t="${t// /}"
      if [ "$now_hm" = "$t" ]; then
        last=$(_last_shot_epoch)
        elapsed=$(( now_epoch - last ))
        # Guard against double-fire when the timer fires twice inside one minute.
        [ "$elapsed" -gt 60 ] && should_fire=1
        break
      fi
    done
    ;;
  interval)
    if _in_window "$now_hm"; then
      last=$(_last_shot_epoch)
      elapsed=$(( now_epoch - last ))
      interval_sec=$(( ${INTERVAL_MIN:-30} * 60 ))
      [ "$elapsed" -ge "$interval_sec" ] && should_fire=1
    fi
    ;;
esac

if [ "$should_fire" -eq 1 ]; then
  exec "$CAPTURE"
fi

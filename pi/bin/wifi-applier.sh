#!/usr/bin/env bash
set -euo pipefail
# Stub — full implementation in build step 2.
DEFAULTS="${PICAM_DEFAULTS:-/etc/picam/defaults.conf}"
# shellcheck source=/dev/null
source <(sed 's/\r//g' "$DEFAULTS" 2>/dev/null || true)

WIFI_UPDATE="${PICAM_BOOT_DIR:-/boot/firmware/picam}/wifi-update.txt"
[ -f "$WIFI_UPDATE" ] || exit 0

echo "[wifi-applier] not yet implemented" >&2
exit 1

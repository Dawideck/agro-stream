#!/usr/bin/env bash
# Append one status line to STATUS_LOG and rotate at STATUS_LOG_MAX_LINES.
# Usage: status-write.sh "TOKEN VALUE | TOKEN VALUE | ..."
set -euo pipefail

DEFAULTS="${PICAM_DEFAULTS:-/etc/picam/defaults.conf}"
# shellcheck source=/dev/null
source <(sed 's/\r//g' "$DEFAULTS" 2>/dev/null || true)

STATUS_LOG="${STATUS_LOG:-/boot/firmware/picam/status.log}"
STATUS_LOG_MAX_LINES="${STATUS_LOG_MAX_LINES:-200}"

ts=$(date -u '+%Y-%m-%d %H:%M:%S')
echo "$ts | $*" >> "$STATUS_LOG"

line_count=$(wc -l < "$STATUS_LOG")
if [ "$line_count" -gt "$STATUS_LOG_MAX_LINES" ]; then
  tmp=$(mktemp)
  tail -n "$STATUS_LOG_MAX_LINES" "$STATUS_LOG" > "$tmp"
  mv "$tmp" "$STATUS_LOG"
fi

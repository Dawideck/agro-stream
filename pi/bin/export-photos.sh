#!/usr/bin/env bash
# Copy photos in a date range to a user-readable directory for scp download.
# Usage: sudo export-photos.sh [--from YYYY-MM-DD] [--to YYYY-MM-DD]
# No arguments: export entire photo history.
# Injectables: PICAM_JPEG_DIR, PICAM_EXPORT_DIR, PICAM_OWNER, PICAM_CHOWN
set -euo pipefail

JPEG_DIR="${PICAM_JPEG_DIR:-/var/lib/picam/photos}"
EXPORT_DIR="${PICAM_EXPORT_DIR:-/home/pi/picam-export}"
# Prefer the invoking user (sudo preserves SUDO_USER); fall back to pi
OWNER="${PICAM_OWNER:-${SUDO_USER:-pi}}"
CHOWN_CMD="${PICAM_CHOWN:-chown}"

FROM_DATE=""
TO_DATE=""

# ---- Arg parsing -------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM_DATE="$2"; shift 2 ;;
    --to)   TO_DATE="$2";   shift 2 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# ---- Validate dates ----------------------------------------------------------
_valid_date() {
  printf '%s' "$1" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
}

if [ -n "$FROM_DATE" ] && ! _valid_date "$FROM_DATE"; then
  printf 'Invalid --from date: %s (expected YYYY-MM-DD)\n' "$FROM_DATE" >&2
  exit 1
fi
if [ -n "$TO_DATE" ] && ! _valid_date "$TO_DATE"; then
  printf 'Invalid --to date: %s (expected YYYY-MM-DD)\n' "$TO_DATE" >&2
  exit 1
fi

# ---- Copy matching day directories -------------------------------------------
if [ ! -d "$JPEG_DIR" ]; then
  printf 'Photo directory not found: %s\n' "$JPEG_DIR" >&2
  exit 1
fi

rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
count=0

for day_dir in "$JPEG_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/; do
  [ -d "$day_dir" ] || continue
  day=$(basename "$day_dir")

  # YYYY-MM-DD sorts lexicographically — string comparison is correct here
  [ -n "$FROM_DATE" ] && [[ "$day" < "$FROM_DATE" ]] && continue
  [ -n "$TO_DATE" ]   && [[ "$day" > "$TO_DATE" ]]   && continue

  cp -r "${JPEG_DIR}/${day}" "$EXPORT_DIR/"
  count=$(( count + 1 ))
done

if [ "$count" -eq 0 ]; then
  printf 'No photos found'
  [ -n "$FROM_DATE" ] && printf ' from %s' "$FROM_DATE"
  [ -n "$TO_DATE" ]   && printf ' to %s' "$TO_DATE"
  printf '.\n'
  exit 0
fi

"$CHOWN_CMD" -R "$OWNER:$OWNER" "$EXPORT_DIR"

PI_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
PI_ADDR="${PI_IP:-pi.local}"

printf '\nExported %d day(s) to %s (owner: %s)\n' "$count" "$EXPORT_DIR" "$OWNER"
printf '\nDownload on your Mac:\n'
printf '  scp -r %s@%s:%s ./picam-photos\n\n' "$OWNER" "$PI_ADDR" "$EXPORT_DIR"

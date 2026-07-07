#!/usr/bin/env bash
# Send a rate-limited email alert via Gmail SMTP.
# Usage: alert.sh "message text"
# Config: /boot/firmware/picam/alert.conf (FROM, TO, SMTP_USER, SMTP_PASS)
# Injectables: PICAM_BOOT_DIR, PICAM_CURL, PICAM_ALERT_CONF,
#   PICAM_ALERT_STATE_DIR, PICAM_NOW_DATE, PICAM_NOW_EPOCH
set -euo pipefail

BOOT_PICAM="${PICAM_BOOT_DIR:-/boot/firmware/picam}"
ALERT_CONF="${PICAM_ALERT_CONF:-$BOOT_PICAM/alert.conf}"
STATE_DIR="${PICAM_ALERT_STATE_DIR:-/var/lib/picam}"
CURL="${PICAM_CURL:-curl}"

MSG="${*:-PiCam alert}"

# ---- Load alert config -------------------------------------------------------
if [ ! -f "$ALERT_CONF" ]; then
  logger -t picam "alert: $ALERT_CONF not found — skipping"
  exit 0
fi
# eval avoids bash 3.2 source+process-substitution timing issue.
# shellcheck disable=SC2046,SC2086
eval "$(sed 's/\r//g' "$ALERT_CONF" 2>/dev/null || true)"

# Required fields
if [ -z "${SMTP_USER:-}" ] || [ -z "${SMTP_PASS:-}" ] || \
   [ -z "${FROM:-}" ]     || [ -z "${TO:-}" ]; then
  logger -t picam "alert: incomplete alert.conf (need FROM TO SMTP_USER SMTP_PASS) — skipping"
  exit 0
fi

RATE_LIMIT="${RATE_LIMIT_PER_DAY:-3}"

# ---- Rate limiting -----------------------------------------------------------
TODAY="${PICAM_NOW_DATE:-$(date -u +%Y-%m-%d)}"
RATE_FILE="$STATE_DIR/alert_rate"

# Format of RATE_FILE: "DATE COUNT"
current_date=""
current_count=0
if [ -f "$RATE_FILE" ]; then
  current_date=$(awk '{print $1}' "$RATE_FILE" 2>/dev/null || true)
  current_count=$(awk '{print $2}' "$RATE_FILE" 2>/dev/null || echo 0)
fi

if [ "$current_date" != "$TODAY" ]; then
  current_count=0
fi

if [ "$current_count" -ge "$RATE_LIMIT" ]; then
  logger -t picam "alert: rate limit reached ($current_count/$RATE_LIMIT today) — skipping"
  exit 0
fi

new_count=$(( current_count + 1 ))
printf '%s %d\n' "$TODAY" "$new_count" > "$RATE_FILE"

# ---- Build email -------------------------------------------------------------
HOSTNAME_VAL="${PICAM_HOSTNAME:-$(hostname 2>/dev/null || echo pi)}"
SUBJECT="PiCam alert — $HOSTNAME_VAL"
DATE_HDR=$(date -u -R 2>/dev/null || date -u +"%a, %d %b %Y %H:%M:%S +0000")

read -r -d '' EMAIL_BODY <<EOF || true
From: $FROM
To: $TO
Subject: $SUBJECT
Date: $DATE_HDR
Content-Type: text/plain; charset=UTF-8

$MSG

--
Sent by PiCam ($HOSTNAME_VAL) at $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Alert $new_count/$RATE_LIMIT today.
EOF

# ---- Send via Gmail SMTP -----------------------------------------------------
$CURL --silent --show-error \
  --url "smtps://smtp.gmail.com:465" \
  --ssl-reqd \
  --mail-from "$FROM" \
  --mail-rcpt "$TO" \
  --user "$SMTP_USER:$SMTP_PASS" \
  --upload-file - \
  <<< "$EMAIL_BODY" 2>&1 | logger -t picam || {
    logger -t picam "alert: curl send failed (alert $new_count)"
    exit 1
  }

logger -t picam "alert: sent ($new_count/$RATE_LIMIT today): $MSG"

#!/usr/bin/env bash
# Upload the first and last photos of today to Cloudflare R2.
# Called by capture.sh after each successful capture.
#
# BOD (beginning of day): fires on the first photo of today.
# EOD (end of day): fires when the next scheduled capture would fall outside
#   the capture window — i.e. this is the last photo of the day.
#
# Injectables: PICAM_DEFAULTS, PICAM_CAPTURE_CONF, PICAM_R2_CONF, PICAM_LIB,
#   PICAM_NOW_HHMM, PICAM_NOW_DT, PICAM_CURL, PICAM_JPEG_DIR,
#   PICAM_R2_UPLOAD_DIR
set -euo pipefail

DEFAULTS="${PICAM_DEFAULTS:-/etc/picam/defaults.conf}"
# shellcheck source=/dev/null
source <(sed 's/\r//g' "$DEFAULTS" 2>/dev/null || true)

CAPTURE_CONF="${PICAM_CAPTURE_CONF:-/boot/firmware/picam/capture.conf}"
# shellcheck source=/dev/null
source <(sed 's/\r//g' "$CAPTURE_CONF" 2>/dev/null || true)

R2_CONF="${PICAM_R2_CONF:-/boot/firmware/picam/r2.conf}"
# shellcheck source=/dev/null
source <(sed 's/\r//g' "$R2_CONF" 2>/dev/null || true)

LIBSH="${PICAM_LIB:-/usr/local/bin/picam-lib.sh}"
# shellcheck source=/dev/null
source "$LIBSH"

JPEG_DIR="${PICAM_JPEG_DIR:-${JPEG_DIR:-/var/lib/picam/photos}}"
UPLOAD_DIR="${PICAM_R2_UPLOAD_DIR:-${R2_UPLOAD_DIR:-/var/lib/picam/r2-uploaded}}"
CURL="${PICAM_CURL:-curl}"
now_hm="${PICAM_NOW_HHMM:-$(date -u +%H:%M)}"

# Exit early if R2 is not enabled or credentials are absent.
if [ "${R2_ENABLED:-false}" != "true" ]; then
  exit 0
fi
if [ -z "${R2_ACCOUNT_ID:-}" ] || [ -z "${R2_ACCESS_KEY_ID:-}" ] || \
   [ -z "${R2_SECRET_ACCESS_KEY:-}" ]; then
  echo "[upload] R2 credentials incomplete — skipping" >&2
  exit 0
fi

R2_BUCKET="${R2_BUCKET:-agrosfera}"
SITE_ID="${SITE_ID:-picam}"
ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
REGION="auto"

mkdir -p "$UPLOAD_DIR"

today=$(date -u +%Y-%m-%d)
today_dir="${JPEG_DIR}/${today}"
[ -d "$today_dir" ] || exit 0

# ---------------------------------------------------------------------------
# AWS Signature Version 4 helpers
# ---------------------------------------------------------------------------

_sha256_hex_file() {
  openssl dgst -sha256 "$1" | sed 's/^.* //'
}

_sha256_hex_str() {
  printf '%s' "$1" | openssl dgst -sha256 | sed 's/^.* //'
}

# Encode a string to lowercase hex bytes (for HMAC key seed).
_str_to_hex() {
  printf '%s' "$1" | od -A n -t x1 | tr -d ' \n'
}

# HMAC-SHA256: key_hex data → hex output
_hmac_hex() {
  local key_hex="$1" data="$2"
  printf '%s' "$data" \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${key_hex}" \
    | sed 's/^.* //'
}

# Derive the AWS Sig V4 signing key for a given YYYYMMDD date.
_signing_key() {
  local date_short="$1"
  local k
  k=$(_str_to_hex "AWS4${R2_SECRET_ACCESS_KEY}")
  k=$(_hmac_hex "$k" "$date_short")
  k=$(_hmac_hex "$k" "$REGION")
  k=$(_hmac_hex "$k" "s3")
  k=$(_hmac_hex "$k" "aws4_request")
  printf '%s' "$k"
}

# PUT a single JPEG to R2 with Sig V4 auth.  Returns 0 on HTTP 2xx.
_upload_file() {
  local jpeg_path="$1" object_key="$2"
  local now_dt now_date host content_type payload_hash
  local canonical_request scope string_to_sign signing_key sig auth

  now_dt="${PICAM_NOW_DT:-$(date -u +%Y%m%dT%H%M%SZ)}"
  now_date="${now_dt:0:8}"
  host="${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  content_type="image/jpeg"
  payload_hash=$(_sha256_hex_file "$jpeg_path")

  # Headers must be sorted alphabetically.
  canonical_request="PUT
/${R2_BUCKET}/${object_key}

content-type:${content_type}
host:${host}
x-amz-content-sha256:${payload_hash}
x-amz-date:${now_dt}

content-type;host;x-amz-content-sha256;x-amz-date
${payload_hash}"

  scope="${now_date}/${REGION}/s3/aws4_request"
  string_to_sign="AWS4-HMAC-SHA256
${now_dt}
${scope}
$(_sha256_hex_str "$canonical_request")"

  signing_key=$(_signing_key "$now_date")
  sig=$(_hmac_hex "$signing_key" "$string_to_sign")
  auth="AWS4-HMAC-SHA256 Credential=${R2_ACCESS_KEY_ID}/${scope}, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature=${sig}"

  local http_code
  http_code=$("$CURL" -s -X PUT \
    -H "Authorization: ${auth}" \
    -H "Content-Type: ${content_type}" \
    -H "x-amz-content-sha256: ${payload_hash}" \
    -H "x-amz-date: ${now_dt}" \
    --data-binary "@${jpeg_path}" \
    -o /dev/null -w '%{http_code}' \
    "${ENDPOINT}/${R2_BUCKET}/${object_key}" || echo 0)

  printf '%s' "$http_code" | grep -qE '^2'
}

# ---------------------------------------------------------------------------
# BOD: upload the earliest photo of today (first of day)
# ---------------------------------------------------------------------------
sentinel_first="${UPLOAD_DIR}/${today}.first"
if [ ! -f "$sentinel_first" ]; then
  first_jpg=$(find "$today_dir" -maxdepth 1 -name '*.jpg' 2>/dev/null \
    | sort | head -1 || true)
  if [ -n "$first_jpg" ]; then
    n=$(basename "$first_jpg")
    key="${SITE_ID}/photos/${today:0:4}/${today:5:2}/${today:8:2}/${n%.jpg}.jpg"
    echo "[upload] BOD → $key"
    if _upload_file "$first_jpg" "$key"; then
      printf '%s\n' "$n" > "$sentinel_first"
      echo "[upload] BOD OK"
    else
      echo "[upload] BOD FAIL" >&2
    fi
  fi
fi

# ---------------------------------------------------------------------------
# EOD: upload the latest photo of today if this is the last capture of the day.
# "Last capture" = next scheduled interval falls outside the window.
# ---------------------------------------------------------------------------
sentinel_last="${UPLOAD_DIR}/${today}.last"
if [ ! -f "$sentinel_last" ]; then
  now_min=$(_to_min "$now_hm")
  interval_min="${INTERVAL_MIN:-30}"
  next_min=$(( (now_min + interval_min) % 1440 ))
  next_hm=$(printf '%02d:%02d' $(( next_min / 60 )) $(( next_min % 60 )))

  if ! _in_window "$next_hm"; then
    last_jpg=$(find "$today_dir" -maxdepth 1 -name '*.jpg' 2>/dev/null \
      | sort | tail -1 || true)
    if [ -n "$last_jpg" ]; then
      n=$(basename "$last_jpg")
      key="${SITE_ID}/photos/${today:0:4}/${today:5:2}/${today:8:2}/${n%.jpg}.jpg"
      echo "[upload] EOD → $key"
      if _upload_file "$last_jpg" "$key"; then
        printf '%s\n' "$n" > "$sentinel_last"
        echo "[upload] EOD OK"
      else
        echo "[upload] EOD FAIL" >&2
      fi
    fi
  fi
fi

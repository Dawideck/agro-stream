#!/usr/bin/env bash
# One-time office setup: discover ONVIF snapshot URL, write camera.conf.
# Usage: onvif-probe.sh <camera-ip>
# WS-Security math copied verbatim from verified prototype probe.sh.
set -euo pipefail

DEFAULTS="${PICAM_DEFAULTS:-/etc/picam/defaults.conf}"
# shellcheck source=/dev/null
source <(sed 's/\r//g' "$DEFAULTS" 2>/dev/null || true)

IP="${1:-}"
if [ -z "$IP" ]; then
  echo "Usage: onvif-probe.sh <camera-ip>" >&2
  exit 1
fi

CAMERA_USER="${CAMERA_USER:-admin}"
CAMERA_PASS="${CAMERA_PASS:-}"
CAMERA_MAC="${CAMERA_MAC:-00:46:b8:28:e2:55}"
DEVICE="http://$IP/onvif/device_service"
BOOT_PICAM="${PICAM_BOOT_DIR:-/boot/firmware/picam}"
STATUS_LOG="${STATUS_LOG:-/boot/firmware/picam/status.log}"
CURL="${PICAM_CURL:-curl}"

_log() {
  echo "[onvif-probe] $*"
  echo "$(date -u '+%Y-%m-%d %H:%M:%S') | $*" >> "$STATUS_LOG" 2>/dev/null || true
}

# WS-Security UsernameToken PasswordDigest.
# digest = base64(sha1(nonce_raw + created + password))
# DO NOT MODIFY — verified against real hardware (see probe.sh).
make_security_header() {
  local created="$1"
  local nonce_raw nonce_b64 digest
  nonce_raw=$(openssl rand 16)
  nonce_b64=$(printf '%s' "$nonce_raw" | openssl base64 -A)
  digest=$(
    { printf '%s' "$nonce_raw"; printf '%s%s' "$created" "$CAMERA_PASS"; } \
      | openssl dgst -sha1 -binary | openssl base64 -A
  )
  cat << EOF
<wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><wsse:UsernameToken><wsse:Username>$CAMERA_USER</wsse:Username><wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">$digest</wsse:Password><wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">$nonce_b64</wsse:Nonce><wsu:Created>$created</wsu:Created></wsse:UsernameToken></wsse:Security>
EOF
}

soap_post() {  # $1=endpoint $2=body
  "$CURL" -s -m 10 -X POST "$1" -H 'Content-Type: application/soap+xml' -d "$2"
}

# Get camera UTC time for clock-skew-safe WS-Security timestamps.
# Falls back to Pi time if camera time is unavailable.
get_camera_created() {
  local resp year month day hour minute second
  resp=$(soap_post "$DEVICE" \
    '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><GetSystemDateAndTime xmlns="http://www.onvif.org/ver10/device/wsdl"/></s:Body></s:Envelope>' \
    2>/dev/null || true)
  # Namespace-independent patterns (handles tt:, tds:, or no prefix).
  # head -1 takes only the first occurrence — guards against cameras that
  # include both UTCDateTime and LocalDateTime in one response (double match
  # would give multiline output that breaks printf '%02d').
  # [[:space:]]* tolerates whitespace between > and the digit value.
  year=$(printf '%s'   "$resp" | grep -oE '[Yy]ear>[[:space:]]*[0-9]+'   | head -1 | grep -oE '[0-9]+' || true)
  month=$(printf '%s'  "$resp" | grep -oE '[Mm]onth>[[:space:]]*[0-9]+'  | head -1 | grep -oE '[0-9]+' || true)
  day=$(printf '%s'    "$resp" | grep -oE '[Dd]ay>[[:space:]]*[0-9]+'    | head -1 | grep -oE '[0-9]+' || true)
  hour=$(printf '%s'   "$resp" | grep -oE '[Hh]our>[[:space:]]*[0-9]+'   | head -1 | grep -oE '[0-9]+' || true)
  minute=$(printf '%s' "$resp" | grep -oE '[Mm]inute>[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  second=$(printf '%s' "$resp" | grep -oE '[Ss]econd>[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+' || true)

  if [ -n "$year" ] && [ -n "$month" ] && [ -n "$day" ]; then
    printf '%04d-%02d-%02dT%02d:%02d:%02dZ' \
      "$year" "$month" "$day" "${hour:-0}" "${minute:-0}" "${second:-0}"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# Select the profile token with the highest Width.
# Matches only top-level <..Profiles token="..."> elements, not the nested
# VideoEncoderConfiguration / VideoSourceConfiguration tokens that also carry
# token= attributes and appear before the <tt:Width> values in document order.
select_best_profile() {
  local xml="$1" best_token='' best_width=0
  local current_token='' current_width=0 item

  while IFS= read -r item; do
    case "$item" in
      Profiles\ *)
        if [ "${current_width:-0}" -gt "$best_width" ]; then
          best_width="$current_width"
          best_token="$current_token"
        fi
        current_token=$(printf '%s' "$item" | grep -oE 'token="[^"]*"' | sed 's/token="//;s/"//')
        current_width=0
        ;;
      '<tt:Width>'*)
        current_width="${item#*>}"
        ;;
    esac
  done < <(printf '%s' "$xml" | grep -oE '(Profiles [^<>]*|<tt:Width>[0-9]+)' || true)

  # Flush last profile
  if [ "${current_width:-0}" -gt "$best_width" ]; then
    best_token="$current_token"
  fi

  printf '%s' "$best_token"
}

# --- Step 1: GetCapabilities (no auth) → media XAddr ---
echo "=== GetCapabilities ==="
caps=$(soap_post "$DEVICE" \
  '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl"><Category>Media</Category></GetCapabilities></s:Body></s:Envelope>')
media_xaddr=$(printf '%s' "$caps" \
  | grep -oE '<tt:XAddr>[^<]*</tt:XAddr>' | head -1 | grep -oE 'https?://[^<]*' || true)

if [ -z "$media_xaddr" ]; then
  echo "FAIL: no media XAddr — is ONVIF enabled on the camera?" >&2
  echo "Manual fallback: use http://$IP/onvif/Media as media endpoint." >&2
  exit 2
fi
echo "media XAddr: $media_xaddr"

# --- Step 2: GetSystemDateAndTime for clock-skew-safe timestamps ---
echo "=== GetSystemDateAndTime ==="
created=$(get_camera_created)
echo "using created: $created"

# --- Step 3: GetProfiles → pick highest-resolution profile ---
echo "=== GetProfiles ==="
profiles=$(soap_post "$media_xaddr" \
  "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\"><s:Header>$(make_security_header "$created")</s:Header><s:Body><GetProfiles xmlns=\"http://www.onvif.org/ver10/media/wsdl\"/></s:Body></s:Envelope>")
token=$(select_best_profile "$profiles")

if [ -z "$token" ]; then
  echo "FAIL: no profile token (auth problem?)" >&2
  printf '%s\n' "$profiles" | head -c 500 >&2
  echo "Manual fallback: run GetProfiles manually and inspect tokens." >&2
  exit 3
fi
echo "selected token: $token (highest resolution)"

# --- Step 4: GetSnapshotUri ---
echo "=== GetSnapshotUri ==="
created=$(get_camera_created)
snap=$(soap_post "$media_xaddr" \
  "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\"><s:Header>$(make_security_header "$created")</s:Header><s:Body><GetSnapshotUri xmlns=\"http://www.onvif.org/ver10/media/wsdl\"><ProfileToken>$token</ProfileToken></GetSnapshotUri></s:Body></s:Envelope>")
# Look specifically inside <tt:Uri> / <Uri> element content, not xmlns attributes.
# The SOAP envelope has many xmlns:xxx="http://..." that would fool a plain http grep.
snapshot_url=$(printf '%s' "$snap" | grep -oiE '[Uu][Rr][Ii]>[^<]+' | grep -oiE 'https?://[^<]*' | head -1 || true)

if [ -z "$snapshot_url" ]; then
  echo "FAIL: no snapshot URI." >&2
  printf '%s\n' "$snap" | head -c 500 >&2
  echo "Manual fallback: http://$IP:80/onvif/Snapshot (verified for Kenik KG-4230TAS-IL)." >&2
  exit 4
fi
echo "snapshot URL: $snapshot_url"

# --- Step 5: Verify by fetching one frame ---
echo "=== Verify snapshot ==="
tmpjpg=$(mktemp)
# shellcheck disable=SC2064
trap "rm -f '$tmpjpg'" EXIT

"$CURL" -s --digest -u "${CAMERA_USER}:${CAMERA_PASS}" \
  "$snapshot_url" -o "$tmpjpg" -m 15 || true

file_size=$(wc -c < "$tmpjpg" | tr -d ' ')
first_bytes=$(od -A n -N 2 -t x1 "$tmpjpg" 2>/dev/null | tr -d ' \n')

if [ "$first_bytes" != "ffd8" ] || [ "$file_size" -lt 10240 ]; then
  echo "FAIL: not a valid JPEG (magic=${first_bytes} size=${file_size}B)." >&2
  echo "Manual fallback: curl --digest -u admin: http://$IP:80/onvif/Snapshot" >&2
  exit 5
fi
echo "PASS: JPEG verified (${file_size} bytes)"

# --- Step 6: Write camera.conf ---
snapshot_tmpl=$(printf '%s' "$snapshot_url" | sed "s#$IP#{IP}#g")
media_tmpl=$(printf '%s' "$media_xaddr" | sed "s#$IP#{IP}#g")
mkdir -p "$BOOT_PICAM"

cat > "$BOOT_PICAM/camera.conf" << CONF
CAMERA_MAC=$CAMERA_MAC
CAMERA_USER=$CAMERA_USER
CAMERA_PASS=$CAMERA_PASS
ONVIF_MEDIA_XADDR=$media_tmpl
SNAPSHOT_URL=$snapshot_tmpl
CONF

echo "=== camera.conf written to $BOOT_PICAM/camera.conf ==="
cat "$BOOT_PICAM/camera.conf"
_log "ONVIF PROBE OK | ip=$IP snapshot=$snapshot_tmpl"

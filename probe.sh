#!/usr/bin/env bash
#
# probe.sh — VERIFIED working ONVIF snapshot-URL discovery for the Kenik
# KG-4230TAS-IL (QUVII-platform firmware). Run once, in the office, to confirm
# the snapshot URL and (optionally) seed camera.conf.
#
# This is a PROTOTYPE proven against the real unit on 2026-06-10. The agent
# should productionize it into pi/bin/onvif-probe.sh (add profile selection by
# resolution, clock-skew handling, camera.conf writing, and shellcheck/tests),
# but MUST NOT reinvent the WS-Security computation — it is correct here.
#
# Verified facts baked in below:
#   - ONVIF media service endpoint:  http://<IP>/onvif/Media   (capital M)
#   - GetCapabilities / GetSystemDateAndTime: no auth
#   - GetProfiles / GetSnapshotUri: WS-Security UsernameToken PasswordDigest
#   - Snapshot fetch: HTTP Digest, user "admin", EMPTY password
#   - Working snapshot URL: http://<IP>:80/onvif/Snapshot
#
set -euo pipefail

IP="${1:-192.168.251.113}"     # camera IP (arg 1, defaults to office address)
USER="admin"
PASS="${CAMERA_PASS:-}"        # empty by default; export CAMERA_PASS=... to override
DEVICE="http://$IP/onvif/device_service"

# --- build a fresh WS-Security UsernameToken PasswordDigest header ---
# digest = base64( sha1( nonce_raw + created + password ) )
make_security_header() {
  local nonce_raw nonce_b64 created digest
  nonce_raw=$(openssl rand 16)
  nonce_b64=$(printf '%s' "$nonce_raw" | openssl base64 -A)
  created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  digest=$(
    { printf '%s' "$nonce_raw"; printf '%s%s' "$created" "$PASS"; } \
    | openssl dgst -sha1 -binary | openssl base64 -A
  )
  cat <<EOF
<wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><wsse:UsernameToken><wsse:Username>$USER</wsse:Username><wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">$digest</wsse:Password><wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">$nonce_b64</wsse:Nonce><wsu:Created>$created</wsu:Created></wsse:UsernameToken></wsse:Security>
EOF
}

soap_post() {  # $1 = endpoint URL, $2 = full envelope
  curl -s -m 10 -X POST "$1" -H 'Content-Type: application/soap+xml' -d "$2"
}

# --- step 1: GetCapabilities (no auth) → media XAddr ---
echo "=== GetCapabilities (media XAddr) ==="
caps=$(soap_post "$DEVICE" '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl"><Category>Media</Category></GetCapabilities></s:Body></s:Envelope>')
media_xaddr=$(echo "$caps" | grep -oE '<tt:XAddr>[^<]*</tt:XAddr>' | head -1 | grep -oE 'https?://[^<]*')
echo "media XAddr: ${media_xaddr:-<not found>}"
[ -n "$media_xaddr" ] || { echo "FAIL: no media XAddr — is ONVIF enabled?"; exit 2; }

# --- step 2: GetProfiles (WS-Security) → profile tokens + resolutions ---
echo "=== GetProfiles ==="
profiles=$(soap_post "$media_xaddr" "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\"><s:Header>$(make_security_header)</s:Header><s:Body><GetProfiles xmlns=\"http://www.onvif.org/ver10/media/wsdl\"/></s:Body></s:Envelope>")
echo "$profiles" | grep -oE '(token="[^"]*"|<tt:Width>[0-9]*|<tt:Height>[0-9]*)' || true
# TODO (productionize): pick token with the largest Width, not just the first.
token=$(echo "$profiles" | grep -oE 'token="[^"]*"' | head -1 | sed 's/token="//;s/"//')
echo "using token: ${token:-<none>}"
[ -n "$token" ] || { echo "FAIL: no profile token (auth problem?)"; echo "$profiles" | head -c 500; exit 3; }

# --- step 3: GetSnapshotUri (WS-Security) → snapshot URL ---
echo "=== GetSnapshotUri ==="
snap=$(soap_post "$media_xaddr" "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\"><s:Header>$(make_security_header)</s:Header><s:Body><GetSnapshotUri xmlns=\"http://www.onvif.org/ver10/media/wsdl\"><ProfileToken>$token</ProfileToken></GetSnapshotUri></s:Body></s:Envelope>")
snapshot_url=$(echo "$snap" | grep -oiE 'http[s]?://[^<]*' | head -1)
echo "snapshot URL: ${snapshot_url:-<not found>}"
[ -n "$snapshot_url" ] || { echo "FAIL: no snapshot URI"; echo "$snap" | head -c 500; exit 4; }

# --- step 4: verify by fetching one frame ---
echo "=== verify snapshot fetch ==="
curl -s --digest -u "$USER:$PASS" "$snapshot_url" -o /tmp/picam-probe.jpg -m 15 || true
if file /tmp/picam-probe.jpg | grep -q 'JPEG image data'; then
  echo "PASS: got JPEG → /tmp/picam-probe.jpg ($(wc -c </tmp/picam-probe.jpg) bytes)"
  echo
  echo "For camera.conf (replace IP with {IP} template):"
  echo "  SNAPSHOT_URL=$(echo "$snapshot_url" | sed "s#$IP#{IP}#")"
else
  echo "FAIL: fetched file is not a JPEG"; file /tmp/picam-probe.jpg
  exit 5
fi

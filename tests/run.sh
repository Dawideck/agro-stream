#!/usr/bin/env bash
# tests/run.sh — PiCam test suite (bash 3.2 compatible; runs on macOS and Pi)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

check() {
  local desc="$1"; shift
  local tmp
  tmp=$(mktemp)
  if "$@" >"$tmp" 2>&1; then
    PASS=$(( PASS + 1 ))
    echo "  PASS: $desc"
  else
    FAIL=$(( FAIL + 1 ))
    echo "  FAIL: $desc"
    [ -s "$tmp" ] && sed 's/^/    /' "$tmp"
  fi
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
test_crlf_config_parsing() {
  echo "--- CRLF config parsing ---"
  local tmpfile
  tmpfile=$(mktemp)
  local tmpclean
  tmpclean=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$tmpfile' '$tmpclean'" RETURN
  printf 'TEST_CRLF_VAL=/some/path\r\nTEST_CRLF_NUM=42\r\n' > "$tmpfile"

  local result
  sed 's/\r//g' "$tmpfile" > "$tmpclean"
  result=$(bash -c "source '$tmpclean'; printf '%s:%s' \"\$TEST_CRLF_VAL\" \"\$TEST_CRLF_NUM\"")
  check "CRLF: values stripped of carriage returns" [ "$result" = "/some/path:42" ]
}

# ---------------------------------------------------------------------------
test_defaults_completeness() {
  echo "--- defaults.conf completeness ---"
  local f="$REPO_ROOT/pi/etc/defaults.conf"
  check "defaults.conf exists" test -f "$f"
  [ -f "$f" ] || return 0

  for key in JPEG_DIR RETENTION_DAYS MODE INTERVAL_MIN WINDOW_START WINDOW_END \
              TIMES CAMERA_MAC CAMERA_USER CAMERA_PASS SNAPSHOT_URL ONVIF_MEDIA_XADDR \
              STATUS_LOG STATUS_LOG_MAX_LINES CAMERA_IP_CACHE FAIL_COUNT_FILE \
              LAST_SHOT_STAMP HEALTH_REBOOT_COOLDOWN_SEC \
              HEALTH_FAIL_REBOOT_THRESHOLD HEALTH_FAIL_NETWORK_RESTART_THRESHOLD; do
    check "defaults has key: $key" grep -q "^${key}=" "$f"
  done
}

# ---------------------------------------------------------------------------
test_shellcheck() {
  echo "--- shellcheck ---"
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "  SKIP: shellcheck not installed (brew install shellcheck)"
    return
  fi
  local script
  for script in \
      "$REPO_ROOT/install.sh" \
      "$REPO_ROOT/pi/bin/"*.sh \
      "$REPO_ROOT/mac/picam-config.sh"; do
    case "$script" in
      *'/*.sh') FAIL=$(( FAIL + 1 )); echo "  FAIL: no scripts found in pi/bin/"; continue ;;
    esac
    if [ -f "$script" ]; then
      check "shellcheck $(basename "$script")" shellcheck "$script"
    else
      FAIL=$(( FAIL + 1 ))
      echo "  FAIL: missing: $(basename "$script")"
    fi
  done
}

# ---------------------------------------------------------------------------
test_systemd_units() {
  echo "--- systemd unit syntax ---"
  if ! command -v systemd-analyze >/dev/null 2>&1; then
    echo "  SKIP: systemd-analyze not found (run on Pi / Linux)"
    return
  fi
  local unit
  for unit in \
      "$REPO_ROOT/pi/systemd/picam-wifi-applier.service" \
      "$REPO_ROOT/pi/systemd/picam-capture.timer" \
      "$REPO_ROOT/pi/systemd/picam-capture.service" \
      "$REPO_ROOT/pi/systemd/picam-healthcheck.timer" \
      "$REPO_ROOT/pi/systemd/picam-healthcheck.service"; do
    if [ -f "$unit" ]; then
      check "systemd-analyze verify $(basename "$unit")" systemd-analyze verify "$unit"
    else
      FAIL=$(( FAIL + 1 ))
      echo "  FAIL: missing: $(basename "$unit")"
    fi
  done
}

# ---------------------------------------------------------------------------
test_wifi_applier() {
  echo "--- wifi-applier lifecycle ---"

  local boot_dir status_log calls_file fake_nmcli script
  boot_dir=$(mktemp -d)
  status_log=$(mktemp)
  calls_file=$(mktemp)
  fake_nmcli=$(mktemp)
  script="$REPO_ROOT/pi/bin/wifi-applier.sh"

  # shellcheck disable=SC2064
  trap "rm -rf '$boot_dir' '$status_log' '$calls_file' '$fake_nmcli'" RETURN

  # Fake nmcli: records all invocations; simulates "profile does not exist"
  cat > "$fake_nmcli" << FAKESCRIPT
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$calls_file"
case "\$1 \$2" in
  "connection show") exit 1 ;;
  *) exit 0 ;;
esac
FAKESCRIPT
  chmod +x "$fake_nmcli"

  run_wifi() {
    PICAM_BOOT_DIR="$boot_dir" \
    STATUS_LOG="$status_log" \
    PICAM_NMCLI="$fake_nmcli" \
    PICAM_DEFAULTS=/dev/null \
    bash "$script"
  }

  # --- scenario 1: no wifi-update.txt → silent exit 0, nothing created ---
  check "wifi: no file → exits 0" run_wifi
  check "wifi: no file → no .applied" test ! -f "$boot_dir/wifi-update.applied"
  check "wifi: no file → no .failed"  test ! -f "$boot_dir/wifi-update.failed"

  # --- scenario 2: valid CRLF file → .applied created, PASS scrubbed ---
  printf 'SSID=TestNetwork\r\nPASS=SuperSecret123\r\nPRIORITY=10\r\n' \
    > "$boot_dir/wifi-update.txt"
  true > "$calls_file"

  check "wifi: valid → exits 0"              run_wifi
  check "wifi: valid → .txt removed"         test ! -f "$boot_dir/wifi-update.txt"
  check "wifi: valid → .applied created"     test -f  "$boot_dir/wifi-update.applied"
  check "wifi: valid → PASS scrubbed"        bash -c "test -f '$boot_dir/wifi-update.applied' && ! grep -q '^PASS=' '$boot_dir/wifi-update.applied'"
  check "wifi: valid → SSID preserved"       grep -q 'SSID=TestNetwork' "$boot_dir/wifi-update.applied"
  check "wifi: valid → nmcli add called"     grep -q 'connection add'   "$calls_file"
  check "wifi: valid → nmcli up called"      grep -q 'connection up'    "$calls_file"

  # --- scenario 3: empty SSID → .failed with ERROR line ---
  printf 'SSID=\r\nPASS=SuperSecret123\r\nPRIORITY=5\r\n' \
    > "$boot_dir/wifi-update.txt"

  check "wifi: empty SSID → exits non-zero" \
    bash -c "! PICAM_BOOT_DIR='$boot_dir' STATUS_LOG='$status_log' PICAM_NMCLI='$fake_nmcli' PICAM_DEFAULTS=/dev/null bash '$script'"
  check "wifi: empty SSID → .failed created" test -f "$boot_dir/wifi-update.failed"
  check "wifi: empty SSID → ERROR in .failed" grep -q 'ERROR' "$boot_dir/wifi-update.failed"
  rm -f "$boot_dir/wifi-update.failed"

  # --- scenario 4: PASS too short (< 8 chars) → .failed ---
  printf 'SSID=TestNetwork\r\nPASS=short\r\nPRIORITY=5\r\n' \
    > "$boot_dir/wifi-update.txt"

  check "wifi: short PASS → exits non-zero" \
    bash -c "! PICAM_BOOT_DIR='$boot_dir' STATUS_LOG='$status_log' PICAM_NMCLI='$fake_nmcli' PICAM_DEFAULTS=/dev/null bash '$script'"
  check "wifi: short PASS → .failed created" test -f "$boot_dir/wifi-update.failed"
  check "wifi: short PASS → ERROR in .failed" grep -q 'ERROR' "$boot_dir/wifi-update.failed"
  rm -f "$boot_dir/wifi-update.failed"

  # --- scenario 5: profile already exists → modify (not add) ---
  printf 'SSID=ExistNet\r\nPASS=AnotherSecret456\r\nPRIORITY=5\r\n' \
    > "$boot_dir/wifi-update.txt"
  true > "$calls_file"

  # Rewrite fake nmcli so it says the profile already exists
  cat > "$fake_nmcli" << FAKESCRIPT2
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$calls_file"
case "\$1 \$2" in
  "connection show") exit 0 ;;
  *) exit 0 ;;
esac
FAKESCRIPT2
  chmod +x "$fake_nmcli"

  check "wifi: existing profile → exits 0"        run_wifi
  check "wifi: existing profile → modify called"  grep -q 'connection modify' "$calls_file"
  check "wifi: existing profile → add NOT called" bash -c "! grep -q 'connection add' '$calls_file'"
}

# ---------------------------------------------------------------------------
test_discover_camera() {
  echo "--- discover-camera ---"

  local var_dir status_log fake_arpscan fake_ip fake_tcp script
  var_dir=$(mktemp -d)
  status_log=$(mktemp)
  fake_arpscan=$(mktemp)
  fake_ip=$(mktemp)
  fake_tcp=$(mktemp)
  script="$REPO_ROOT/pi/bin/discover-camera.sh"

  # shellcheck disable=SC2064
  trap "rm -rf '$var_dir' '$status_log' '$fake_arpscan' '$fake_ip' '$fake_tcp'" RETURN

  # Default fake ip: network is UP
  printf '#!/usr/bin/env bash\necho "default via 192.168.1.1 dev wlan0"\n' > "$fake_ip"
  chmod +x "$fake_ip"

  # Default fake TCP check: all hosts unreachable
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fake_tcp"
  chmod +x "$fake_tcp"

  # Default fake arp-scan: no hosts
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_arpscan"
  chmod +x "$fake_arpscan"

  run_discover() {
    CAMERA_IP_CACHE="$var_dir/camera_ip" \
    STATUS_LOG="$status_log" \
    CAMERA_MAC="00:46:b8:28:e2:55" \
    PICAM_ARPSCAN="$fake_arpscan" \
    PICAM_IP_CMD="$fake_ip" \
    PICAM_TCP_CHECK="$fake_tcp" \
    PICAM_DEFAULTS=/dev/null \
    bash "$script"
  }

  # --- scenario 1: no network → exit 2 ---
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_ip"
  chmod +x "$fake_ip"

  check "discover: no network → exit 2" bash -c "
    rc=0
    CAMERA_IP_CACHE='$var_dir/camera_ip' \
    STATUS_LOG='$status_log' \
    CAMERA_MAC='00:46:b8:28:e2:55' \
    PICAM_ARPSCAN='$fake_arpscan' \
    PICAM_IP_CMD='$fake_ip' \
    PICAM_TCP_CHECK='$fake_tcp' \
    PICAM_DEFAULTS=/dev/null \
    bash '$script' >/dev/null 2>&1 || rc=\$?
    [ \"\$rc\" -eq 2 ]
  "

  # Restore network
  printf '#!/usr/bin/env bash\necho "default via 192.168.1.1 dev wlan0"\n' > "$fake_ip"
  chmod +x "$fake_ip"

  # --- scenario 2: valid cached IP responds on port 80 → exit 0, outputs IP ---
  echo "192.168.1.113" > "$var_dir/camera_ip"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_tcp"
  chmod +x "$fake_tcp"

  local result
  result=$(run_discover) || true
  check "discover: cache hit → exits 0"       run_discover
  check "discover: cache hit → outputs IP"    [ "$result" = "192.168.1.113" ]

  # --- scenario 3: stale cache, arp-scan finds camera → exit 0, cache updated ---
  rm -f "$var_dir/camera_ip"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fake_tcp"
  chmod +x "$fake_tcp"
  printf '#!/usr/bin/env bash\nprintf "192.168.1.200\t00:46:b8:28:e2:55\tKenik\n"\n' \
    > "$fake_arpscan"
  chmod +x "$fake_arpscan"

  result=$(run_discover) || true
  check "discover: arp finds camera → exits 0"   [ "$result" = "192.168.1.200" ]
  check "discover: arp finds camera → cache set" [ "$(cat "$var_dir/camera_ip")" = "192.168.1.200" ]

  # --- scenario 4: camera not found → exit 3 ---
  rm -f "$var_dir/camera_ip"
  printf '#!/usr/bin/env bash\nprintf "192.168.1.1\taa:bb:cc:dd:ee:ff\tRouter\n"\n' \
    > "$fake_arpscan"
  chmod +x "$fake_arpscan"

  check "discover: not found → exit 3" bash -c "
    rc=0
    CAMERA_IP_CACHE='$var_dir/camera_ip' \
    STATUS_LOG='$status_log' \
    CAMERA_MAC='00:46:b8:28:e2:55' \
    PICAM_ARPSCAN='$fake_arpscan' \
    PICAM_IP_CMD='$fake_ip' \
    PICAM_TCP_CHECK='$fake_tcp' \
    PICAM_DEFAULTS=/dev/null \
    bash '$script' >/dev/null 2>&1 || rc=\$?
    [ \"\$rc\" -eq 3 ]
  "

  # --- scenario 5: MAC normalisation — stripped leading zero + uppercase ---
  rm -f "$var_dir/camera_ip"
  printf '#!/usr/bin/env bash\nprintf "192.168.1.200\t0:46:B8:28:E2:55\tKenik\n"\n' \
    > "$fake_arpscan"
  chmod +x "$fake_arpscan"

  result=$(run_discover) || true
  check "discover: MAC norm (0:46:B8…) → found" [ "$result" = "192.168.1.200" ]

  # --- scenario 6: MAC normalisation — dashes ---
  rm -f "$var_dir/camera_ip"
  printf '#!/usr/bin/env bash\nprintf "192.168.1.200\t00-46-b8-28-e2-55\tKenik\n"\n' \
    > "$fake_arpscan"
  chmod +x "$fake_arpscan"

  result=$(run_discover) || true
  check "discover: MAC norm (00-46-…) → found" [ "$result" = "192.168.1.200" ]
}

# ---------------------------------------------------------------------------
test_onvif_probe() {
  echo "--- onvif-probe ---"

  local tmp_dir fake_curl calls_file script
  tmp_dir=$(mktemp -d)
  calls_file="$tmp_dir/curl_calls"
  fake_curl="$tmp_dir/fake_curl.sh"
  script="$REPO_ROOT/pi/bin/onvif-probe.sh"

  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN

  # Canned SOAP responses ------------------------------------------------

  # GetSystemDateAndTime
  cat > "$tmp_dir/time.xml" << 'XMLEOF'
<s:Envelope><s:Body><tds:GetSystemDateAndTimeResponse>
<tds:SystemDateAndTime><tt:UTCDateTime>
<tt:Time><tt:Hour>12</tt:Hour><tt:Minute>0</tt:Minute><tt:Second>0</tt:Second></tt:Time>
<tt:Date><tt:Year>2026</tt:Year><tt:Month>6</tt:Month><tt:Day>15</tt:Day></tt:Date>
</tt:UTCDateTime></tds:SystemDateAndTime>
</tds:GetSystemDateAndTimeResponse></s:Body></s:Envelope>
XMLEOF

  # GetCapabilities → media XAddr
  cat > "$tmp_dir/caps.xml" << 'XMLEOF'
<s:Envelope><s:Body><tds:GetCapabilitiesResponse>
<tds:Capabilities><tt:Media>
<tt:XAddr>http://192.168.1.113/onvif/Media</tt:XAddr>
</tt:Media></tds:Capabilities>
</tds:GetCapabilitiesResponse></s:Body></s:Envelope>
XMLEOF

  # GetProfiles: 3 profiles — highest-res (Profile_Main) is LAST, not first
  cat > "$tmp_dir/profiles.xml" << 'XMLEOF'
<s:Envelope><s:Body><trt:GetProfilesResponse>
<trt:Profiles token="Profile_Mobile">
<tt:Width>640</tt:Width><tt:Height>480</tt:Height>
</trt:Profiles>
<trt:Profiles token="Profile_Sub">
<tt:Width>1280</tt:Width><tt:Height>720</tt:Height>
</trt:Profiles>
<trt:Profiles token="Profile_Main">
<tt:Width>2688</tt:Width><tt:Height>1520</tt:Height>
</trt:Profiles>
</trt:GetProfilesResponse></s:Body></s:Envelope>
XMLEOF

  # GetSnapshotUri
  cat > "$tmp_dir/snapuri.xml" << 'XMLEOF'
<s:Envelope><s:Body><trt:GetSnapshotUriResponse>
<trt:MediaUri><tt:Uri>http://192.168.1.113:80/onvif/Snapshot</tt:Uri>
</trt:MediaUri></trt:GetSnapshotUriResponse></s:Body></s:Envelope>
XMLEOF

  # Fake curl: records calls, dispatches by request body ----------------
  cat > "$fake_curl" << CURLEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$calls_file"

body="" output_file="" prev=""
for arg in "\$@"; do
  case "\$prev" in
    -d) body="\$arg" ;;
    -o) output_file="\$arg" ;;
  esac
  prev="\$arg"
done

if [ -n "\$output_file" ]; then
  printf '\xff\xd8\xff\xe0' > "\$output_file"
  dd if=/dev/zero bs=1024 count=11 >> "\$output_file" 2>/dev/null
  exit 0
fi

if printf '%s' "\$body" | grep -q 'GetSystemDateAndTime'; then
  cat "$tmp_dir/time.xml"
elif printf '%s' "\$body" | grep -q 'GetCapabilities'; then
  cat "$tmp_dir/caps.xml"
elif printf '%s' "\$body" | grep -q 'GetSnapshotUri'; then
  cat "$tmp_dir/snapuri.xml"
elif printf '%s' "\$body" | grep -q 'GetProfiles'; then
  cat "$tmp_dir/profiles.xml"
else
  exit 1
fi
CURLEOF
  chmod +x "$fake_curl"

  run_probe() {
    PICAM_CURL="$fake_curl" \
    PICAM_BOOT_DIR="$tmp_dir/boot" \
    PICAM_DEFAULTS=/dev/null \
    CAMERA_USER=admin \
    CAMERA_PASS='' \
    STATUS_LOG="$tmp_dir/status.log" \
    bash "$script" 192.168.1.113
  }
  mkdir -p "$tmp_dir/boot"

  # --- scenario 1: happy path → camera.conf written with {IP} template ---
  true > "$calls_file"
  check "probe: happy path → exits 0" run_probe
  check "probe: camera.conf created" test -f "$tmp_dir/boot/camera.conf"
  check "probe: SNAPSHOT_URL uses {IP} template" \
    grep -q 'SNAPSHOT_URL=http://{IP}' "$tmp_dir/boot/camera.conf"
  check "probe: ONVIF_MEDIA_XADDR uses {IP} template" \
    grep -q 'ONVIF_MEDIA_XADDR=http://{IP}' "$tmp_dir/boot/camera.conf"
  check "probe: CAMERA_USER written" \
    grep -q 'CAMERA_USER=admin' "$tmp_dir/boot/camera.conf"

  # --- scenario 2: profile selection — highest-res (Profile_Main) used ---
  check "probe: GetSnapshotUri called with Profile_Main (highest res)" \
    grep -q 'Profile_Main' "$calls_file"

  # --- scenario 2b: nested encoder tokens (real Kenik camera format) ---
  # Profiles element wraps a VideoEncoderConfiguration with its own token.
  # select_best_profile must pick the PROFILE token, not the encoder token.
  cat > "$tmp_dir/profiles.xml" << 'XMLEOF'
<s:Envelope><s:Body><trt:GetProfilesResponse>
<trt:Profiles token="MainStream"><tt:VideoEncoderConfiguration token="VideoEncoderToken0s0">
<tt:Resolution><tt:Width>2688</tt:Width><tt:Height>1520</tt:Height></tt:Resolution>
</tt:VideoEncoderConfiguration></trt:Profiles>
<trt:Profiles token="SubStream"><tt:VideoEncoderConfiguration token="VideoEncoderToken1s0">
<tt:Resolution><tt:Width>1280</tt:Width><tt:Height>720</tt:Height></tt:Resolution>
</tt:VideoEncoderConfiguration></trt:Profiles>
</trt:GetProfilesResponse></s:Body></s:Envelope>
XMLEOF
  true > "$calls_file"
  check "probe: nested encoder tokens → exits 0" run_probe
  check "probe: nested tokens → uses profile token MainStream (not VideoEncoderToken0s0)" \
    grep -q 'MainStream' "$calls_file"
  check "probe: nested tokens → encoder token NOT used as ProfileToken" bash -c \
    "! grep -q 'VideoEncoderToken0s0' '$calls_file'"
  # Restore original profiles.xml for remaining scenarios
  cat > "$tmp_dir/profiles.xml" << 'XMLEOF'
<s:Envelope><s:Body><trt:GetProfilesResponse>
<trt:Profiles token="Profile_Mobile">
<tt:Width>640</tt:Width><tt:Height>480</tt:Height>
</trt:Profiles>
<trt:Profiles token="Profile_Sub">
<tt:Width>1280</tt:Width><tt:Height>720</tt:Height>
</trt:Profiles>
<trt:Profiles token="Profile_Main">
<tt:Width>2688</tt:Width><tt:Height>1520</tt:Height>
</trt:Profiles>
</trt:GetProfilesResponse></s:Body></s:Envelope>
XMLEOF

  # --- scenario 3: GetSystemDateAndTime called (clock-skew handling) ---
  check "probe: GetSystemDateAndTime called" \
    grep -q 'GetSystemDateAndTime' "$calls_file"

  # --- scenario 4: GetCapabilities failure → exit 2 + no camera.conf ---
  cat > "$tmp_dir/caps.xml" << 'XMLEOF'
<s:Envelope><s:Body><s:Fault><s:Code><s:Value>env:Receiver</s:Value></s:Code></s:Fault></s:Body></s:Envelope>
XMLEOF
  rm -f "$tmp_dir/boot/camera.conf"

  check "probe: caps failure → exit 2" bash -c "
    rc=0
    PICAM_CURL='$fake_curl' PICAM_BOOT_DIR='$tmp_dir/boot' \
    PICAM_DEFAULTS=/dev/null CAMERA_USER=admin CAMERA_PASS= \
    STATUS_LOG='$tmp_dir/status.log' \
    bash '$script' 192.168.1.113 >/dev/null 2>&1 || rc=\$?
    [ \"\$rc\" -eq 2 ]
  "
  check "probe: caps failure → no camera.conf written" \
    test ! -f "$tmp_dir/boot/camera.conf"

  # Restore caps response
  cat > "$tmp_dir/caps.xml" << 'XMLEOF'
<s:Envelope><s:Body><tds:GetCapabilitiesResponse>
<tds:Capabilities><tt:Media>
<tt:XAddr>http://192.168.1.113/onvif/Media</tt:XAddr>
</tt:Media></tds:Capabilities>
</tds:GetCapabilitiesResponse></s:Body></s:Envelope>
XMLEOF

  # --- scenario 5: invalid JPEG → exit 5 ---
  cat > "$fake_curl" << CURLEOF2
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$calls_file"
body="" output_file="" prev=""
for arg in "\$@"; do
  case "\$prev" in
    -d) body="\$arg" ;;
    -o) output_file="\$arg" ;;
  esac
  prev="\$arg"
done
if [ -n "\$output_file" ]; then
  printf 'not a jpeg' > "\$output_file"
  exit 0
fi
if printf '%s' "\$body" | grep -q 'GetSystemDateAndTime'; then cat "$tmp_dir/time.xml"
elif printf '%s' "\$body" | grep -q 'GetCapabilities'; then cat "$tmp_dir/caps.xml"
elif printf '%s' "\$body" | grep -q 'GetSnapshotUri'; then cat "$tmp_dir/snapuri.xml"
elif printf '%s' "\$body" | grep -q 'GetProfiles'; then cat "$tmp_dir/profiles.xml"
else exit 1; fi
CURLEOF2
  chmod +x "$fake_curl"

  check "probe: invalid JPEG → exit 5" bash -c "
    rc=0
    PICAM_CURL='$fake_curl' PICAM_BOOT_DIR='$tmp_dir/boot' \
    PICAM_DEFAULTS=/dev/null CAMERA_USER=admin CAMERA_PASS= \
    STATUS_LOG='$tmp_dir/status.log' \
    bash '$script' 192.168.1.113 >/dev/null 2>&1 || rc=\$?
    [ \"\$rc\" -eq 5 ]
  "
}

# ---------------------------------------------------------------------------
test_camera_time_parsing() {
  echo "--- camera time parsing ---"

  local tmp_dir fake_curl script
  tmp_dir=$(mktemp -d)
  fake_curl="$tmp_dir/fake_curl.sh"
  script="$REPO_ROOT/pi/bin/onvif-probe.sh"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN
  mkdir -p "$tmp_dir/boot"

  # Shared non-time SOAP responses
  cat > "$tmp_dir/caps.xml" << 'XMLEOF'
<s:Envelope><s:Body><tds:GetCapabilitiesResponse><tds:Capabilities><tt:Media>
<tt:XAddr>http://192.168.1.1/onvif/Media</tt:XAddr>
</tt:Media></tds:Capabilities></tds:GetCapabilitiesResponse></s:Body></s:Envelope>
XMLEOF
  cat > "$tmp_dir/profiles.xml" << 'XMLEOF'
<s:Envelope><s:Body><trt:GetProfilesResponse>
<trt:Profiles token="Profile_1"><tt:Width>1280</tt:Width></trt:Profiles>
</trt:GetProfilesResponse></s:Body></s:Envelope>
XMLEOF
  cat > "$tmp_dir/snapuri.xml" << 'XMLEOF'
<s:Envelope><s:Body><trt:GetSnapshotUriResponse>
<trt:MediaUri><tt:Uri>http://192.168.1.1:80/onvif/Snapshot</tt:Uri>
</trt:MediaUri></trt:GetSnapshotUriResponse></s:Body></s:Envelope>
XMLEOF

  # Fake curl: reads time response from $tmp_dir/time.xml; writes fake JPEG for snapshot
  cat > "$fake_curl" << CURLEOF
#!/usr/bin/env bash
body="" output_file="" prev=""
for arg in "\$@"; do
  case "\$prev" in
    -d) body="\$arg" ;;
    -o) output_file="\$arg" ;;
  esac
  prev="\$arg"
done
if [ -n "\$output_file" ]; then
  printf '\xff\xd8\xff\xe0' > "\$output_file"
  dd if=/dev/zero bs=1024 count=11 >> "\$output_file" 2>/dev/null
  exit 0
fi
if printf '%s' "\$body" | grep -q 'GetSystemDateAndTime'; then cat "$tmp_dir/time.xml"
elif printf '%s' "\$body" | grep -q 'GetCapabilities'; then cat "$tmp_dir/caps.xml"
elif printf '%s' "\$body" | grep -q 'GetSnapshotUri'; then cat "$tmp_dir/snapuri.xml"
elif printf '%s' "\$body" | grep -q 'GetProfiles'; then cat "$tmp_dir/profiles.xml"
else exit 1; fi
CURLEOF
  chmod +x "$fake_curl"

  run_probe() {
    PICAM_CURL="$fake_curl" PICAM_BOOT_DIR="$tmp_dir/boot" \
    PICAM_DEFAULTS=/dev/null CAMERA_USER=admin CAMERA_PASS='' \
    STATUS_LOG="$tmp_dir/status.log" \
    bash "$script" 192.168.1.1
  }

  # --- scenario 1: UTCDateTime + LocalDateTime (the real bug: grep returns two lines) ---
  cat > "$tmp_dir/time.xml" << 'XMLEOF'
<s:Envelope><s:Body><tds:GetSystemDateAndTimeResponse>
<tds:SystemDateAndTime>
<tt:UTCDateTime>
<tt:Time><tt:Hour>6</tt:Hour><tt:Minute>1</tt:Minute><tt:Second>5</tt:Second></tt:Time>
<tt:Date><tt:Year>2026</tt:Year><tt:Month>6</tt:Month><tt:Day>1</tt:Day></tt:Date>
</tt:UTCDateTime>
<tt:LocalDateTime>
<tt:Time><tt:Hour>8</tt:Hour><tt:Minute>1</tt:Minute><tt:Second>5</tt:Second></tt:Time>
<tt:Date><tt:Year>2026</tt:Year><tt:Month>6</tt:Month><tt:Day>1</tt:Day></tt:Date>
</tt:LocalDateTime>
</tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse></s:Body></s:Envelope>
XMLEOF
  rm -f "$tmp_dir/boot/camera.conf"
  check "time: UTC+Local double occurrence → probe exits 0" run_probe
  check "time: UTC+Local double occurrence → camera.conf written" \
    test -f "$tmp_dir/boot/camera.conf"

  # --- scenario 2: single-digit fields → zero-padded ISO8601 (same XML, check format) ---
  run_probe > "$tmp_dir/probe_out.txt" 2>/dev/null || true
  check "time: single-digit fields → ISO8601 format" \
    grep -qE 'created: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' \
    "$tmp_dir/probe_out.txt"

  # --- scenario 3: whitespace between > and digit value ---
  cat > "$tmp_dir/time.xml" << 'XMLEOF'
<s:Envelope><s:Body><tds:GetSystemDateAndTimeResponse>
<tds:SystemDateAndTime><tt:UTCDateTime>
<tt:Time>
  <tt:Hour> 6 </tt:Hour><tt:Minute> 30 </tt:Minute><tt:Second> 0 </tt:Second>
</tt:Time>
<tt:Date>
  <tt:Year> 2026 </tt:Year><tt:Month> 12 </tt:Month><tt:Day> 31 </tt:Day>
</tt:Date>
</tt:UTCDateTime></tds:SystemDateAndTime>
</tds:GetSystemDateAndTimeResponse></s:Body></s:Envelope>
XMLEOF
  rm -f "$tmp_dir/boot/camera.conf"
  check "time: whitespace in values → probe exits 0" run_probe

  # --- scenario 4: malformed time response → fallback to Pi time, probe continues ---
  cat > "$tmp_dir/time.xml" << 'XMLEOF'
<s:Envelope><s:Body><s:Fault><s:Code>Receiver</s:Code></s:Fault></s:Body></s:Envelope>
XMLEOF
  rm -f "$tmp_dir/boot/camera.conf"
  check "time: malformed → fallback to Pi time, probe exits 0" run_probe
  check "time: malformed → camera.conf still written" test -f "$tmp_dir/boot/camera.conf"
}

# ---------------------------------------------------------------------------
test_capture_gate() {
  echo "--- capture-gate.sh ---"
  local script="$REPO_ROOT/pi/bin/capture-gate.sh"
  local tmp_dir
  tmp_dir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN

  local stamp="$tmp_dir/last_shot"
  local fired="$tmp_dir/fired"
  # Fake capture: just writes a marker file.
  local fake_capture="$tmp_dir/fake_capture.sh"
  printf '#!/usr/bin/env bash\ntouch "%s"\n' "$fired" > "$fake_capture"
  chmod +x "$fake_capture"

  run_gate() {
    PICAM_DEFAULTS=/dev/null \
    PICAM_CAPTURE_CONF=/dev/null \
    PICAM_CAPTURE="$fake_capture" \
    LAST_SHOT_STAMP="$stamp" \
    MODE="${MODE:-interval}" \
    INTERVAL_MIN="${INTERVAL_MIN:-30}" \
    WINDOW_START="${WINDOW_START:-07:00}" \
    WINDOW_END="${WINDOW_END:-18:00}" \
    TIMES="${TIMES:-08:00,12:00}" \
    PICAM_NOW_HHMM="${PICAM_NOW_HHMM:-}" \
    PICAM_NOW_EPOCH="${PICAM_NOW_EPOCH:-}" \
    bash "$script"
  }

  # --- interval mode ---
  rm -f "$stamp" "$fired"
  MODE=interval INTERVAL_MIN=30 WINDOW_START=07:00 WINDOW_END=18:00 \
  PICAM_NOW_HHMM=10:00 PICAM_NOW_EPOCH=1000000 \
  run_gate
  check "gate: interval, no stamp, inside window → fires" test -f "$fired"

  rm -f "$stamp" "$fired"
  MODE=interval INTERVAL_MIN=30 WINDOW_START=07:00 WINDOW_END=18:00 \
  PICAM_NOW_HHMM=06:59 PICAM_NOW_EPOCH=1000000 \
  run_gate
  check "gate: interval, outside window (before start) → no fire" test ! -f "$fired"

  rm -f "$stamp" "$fired"
  MODE=interval INTERVAL_MIN=30 WINDOW_START=07:00 WINDOW_END=18:00 \
  PICAM_NOW_HHMM=18:01 PICAM_NOW_EPOCH=1000000 \
  run_gate
  check "gate: interval, outside window (after end) → no fire" test ! -f "$fired"

  # Stamp is 25 min ago (< 30 min interval) → no fire
  rm -f "$fired"
  printf '%d\n' "$(( 1000000 - 25 * 60 ))" > "$stamp"
  MODE=interval INTERVAL_MIN=30 WINDOW_START=07:00 WINDOW_END=18:00 \
  PICAM_NOW_HHMM=10:00 PICAM_NOW_EPOCH=1000000 \
  run_gate
  check "gate: interval, stamp 25 min ago (< 30 min) → no fire" test ! -f "$fired"

  # Stamp is 30 min ago (exactly) → fires
  rm -f "$fired"
  printf '%d\n' "$(( 1000000 - 30 * 60 ))" > "$stamp"
  MODE=interval INTERVAL_MIN=30 WINDOW_START=07:00 WINDOW_END=18:00 \
  PICAM_NOW_HHMM=10:00 PICAM_NOW_EPOCH=1000000 \
  run_gate
  check "gate: interval, stamp exactly 30 min ago → fires" test -f "$fired"

  # Window boundary: at WINDOW_END exactly → fires if elapsed
  rm -f "$fired"
  printf '%d\n' "$(( 1000000 - 30 * 60 ))" > "$stamp"
  MODE=interval INTERVAL_MIN=30 WINDOW_START=07:00 WINDOW_END=18:00 \
  PICAM_NOW_HHMM=18:00 PICAM_NOW_EPOCH=1000000 \
  run_gate
  check "gate: interval, at WINDOW_END exactly → fires" test -f "$fired"

  # Window boundary: at WINDOW_START exactly → fires (no stamp)
  rm -f "$stamp" "$fired"
  MODE=interval INTERVAL_MIN=30 WINDOW_START=07:00 WINDOW_END=18:00 \
  PICAM_NOW_HHMM=07:00 PICAM_NOW_EPOCH=1000000 \
  run_gate
  check "gate: interval, at WINDOW_START exactly → fires" test -f "$fired"

  # --- times mode ---
  rm -f "$stamp" "$fired"
  MODE=times TIMES=08:00,12:00,16:00 \
  PICAM_NOW_HHMM=08:00 PICAM_NOW_EPOCH=1000000 \
  run_gate
  check "gate: times, current HH:MM matches → fires" test -f "$fired"

  rm -f "$stamp" "$fired"
  MODE=times TIMES=08:00,12:00,16:00 \
  PICAM_NOW_HHMM=09:00 PICAM_NOW_EPOCH=1000000 \
  run_gate
  check "gate: times, no match → no fire" test ! -f "$fired"

  # Double-fire guard: stamp is 30 sec ago (< 60 sec) → no fire
  rm -f "$fired"
  printf '%d\n' "$(( 1000000 - 30 ))" > "$stamp"
  MODE=times TIMES=08:00,12:00,16:00 \
  PICAM_NOW_HHMM=08:00 PICAM_NOW_EPOCH=1000000 \
  run_gate
  check "gate: times, double-fire guard (30s ago) → no fire" test ! -f "$fired"

  # Guard passed: stamp is 61 sec ago → fires
  rm -f "$fired"
  printf '%d\n' "$(( 1000000 - 61 ))" > "$stamp"
  MODE=times TIMES=08:00,12:00,16:00 \
  PICAM_NOW_HHMM=08:00 PICAM_NOW_EPOCH=1000000 \
  run_gate
  check "gate: times, stamp 61s ago (> 60s guard) → fires" test -f "$fired"
}

# ---------------------------------------------------------------------------
test_capture() {
  echo "--- capture.sh ---"
  local script="$REPO_ROOT/pi/bin/capture.sh"
  local tmp_dir
  tmp_dir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN

  mkdir -p "$tmp_dir/boot" "$tmp_dir/photos" "$tmp_dir/var"
  local stamp="$tmp_dir/var/last_shot"
  local failcount="$tmp_dir/var/fail_count"
  local ip_cache="$tmp_dir/var/camera_ip"
  local calls_file="$tmp_dir/calls"
  true > "$calls_file"

  # Fake discover: always returns 192.168.1.50
  local fake_discover="$tmp_dir/discover.sh"
  printf '#!/usr/bin/env bash\nprintf "192.168.1.50\\n"\n' > "$fake_discover"
  chmod +x "$fake_discover"

  # Fake curl: writes a valid JPEG (FF D8 + 11 KB zeros)
  local fake_curl="$tmp_dir/curl.sh"
  cat > "$fake_curl" << 'CURLEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "%CALLS%"
output_file="" prev=""
for arg in "$@"; do
  case "$prev" in -o) output_file="$arg" ;; esac
  prev="$arg"
done
if [ -n "$output_file" ]; then
  printf '\xff\xd8\xff\xe0' > "$output_file"
  dd if=/dev/zero bs=1024 count=11 >> "$output_file" 2>/dev/null
fi
CURLEOF
  sed -i '' "s|%CALLS%|$calls_file|g" "$fake_curl" 2>/dev/null \
    || sed -i "s|%CALLS%|$calls_file|g" "$fake_curl"
  chmod +x "$fake_curl"

  run_capture() {
    PICAM_DEFAULTS=/dev/null \
    PICAM_BOOT_DIR="$tmp_dir/boot" \
    PICAM_CURL="$fake_curl" \
    PICAM_DISCOVER="$fake_discover" \
    JPEG_DIR="$tmp_dir/photos" \
    RETENTION_DAYS=30 \
    SNAPSHOT_URL='http://{IP}:80/onvif/Snapshot' \
    CAMERA_USER=admin \
    CAMERA_PASS='' \
    CAMERA_IP_CACHE="$ip_cache" \
    FAIL_COUNT_FILE="$failcount" \
    LAST_SHOT_STAMP="$stamp" \
    bash "$script"
  }

  # --- happy path ---
  rm -f "$stamp" "$failcount"
  check "capture: happy path → exits 0" run_capture
  check "capture: JPEG saved in date subdir" \
    bash -c "find '$tmp_dir/photos' -name '*.jpg' | grep -q ."
  check "capture: last_photo.jpg copied to boot" \
    test -f "$tmp_dir/boot/last_photo.jpg"
  check "capture: last_shot stamp written" test -f "$stamp"
  check "capture: fail_count reset to 0" bash -c \
    "[ \"\$(cat '$failcount')\" = '0' ]"

  # --- {IP} placeholder substituted ---
  check "capture: {IP} substituted in curl URL" \
    grep -q '192.168.1.50' "$calls_file"

  # --- discovery failure → exit 1 + fail_count incremented ---
  rm -f "$stamp" "$failcount"
  local fail_discover="$tmp_dir/fail_discover.sh"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$fail_discover"
  chmod +x "$fail_discover"
  check "capture: discover fail → exit 1" bash -c "
    PICAM_DEFAULTS=/dev/null PICAM_BOOT_DIR='$tmp_dir/boot' \
    PICAM_CURL='$fake_curl' PICAM_DISCOVER='$fail_discover' \
    JPEG_DIR='$tmp_dir/photos' SNAPSHOT_URL='http://{IP}/snap' \
    CAMERA_USER=admin CAMERA_PASS='' \
    CAMERA_IP_CACHE='$ip_cache' FAIL_COUNT_FILE='$failcount' \
    LAST_SHOT_STAMP='$stamp' \
    bash '$script' >/dev/null 2>&1; [ \$? -eq 1 ]
  "
  check "capture: discover fail → fail_count incremented" bash -c \
    "[ \"\$(cat '$failcount' 2>/dev/null || echo 0)\" -gt 0 ]"

  # --- retry on snapshot failure: first curl fails, second succeeds ---
  rm -f "$stamp" "$failcount"
  local call_count_file="$tmp_dir/call_count"
  printf '0\n' > "$call_count_file"
  local retry_curl="$tmp_dir/retry_curl.sh"
  cat > "$retry_curl" << CURLEOF
#!/usr/bin/env bash
n=\$(cat "$call_count_file" 2>/dev/null || echo 0)
n=\$(( n + 1 ))
printf '%d\n' "\$n" > "$call_count_file"
output_file="" prev=""
for arg in "\$@"; do
  case "\$prev" in -o) output_file="\$arg" ;; esac
  prev="\$arg"
done
if [ -n "\$output_file" ] && [ "\$n" -ge 2 ]; then
  printf '\xff\xd8\xff\xe0' > "\$output_file"
  dd if=/dev/zero bs=1024 count=11 >> "\$output_file" 2>/dev/null
  exit 0
fi
exit 1
CURLEOF
  chmod +x "$retry_curl"
  check "capture: first curl fail, retry succeeds → exits 0" bash -c "
    PICAM_DEFAULTS=/dev/null PICAM_BOOT_DIR='$tmp_dir/boot' \
    PICAM_CURL='$retry_curl' PICAM_DISCOVER='$fake_discover' \
    JPEG_DIR='$tmp_dir/photos' SNAPSHOT_URL='http://{IP}/snap' \
    CAMERA_USER=admin CAMERA_PASS='' \
    CAMERA_IP_CACHE='$ip_cache' FAIL_COUNT_FILE='$failcount' \
    LAST_SHOT_STAMP='$stamp' \
    bash '$script' >/dev/null 2>&1
  "

  # --- retention: old directory removed ---
  local old_dir="$tmp_dir/photos/2020-01-01"
  mkdir -p "$old_dir"
  touch "$old_dir/120000.jpg"
  run_capture > /dev/null 2>&1 || true
  check "capture: old photo dir (>30d) pruned by retention" \
    test ! -d "$old_dir"
}

# ---------------------------------------------------------------------------
test_healthcheck() {
  echo "--- healthcheck.sh ---"
  local script="$REPO_ROOT/pi/bin/healthcheck.sh"
  local tmp_dir
  tmp_dir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN

  mkdir -p "$tmp_dir/boot" "$tmp_dir/photos" "$tmp_dir/var" "$tmp_dir/run"

  local failcount="$tmp_dir/var/fail_count"
  local netfail="$tmp_dir/var/net_fail"
  local stamp="$tmp_dir/var/last_shot"
  local last_reboot="$tmp_dir/var/last_reboot"
  local boot_marker="$tmp_dir/run/hc_booted"
  local systemctl_calls="$tmp_dir/systemctl_calls"
  local alert_calls="$tmp_dir/alert_calls"

  # Fake ip: outputs a default route with a gateway
  local fake_ip="$tmp_dir/ip.sh"
  printf '#!/usr/bin/env bash\necho "default via 192.168.1.1 dev wlan0"\n' > "$fake_ip"
  chmod +x "$fake_ip"

  # Fake ping: succeeds by default
  local fake_ping="$tmp_dir/ping.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_ping"
  chmod +x "$fake_ping"

  # Fake discover: returns IP
  local fake_discover="$tmp_dir/discover.sh"
  printf '#!/usr/bin/env bash\nprintf "192.168.1.50\\n"\n' > "$fake_discover"
  chmod +x "$fake_discover"

  # Fake curl: returns valid JPEG
  local fake_curl="$tmp_dir/curl.sh"
  cat > "$fake_curl" << 'CURLEOF'
#!/usr/bin/env bash
output_file="" prev=""
for arg in "$@"; do
  case "$prev" in -o) output_file="$arg" ;; esac
  prev="$arg"
done
[ -n "$output_file" ] && printf '\xff\xd8\xff\xe0' > "$output_file" \
  && dd if=/dev/zero bs=1024 count=11 >> "$output_file" 2>/dev/null
CURLEOF
  chmod +x "$fake_curl"

  # Fake systemctl: records calls
  local fake_systemctl="$tmp_dir/systemctl.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' \
    "$systemctl_calls" > "$fake_systemctl"
  chmod +x "$fake_systemctl"

  # Fake alert: records calls
  local fake_alert="$tmp_dir/alert.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' \
    "$alert_calls" > "$fake_alert"
  chmod +x "$fake_alert"

  run_hc() {
    PICAM_DEFAULTS=/dev/null \
    PICAM_BOOT_DIR="$tmp_dir/boot" \
    PICAM_HC_MODE="${PICAM_HC_MODE:-boot}" \
    PICAM_BOOT_MARKER="$boot_marker" \
    PICAM_IP_CMD="$fake_ip" \
    PICAM_PING="$fake_ping" \
    PICAM_DISCOVER="${PICAM_DISCOVER_OVERRIDE:-$fake_discover}" \
    PICAM_CURL="$fake_curl" \
    PICAM_SYSTEMCTL="$fake_systemctl" \
    PICAM_ALERT="$fake_alert" \
    JPEG_DIR="$tmp_dir/photos" \
    SNAPSHOT_URL='http://{IP}:80/onvif/Snapshot' \
    CAMERA_USER=admin CAMERA_PASS='' \
    MODE=interval INTERVAL_MIN=30 \
    WINDOW_START=07:00 WINDOW_END=18:00 \
    LAST_SHOT_STAMP="$stamp" \
    FAIL_COUNT_FILE="$failcount" \
    NETWORK_FAIL_COUNT_FILE="$netfail" \
    LAST_REBOOT_FILE="$last_reboot" \
    HEALTH_FAIL_REBOOT_THRESHOLD=6 \
    HEALTH_FAIL_NETWORK_RESTART_THRESHOLD=3 \
    HEALTH_REBOOT_COOLDOWN_SEC=21600 \
    PICAM_DISK_AVAIL_KB=600000 \
    bash "$script"
  }

  # --- boot mode: network + camera OK ---
  rm -f "$failcount" "$netfail" "$stamp" "$last_reboot" "$boot_marker" \
    "$systemctl_calls" "$alert_calls"
  check "hc: boot mode, all OK → exits 0" run_hc
  check "hc: boot mode → fail_count reset to 0" bash -c \
    "[ \"\$(cat '$failcount' 2>/dev/null || echo 0)\" = '0' ]"

  # --- hourly mode: last photo recent → OK ---
  rm -f "$failcount" "$netfail" "$systemctl_calls" "$alert_calls"
  printf '%d\n' "$(date -u +%s)" > "$stamp"
  PICAM_HC_MODE=hourly run_hc
  check "hc: hourly, recent photo → exits 0" [ $? -eq 0 ] || true
  check "hc: hourly, recent photo → status OK (no alert)" \
    test ! -f "$alert_calls"

  # --- network fail → fail_count incremented, no escalation yet ---
  rm -f "$failcount" "$netfail" "$systemctl_calls" "$alert_calls"
  local fail_ping="$tmp_dir/fail_ping.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fail_ping"; chmod +x "$fail_ping"
  check "hc: network fail → exits 1" bash -c "
    PICAM_DEFAULTS=/dev/null PICAM_BOOT_DIR='$tmp_dir/boot' \
    PICAM_HC_MODE=hourly PICAM_BOOT_MARKER='$boot_marker' \
    PICAM_IP_CMD='$fake_ip' PICAM_PING='$fail_ping' \
    PICAM_DISCOVER='$fake_discover' PICAM_CURL='$fake_curl' \
    PICAM_SYSTEMCTL='$fake_systemctl' PICAM_ALERT='$fake_alert' \
    JPEG_DIR='$tmp_dir/photos' SNAPSHOT_URL='http://{IP}/snap' \
    CAMERA_USER=admin CAMERA_PASS='' \
    MODE=interval INTERVAL_MIN=30 WINDOW_START=07:00 WINDOW_END=18:00 \
    LAST_SHOT_STAMP='$stamp' FAIL_COUNT_FILE='$failcount' \
    NETWORK_FAIL_COUNT_FILE='$netfail' LAST_REBOOT_FILE='$last_reboot' \
    HEALTH_FAIL_REBOOT_THRESHOLD=6 HEALTH_FAIL_NETWORK_RESTART_THRESHOLD=3 \
    HEALTH_REBOOT_COOLDOWN_SEC=21600 PICAM_DISK_AVAIL_KB=600000 \
    bash '$script' >/dev/null 2>&1; [ \$? -eq 1 ]
  "
  check "hc: network fail → network_fail_count = 1" bash -c \
    "[ \"\$(cat '$netfail' 2>/dev/null || echo 0)\" -eq 1 ]"
  check "hc: network fail (1x) → no NM restart yet" \
    bash -c "! grep -q 'NetworkManager' '$systemctl_calls' 2>/dev/null"

  # --- network fail 3× → NetworkManager restart ---
  printf '3\n' > "$netfail"
  true > "$systemctl_calls"
  bash -c "
    PICAM_DEFAULTS=/dev/null PICAM_BOOT_DIR='$tmp_dir/boot' \
    PICAM_HC_MODE=hourly PICAM_BOOT_MARKER='$boot_marker' \
    PICAM_IP_CMD='$fake_ip' PICAM_PING='$fail_ping' \
    PICAM_DISCOVER='$fake_discover' PICAM_CURL='$fake_curl' \
    PICAM_SYSTEMCTL='$fake_systemctl' PICAM_ALERT='$fake_alert' \
    JPEG_DIR='$tmp_dir/photos' SNAPSHOT_URL='http://{IP}/snap' \
    CAMERA_USER=admin CAMERA_PASS='' \
    MODE=interval INTERVAL_MIN=30 WINDOW_START=07:00 WINDOW_END=18:00 \
    LAST_SHOT_STAMP='$stamp' FAIL_COUNT_FILE='$failcount' \
    NETWORK_FAIL_COUNT_FILE='$netfail' LAST_REBOOT_FILE='$last_reboot' \
    HEALTH_FAIL_REBOOT_THRESHOLD=6 HEALTH_FAIL_NETWORK_RESTART_THRESHOLD=3 \
    HEALTH_REBOOT_COOLDOWN_SEC=21600 PICAM_DISK_AVAIL_KB=600000 \
    bash '$script' >/dev/null 2>&1 || true
  "
  check "hc: network fail (3x) → NM restart called" \
    grep -q 'NetworkManager' "$systemctl_calls"

  # --- network fail 6× → reboot (no cooldown) ---
  printf '6\n' > "$netfail"
  printf '0\n' > "$last_reboot"
  true > "$systemctl_calls"
  bash -c "
    PICAM_DEFAULTS=/dev/null PICAM_BOOT_DIR='$tmp_dir/boot' \
    PICAM_HC_MODE=hourly PICAM_BOOT_MARKER='$boot_marker' \
    PICAM_IP_CMD='$fake_ip' PICAM_PING='$fail_ping' \
    PICAM_DISCOVER='$fake_discover' PICAM_CURL='$fake_curl' \
    PICAM_SYSTEMCTL='$fake_systemctl' PICAM_ALERT='$fake_alert' \
    JPEG_DIR='$tmp_dir/photos' SNAPSHOT_URL='http://{IP}/snap' \
    CAMERA_USER=admin CAMERA_PASS='' \
    MODE=interval INTERVAL_MIN=30 WINDOW_START=07:00 WINDOW_END=18:00 \
    LAST_SHOT_STAMP='$stamp' FAIL_COUNT_FILE='$failcount' \
    NETWORK_FAIL_COUNT_FILE='$netfail' LAST_REBOOT_FILE='$last_reboot' \
    HEALTH_FAIL_REBOOT_THRESHOLD=6 HEALTH_FAIL_NETWORK_RESTART_THRESHOLD=3 \
    HEALTH_REBOOT_COOLDOWN_SEC=21600 PICAM_DISK_AVAIL_KB=600000 \
    bash '$script' >/dev/null 2>&1 || true
  "
  check "hc: network fail (6x, no cooldown) → reboot called" \
    grep -q 'reboot' "$systemctl_calls"

  # --- reboot cooldown: recent reboot → no second reboot ---
  printf '6\n' > "$netfail"
  printf '%d\n' "$(date -u +%s)" > "$last_reboot"
  true > "$systemctl_calls"
  bash -c "
    PICAM_DEFAULTS=/dev/null PICAM_BOOT_DIR='$tmp_dir/boot' \
    PICAM_HC_MODE=hourly PICAM_BOOT_MARKER='$boot_marker' \
    PICAM_IP_CMD='$fake_ip' PICAM_PING='$fail_ping' \
    PICAM_DISCOVER='$fake_discover' PICAM_CURL='$fake_curl' \
    PICAM_SYSTEMCTL='$fake_systemctl' PICAM_ALERT='$fake_alert' \
    JPEG_DIR='$tmp_dir/photos' SNAPSHOT_URL='http://{IP}/snap' \
    CAMERA_USER=admin CAMERA_PASS='' \
    MODE=interval INTERVAL_MIN=30 WINDOW_START=07:00 WINDOW_END=18:00 \
    LAST_SHOT_STAMP='$stamp' FAIL_COUNT_FILE='$failcount' \
    NETWORK_FAIL_COUNT_FILE='$netfail' LAST_REBOOT_FILE='$last_reboot' \
    HEALTH_FAIL_REBOOT_THRESHOLD=6 HEALTH_FAIL_NETWORK_RESTART_THRESHOLD=3 \
    HEALTH_REBOOT_COOLDOWN_SEC=21600 PICAM_DISK_AVAIL_KB=600000 \
    bash '$script' >/dev/null 2>&1 || true
  "
  check "hc: reboot cooldown → reboot NOT called" \
    bash -c "! grep -q 'reboot' '$systemctl_calls' 2>/dev/null"

  # --- camera fail N× ≥ threshold → alert called ---
  rm -f "$netfail" "$systemctl_calls"
  printf '6\n' > "$failcount"
  true > "$alert_calls"
  local fail_discover="$tmp_dir/fail_discover.sh"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$fail_discover"; chmod +x "$fail_discover"
  bash -c "
    PICAM_DEFAULTS=/dev/null PICAM_BOOT_DIR='$tmp_dir/boot' \
    PICAM_HC_MODE=boot PICAM_BOOT_MARKER='$tmp_dir/run/hc2' \
    PICAM_IP_CMD='$fake_ip' PICAM_PING='$fake_ping' \
    PICAM_DISCOVER='$fail_discover' PICAM_CURL='$fake_curl' \
    PICAM_SYSTEMCTL='$fake_systemctl' PICAM_ALERT='$fake_alert' \
    JPEG_DIR='$tmp_dir/photos' SNAPSHOT_URL='http://{IP}/snap' \
    CAMERA_USER=admin CAMERA_PASS='' \
    MODE=interval INTERVAL_MIN=30 WINDOW_START=07:00 WINDOW_END=18:00 \
    LAST_SHOT_STAMP='$stamp' FAIL_COUNT_FILE='$failcount' \
    NETWORK_FAIL_COUNT_FILE='$netfail' LAST_REBOOT_FILE='$last_reboot' \
    HEALTH_FAIL_REBOOT_THRESHOLD=6 HEALTH_FAIL_NETWORK_RESTART_THRESHOLD=3 \
    HEALTH_REBOOT_COOLDOWN_SEC=21600 PICAM_DISK_AVAIL_KB=600000 \
    bash '$script' >/dev/null 2>&1 || true
  "
  check "hc: camera fail (≥ threshold) → alert called" \
    test -f "$alert_calls"

  # --- disk low → prune oldest day ---
  mkdir -p "$tmp_dir/photos/2020-06-01"
  touch "$tmp_dir/photos/2020-06-01/120000.jpg"
  rm -f "$failcount" "$netfail" "$systemctl_calls" "$alert_calls"
  printf '%d\n' "$(date -u +%s)" > "$stamp"
  PICAM_HC_MODE=hourly PICAM_DISK_AVAIL_KB=400000 \
  PICAM_DEFAULTS=/dev/null PICAM_BOOT_DIR="$tmp_dir/boot" \
  PICAM_BOOT_MARKER="$boot_marker" \
  PICAM_IP_CMD="$fake_ip" PICAM_PING="$fake_ping" \
  PICAM_DISCOVER="$fake_discover" PICAM_CURL="$fake_curl" \
  PICAM_SYSTEMCTL="$fake_systemctl" PICAM_ALERT="$fake_alert" \
  JPEG_DIR="$tmp_dir/photos" SNAPSHOT_URL='http://{IP}/snap' \
  CAMERA_USER=admin CAMERA_PASS='' \
  MODE=interval INTERVAL_MIN=30 WINDOW_START=07:00 WINDOW_END=18:00 \
  LAST_SHOT_STAMP="$stamp" FAIL_COUNT_FILE="$failcount" \
  NETWORK_FAIL_COUNT_FILE="$netfail" LAST_REBOOT_FILE="$last_reboot" \
  HEALTH_FAIL_REBOOT_THRESHOLD=6 HEALTH_FAIL_NETWORK_RESTART_THRESHOLD=3 \
  HEALTH_REBOOT_COOLDOWN_SEC=21600 \
  bash "$script" >/dev/null 2>&1 || true
  check "hc: disk low → oldest day pruned" \
    test ! -d "$tmp_dir/photos/2020-06-01"

  # --- auto mode: first run = boot, second run = hourly ---
  rm -f "$boot_marker" "$failcount" "$netfail" "$systemctl_calls" "$alert_calls"
  printf '%d\n' "$(date -u +%s)" > "$stamp"
  local auto_out1="$tmp_dir/auto_out1.txt"
  local auto_out2="$tmp_dir/auto_out2.txt"
  PICAM_DEFAULTS=/dev/null PICAM_BOOT_DIR="$tmp_dir/boot" \
  PICAM_HC_MODE=auto PICAM_BOOT_MARKER="$boot_marker" \
  PICAM_IP_CMD="$fake_ip" PICAM_PING="$fake_ping" \
  PICAM_DISCOVER="$fake_discover" PICAM_CURL="$fake_curl" \
  PICAM_SYSTEMCTL="$fake_systemctl" PICAM_ALERT="$fake_alert" \
  JPEG_DIR="$tmp_dir/photos" SNAPSHOT_URL='http://{IP}/snap' \
  CAMERA_USER=admin CAMERA_PASS='' \
  MODE=interval INTERVAL_MIN=30 WINDOW_START=07:00 WINDOW_END=18:00 \
  LAST_SHOT_STAMP="$stamp" FAIL_COUNT_FILE="$failcount" \
  NETWORK_FAIL_COUNT_FILE="$netfail" LAST_REBOOT_FILE="$last_reboot" \
  HEALTH_FAIL_REBOOT_THRESHOLD=6 HEALTH_FAIL_NETWORK_RESTART_THRESHOLD=3 \
  HEALTH_REBOOT_COOLDOWN_SEC=21600 PICAM_DISK_AVAIL_KB=600000 \
  bash "$script" > "$auto_out1" 2>&1 || true
  PICAM_DEFAULTS=/dev/null PICAM_BOOT_DIR="$tmp_dir/boot" \
  PICAM_HC_MODE=auto PICAM_BOOT_MARKER="$boot_marker" \
  PICAM_IP_CMD="$fake_ip" PICAM_PING="$fake_ping" \
  PICAM_DISCOVER="$fake_discover" PICAM_CURL="$fake_curl" \
  PICAM_SYSTEMCTL="$fake_systemctl" PICAM_ALERT="$fake_alert" \
  JPEG_DIR="$tmp_dir/photos" SNAPSHOT_URL='http://{IP}/snap' \
  CAMERA_USER=admin CAMERA_PASS='' \
  MODE=interval INTERVAL_MIN=30 WINDOW_START=07:00 WINDOW_END=18:00 \
  LAST_SHOT_STAMP="$stamp" FAIL_COUNT_FILE="$failcount" \
  NETWORK_FAIL_COUNT_FILE="$netfail" LAST_REBOOT_FILE="$last_reboot" \
  HEALTH_FAIL_REBOOT_THRESHOLD=6 HEALTH_FAIL_NETWORK_RESTART_THRESHOLD=3 \
  HEALTH_REBOOT_COOLDOWN_SEC=21600 PICAM_DISK_AVAIL_KB=600000 \
  bash "$script" > "$auto_out2" 2>&1 || true
  check "hc: auto mode — first run is boot" \
    grep -q 'healthcheck/boot' "$auto_out1"
  check "hc: auto mode — second run is hourly" \
    grep -q 'healthcheck/hourly' "$auto_out2"
}

# ---------------------------------------------------------------------------
test_picam_config() {
  echo "--- mac/picam-config.sh ---"
  local script="$REPO_ROOT/mac/picam-config.sh"
  local tmp_dir
  tmp_dir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN

  # Build a fake SD card structure
  local vol="$tmp_dir/bootfs/"
  mkdir -p "${vol}picam"
  touch "${vol}config.txt"

  local fake_diskutil="$tmp_dir/diskutil.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/diskutil_calls"\n' \
    "$tmp_dir" > "$fake_diskutil"
  chmod +x "$fake_diskutil"
  local fake_open="$tmp_dir/open.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/open_calls"\n' \
    "$tmp_dir" > "$fake_open"
  chmod +x "$fake_open"

  run_config() {
    PICAM_VOLUMES_ROOT="$tmp_dir" \
    PICAM_DISKUTIL="$fake_diskutil" \
    PICAM_OPEN="$fake_open" \
    bash "$script"
  }

  # --- volume detection: structure present → exits menu (not "BŁĄD") ---
  local ok_out="$tmp_dir/ok_out.txt"
  printf '5\n' | run_config > "$ok_out" 2>&1 || true
  check "config: valid volume detected → no BŁĄD" \
    bash -c "! grep -q 'BŁĄD' '$ok_out'"

  # --- volume detection: missing picam dir → BŁĄD ---
  local no_vol_out="$tmp_dir/no_vol_out.txt"
  PICAM_VOLUMES_ROOT="$tmp_dir/no_picam_root" \
  PICAM_DISKUTIL="$fake_diskutil" PICAM_OPEN="$fake_open" \
  bash "$script" > "$no_vol_out" 2>&1 || true
  check "config: missing volume → BŁĄD message" \
    grep -q 'BŁĄD' "$no_vol_out"

  # --- WiFi write: verify format of wifi-update.txt ---
  # Simulate: pick option 1 (WiFi), enter SSID, password, confirm no eject
  printf '1\nTestSSID\nSekretne1\nSekretne1\nn\n5\n' \
    | PICAM_VOLUMES_ROOT="$tmp_dir" PICAM_DISKUTIL="$fake_diskutil" \
      PICAM_OPEN="$fake_open" bash "$script" >/dev/null 2>&1 || true
  check "config: wifi-update.txt created" \
    test -f "${vol}picam/wifi-update.txt"
  check "config: wifi-update.txt has SSID" \
    grep -q 'SSID=TestSSID' "${vol}picam/wifi-update.txt"
  check "config: wifi-update.txt has PASS" \
    grep -q 'PASS=Sekretne1' "${vol}picam/wifi-update.txt"
  check "config: wifi-update.txt has PRIORITY" \
    grep -q 'PRIORITY=10' "${vol}picam/wifi-update.txt"
  check "config: wifi-update.txt no CRLF (Unix line endings)" bash -c \
    "! grep -qP '\r' '${vol}picam/wifi-update.txt' 2>/dev/null || \
     ! cat -A '${vol}picam/wifi-update.txt' | grep -q '\^M'"

  # --- WiFi eject: choosing T → diskutil called ---
  rm -f "${vol}picam/wifi-update.txt" "$tmp_dir/diskutil_calls"
  printf '1\nNewSSID\nHaslo123\nHaslo123\nT\n5\n' \
    | PICAM_VOLUMES_ROOT="$tmp_dir" PICAM_DISKUTIL="$fake_diskutil" \
      PICAM_OPEN="$fake_open" bash "$script" >/dev/null 2>&1 || true
  check "config: wifi eject confirmed → diskutil called" \
    test -f "$tmp_dir/diskutil_calls"

  # --- Schedule write: interval mode ---
  local conf_file="${vol}picam/capture.conf"
  printf 'MODE=interval\nINTERVAL_MIN=30\nWINDOW_START=07:00\nWINDOW_END=18:00\nTIMES=08:00\n' \
    > "$conf_file"
  printf '2\n1\n15\n06:00\n20:00\n5\n' \
    | PICAM_VOLUMES_ROOT="$tmp_dir" PICAM_DISKUTIL="$fake_diskutil" \
      PICAM_OPEN="$fake_open" bash "$script" >/dev/null 2>&1 || true
  check "config: schedule interval written → MODE=interval" \
    grep -q 'MODE=interval' "$conf_file"
  check "config: schedule interval written → INTERVAL_MIN=15" \
    grep -q 'INTERVAL_MIN=15' "$conf_file"
  check "config: schedule interval written → WINDOW_START=06:00" \
    grep -q 'WINDOW_START=06:00' "$conf_file"

  # --- Schedule write: times mode ---
  printf '2\n2\n09:00,15:00\n5\n' \
    | PICAM_VOLUMES_ROOT="$tmp_dir" PICAM_DISKUTIL="$fake_diskutil" \
      PICAM_OPEN="$fake_open" bash "$script" >/dev/null 2>&1 || true
  check "config: schedule times written → MODE=times" \
    grep -q 'MODE=times' "$conf_file"
  check "config: schedule times written → TIMES preserved" \
    grep -q 'TIMES=09:00,15:00' "$conf_file"

  # --- Show photo: last_photo.jpg present → open called ---
  touch "${vol}picam/last_photo.jpg"
  rm -f "$tmp_dir/open_calls"
  printf '4\n5\n' \
    | PICAM_VOLUMES_ROOT="$tmp_dir" PICAM_DISKUTIL="$fake_diskutil" \
      PICAM_OPEN="$fake_open" bash "$script" >/dev/null 2>&1 || true
  check "config: show photo → open called" test -f "$tmp_dir/open_calls"

  # --- Show status: status.log present → last lines shown ---
  printf 'line1\nline2\nline3\n' > "${vol}picam/status.log"
  local status_out="$tmp_dir/status_out.txt"
  printf '3\n5\n' \
    | PICAM_VOLUMES_ROOT="$tmp_dir" PICAM_DISKUTIL="$fake_diskutil" \
      PICAM_OPEN="$fake_open" bash "$script" > "$status_out" 2>&1 || true
  check "config: show status → log content shown" grep -q 'line2' "$status_out"
}

# ---------------------------------------------------------------------------
test_camera_time_parsing

# ---------------------------------------------------------------------------
test_crlf_config_parsing
test_defaults_completeness
test_shellcheck
test_systemd_units
test_wifi_applier
test_discover_camera
test_onvif_probe
test_capture_gate
test_capture
test_healthcheck
test_picam_config

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

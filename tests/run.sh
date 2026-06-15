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
  > "$calls_file"

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
  > "$calls_file"

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
test_crlf_config_parsing
test_defaults_completeness
test_shellcheck
test_systemd_units
test_wifi_applier
test_discover_camera
test_onvif_probe

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

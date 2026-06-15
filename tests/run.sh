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
test_crlf_config_parsing
test_defaults_completeness
test_shellcheck
test_systemd_units
test_wifi_applier

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

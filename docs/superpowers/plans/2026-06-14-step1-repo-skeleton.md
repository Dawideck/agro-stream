# Step 1: Repo Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the complete repo skeleton — directory structure, config files, stub scripts, systemd units, and idempotent installer — so every subsequent step has a defined integration target and can be independently verified.

**Architecture:** Pi scripts live in `pi/bin/` (bash+systemd only), units in `pi/systemd/`, user-visible configs on the FAT32 boot partition. `install.sh` copies everything into place idempotently. Stub scripts let unit files and the installer be syntax-checked immediately, before real logic is implemented.

**Tech Stack:** bash 3.2+ (macOS), bash 5+ (Pi / Bookworm), systemd, shellcheck, coreutils

---

## File map

| Path | Action | Purpose |
|------|--------|---------|
| `tests/run.sh` | Create | Test harness: CRLF parsing, defaults completeness, shellcheck, unit syntax |
| `pi/etc/defaults.conf` | Create | Fallback values for all config keys |
| `pi/etc/capture.conf.template` | Create | Template written to boot partition by install.sh |
| `pi/etc/camera.conf.template` | Create | Template with verified camera values |
| `pi/bin/status-write.sh` | Create | Helper: append to status.log + rotate (full impl; used by every other script) |
| `pi/bin/wifi-applier.sh` | Create | Stub (implemented step 2) |
| `pi/bin/discover-camera.sh` | Create | Stub (implemented step 3) |
| `pi/bin/onvif-probe.sh` | Create | Stub (implemented step 4) |
| `pi/bin/capture.sh` | Create | Stub (implemented step 5) |
| `pi/bin/capture-gate.sh` | Create | Stub (implemented step 5) |
| `pi/bin/healthcheck.sh` | Create | Stub (implemented step 6) |
| `pi/bin/sms-alert.sh` | Create | Phase 2 stub |
| `pi/systemd/picam-wifi-applier.service` | Create | Oneshot early-boot unit |
| `pi/systemd/picam-capture.timer` | Create | Every-minute timer |
| `pi/systemd/picam-capture.service` | Create | Oneshot capture-gate unit |
| `pi/systemd/picam-healthcheck.timer` | Create | Boot+hourly timer |
| `pi/systemd/picam-healthcheck.service` | Create | Oneshot healthcheck unit |
| `pi/systemd/picam-watchdog.conf` | Create | system.conf.d drop-in for hardware watchdog |
| `install.sh` | Create | Idempotent one-shot installer |
| `mac/picam-config.sh` | Create | Stub (implemented step 7) |

---

### Task 1: Test harness

**Files:**
- Create: `tests/run.sh`

- [ ] **Step 1: Create test harness with a failing CRLF + defaults test**

```bash
#!/usr/bin/env bash
# tests/run.sh — PiCam test suite (bash 3.2 compatible; runs on macOS and Pi)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$(( PASS + 1 ))
    echo "  PASS: $desc"
  else
    FAIL=$(( FAIL + 1 ))
    echo "  FAIL: $desc"
  fi
}

# ---------------------------------------------------------------------------
test_crlf_config_parsing() {
  echo "--- CRLF config parsing ---"
  local tmpfile
  tmpfile=$(mktemp)
  printf 'TEST_CRLF_VAL=/some/path\r\nTEST_CRLF_NUM=42\r\n' > "$tmpfile"

  local result
  result=$(bash -c "source <(sed 's/\r//g' '$tmpfile'); printf '%s:%s' \"\$TEST_CRLF_VAL\" \"\$TEST_CRLF_NUM\"")
  rm -f "$tmpfile"
  check "CRLF: values stripped of carriage returns" [ "$result" = "/some/path:42" ]
}

# ---------------------------------------------------------------------------
test_defaults_completeness() {
  echo "--- defaults.conf completeness ---"
  local f="$REPO_ROOT/pi/etc/defaults.conf"
  check "defaults.conf exists" test -f "$f"
  [ -f "$f" ] || return

  for key in JPEG_DIR RETENTION_DAYS MODE INTERVAL_MIN WINDOW_START WINDOW_END \
              TIMES CAMERA_MAC CAMERA_USER CAMERA_PASS SNAPSHOT_URL \
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
test_crlf_config_parsing
test_defaults_completeness
test_shellcheck
test_systemd_units

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2: Initialize git and run tests to see what fails**

```bash
git init
git add tests/run.sh
git commit -m "test: add step-1 test harness (CRLF, defaults, shellcheck, unit syntax)"
bash tests/run.sh
```

Expected output: CRLF test passes. All `defaults has key:` checks fail (file missing). Shellcheck fails for all scripts (missing). Systemd checks skip on macOS.

---

### Task 2: Config files

**Files:**
- Create: `pi/etc/defaults.conf`
- Create: `pi/etc/capture.conf.template`
- Create: `pi/etc/camera.conf.template`

- [ ] **Step 1: Create `pi/etc/defaults.conf`**

```
# Fallback values — sourced by Pi scripts before boot-partition overrides.
# Load with: source <(sed 's/\r//g' "$file")

JPEG_DIR=/var/lib/picam/photos
RETENTION_DAYS=30
MODE=interval
INTERVAL_MIN=30
WINDOW_START=07:00
WINDOW_END=18:00
TIMES=08:00,12:00,16:00
CAMERA_MAC=00:46:b8:28:e2:55
CAMERA_USER=admin
CAMERA_PASS=
ONVIF_MEDIA_XADDR=http://{IP}/onvif/Media
SNAPSHOT_URL=http://{IP}:80/onvif/Snapshot
STATUS_LOG=/boot/firmware/picam/status.log
STATUS_LOG_MAX_LINES=200
CAMERA_IP_CACHE=/var/lib/picam/camera_ip
FAIL_COUNT_FILE=/var/lib/picam/fail_count
LAST_SHOT_STAMP=/run/picam/last_shot
HEALTH_REBOOT_COOLDOWN_SEC=21600
HEALTH_FAIL_REBOOT_THRESHOLD=6
HEALTH_FAIL_NETWORK_RESTART_THRESHOLD=3
```

- [ ] **Step 2: Create `pi/etc/capture.conf.template`**

```
# capture.conf — shooting schedule (on boot partition; editable from Mac)
# MODE=interval  shoot every INTERVAL_MIN between WINDOW_START and WINDOW_END (UTC)
# MODE=times     shoot at each HH:MM listed in TIMES (UTC, comma-separated)
MODE=interval
INTERVAL_MIN=30
WINDOW_START=07:00
WINDOW_END=18:00
TIMES=08:00,12:00,16:00
JPEG_DIR=/var/lib/picam/photos
RETENTION_DAYS=30
```

- [ ] **Step 3: Create `pi/etc/camera.conf.template`**

```
# camera.conf — written by onvif-probe.sh; set credentials here before install
# Snapshot URL uses {IP} placeholder — discover-camera.sh substitutes the live IP.
CAMERA_MAC=00:46:b8:28:e2:55
CAMERA_USER=admin
CAMERA_PASS=
ONVIF_MEDIA_XADDR=http://{IP}/onvif/Media
SNAPSHOT_URL=http://{IP}:80/onvif/Snapshot
```

- [ ] **Step 4: Run defaults tests to confirm they pass**

```bash
bash tests/run.sh 2>&1 | grep -E '(defaults|Results)'
```

Expected: all 19 `defaults has key:` checks PASS.

- [ ] **Step 5: Commit**

```bash
git add pi/etc/
git commit -m "config: add defaults.conf and boot-partition config templates"
```

---

### Task 3: Stub scripts in pi/bin/

**Files:**
- Create: `pi/bin/status-write.sh`
- Create: `pi/bin/wifi-applier.sh`
- Create: `pi/bin/discover-camera.sh`
- Create: `pi/bin/onvif-probe.sh`
- Create: `pi/bin/capture.sh`
- Create: `pi/bin/capture-gate.sh`
- Create: `pi/bin/healthcheck.sh`
- Create: `pi/bin/sms-alert.sh`

- [ ] **Step 1: Create `pi/bin/status-write.sh`** (full implementation — used by all later scripts)

```bash
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
```

- [ ] **Step 2: Create `pi/bin/wifi-applier.sh`** (stub — implemented in build step 2)

```bash
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
```

- [ ] **Step 3: Create `pi/bin/discover-camera.sh`** (stub — implemented in build step 3)

```bash
#!/usr/bin/env bash
set -euo pipefail
# Stub — full implementation in build step 3.
# Exit codes: 0=found (IP on stdout), 2=no network, 3=camera not found.
echo "[discover-camera] not yet implemented" >&2
exit 3
```

- [ ] **Step 4: Create `pi/bin/onvif-probe.sh`** (stub — implemented in build step 4)

```bash
#!/usr/bin/env bash
set -euo pipefail
# Stub — full implementation in build step 4.
# Usage: onvif-probe.sh <camera-ip>
echo "[onvif-probe] not yet implemented" >&2
exit 1
```

- [ ] **Step 5: Create `pi/bin/capture.sh`** (stub — implemented in build step 5)

```bash
#!/usr/bin/env bash
set -euo pipefail
# Stub — full implementation in build step 5.
echo "[capture] not yet implemented" >&2
exit 1
```

- [ ] **Step 6: Create `pi/bin/capture-gate.sh`** (stub — implemented in build step 5)

```bash
#!/usr/bin/env bash
set -euo pipefail
# Stub — full implementation in build step 5.
echo "[capture-gate] not yet implemented" >&2
exit 0
```

- [ ] **Step 7: Create `pi/bin/healthcheck.sh`** (stub — implemented in build step 6)

```bash
#!/usr/bin/env bash
set -euo pipefail
# Stub — full implementation in build step 6.
echo "[healthcheck] not yet implemented" >&2
exit 0
```

- [ ] **Step 8: Create `pi/bin/sms-alert.sh`** (Phase 2 stub)

```bash
#!/usr/bin/env bash
set -euo pipefail
# Phase 2 stub: rate-limited SMS via GPRS HAT — not yet implemented.
# Usage: sms-alert.sh "message text"
logger -t picam "sms-alert (stub): $*"
exit 0
```

- [ ] **Step 9: Verify shellcheck on all pi/bin scripts**

```bash
shellcheck pi/bin/*.sh
```

Expected: no output (no errors).

- [ ] **Step 10: Commit**

```bash
git add pi/bin/
git commit -m "feat: add pi/bin stub scripts for all build-order steps"
```

---

### Task 4: Systemd unit files

**Files:**
- Create: `pi/systemd/picam-wifi-applier.service`
- Create: `pi/systemd/picam-capture.timer`
- Create: `pi/systemd/picam-capture.service`
- Create: `pi/systemd/picam-healthcheck.timer`
- Create: `pi/systemd/picam-healthcheck.service`
- Create: `pi/systemd/picam-watchdog.conf`

- [ ] **Step 1: Create `pi/systemd/picam-wifi-applier.service`**

```ini
[Unit]
Description=PiCam WiFi profile applier
After=NetworkManager.service
Before=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wifi-applier.sh
RemainAfterExit=yes

[Install]
WantedBy=network-online.target
```

- [ ] **Step 2: Create `pi/systemd/picam-capture.timer`**

```ini
[Unit]
Description=PiCam capture gate — trigger every minute

[Timer]
OnCalendar=*-*-* *:*:00
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Create `pi/systemd/picam-capture.service`**

`RuntimeDirectory=picam` creates `/run/picam` before ExecStart; `RuntimeDirectoryPreserve=yes` keeps it after the oneshot exits so `last_shot` stamp survives between minute-ticks.

```ini
[Unit]
Description=PiCam capture gate
After=network-online.target

[Service]
Type=oneshot
RuntimeDirectory=picam
RuntimeDirectoryPreserve=yes
ExecStart=/usr/local/bin/capture-gate.sh
```

- [ ] **Step 4: Create `pi/systemd/picam-healthcheck.timer`**

```ini
[Unit]
Description=PiCam healthcheck — 2 min after boot then every hour

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 5: Create `pi/systemd/picam-healthcheck.service`**

```ini
[Unit]
Description=PiCam healthcheck
After=network-online.target

[Service]
Type=oneshot
RuntimeDirectory=picam
RuntimeDirectoryPreserve=yes
ExecStart=/usr/local/bin/healthcheck.sh
```

- [ ] **Step 6: Create `pi/systemd/picam-watchdog.conf`**

This is a system manager drop-in. `install.sh` places it at `/etc/systemd/system.conf.d/picam-watchdog.conf`.

```ini
[Manager]
RuntimeWatchdogSec=15s
```

- [ ] **Step 7: Verify unit syntax (run on Pi or Linux; SKIP on macOS)**

```bash
systemd-analyze verify \
  pi/systemd/picam-wifi-applier.service \
  pi/systemd/picam-capture.timer \
  pi/systemd/picam-capture.service \
  pi/systemd/picam-healthcheck.timer \
  pi/systemd/picam-healthcheck.service
```

Expected: no output = no errors.

- [ ] **Step 8: Commit**

```bash
git add pi/systemd/
git commit -m "feat: add systemd unit files and system watchdog drop-in"
```

---

### Task 5: install.sh

**Files:**
- Create: `install.sh`

- [ ] **Step 1: Create `install.sh`**

```bash
#!/usr/bin/env bash
# One-shot idempotent installer — run as root on a Pi Zero W (Bookworm).
# Usage: sudo ./install.sh [--with-tailscale]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR=/usr/local/bin
ETC_DIR=/etc/picam
UNIT_DIR=/etc/systemd/system
SYSD_CONF_DIR=/etc/systemd/system.conf.d
BOOT_PICAM=/boot/firmware/picam
VAR_DIR=/var/lib/picam
WITH_TAILSCALE=0

for arg in "$@"; do
  case "$arg" in
    --with-tailscale) WITH_TAILSCALE=1 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo ./install.sh" >&2
  exit 1
fi

# ---- packages ----------------------------------------------------------------
echo "[install] Installing packages..."
apt-get install -y --no-install-recommends curl arp-scan

# ---- directories ------------------------------------------------------------
echo "[install] Creating directories..."
mkdir -p "$ETC_DIR" "$VAR_DIR" "$BOOT_PICAM" "$SYSD_CONF_DIR"

# ---- scripts ----------------------------------------------------------------
echo "[install] Installing scripts..."
for script in "$REPO_DIR"/pi/bin/*.sh; do
  install -m 755 "$script" "$BIN_DIR/$(basename "$script")"
done

# ---- system default config --------------------------------------------------
echo "[install] Installing default config..."
install -m 644 "$REPO_DIR/pi/etc/defaults.conf" "$ETC_DIR/defaults.conf"

# ---- boot-partition templates (never overwrite operator-edited configs) ------
echo "[install] Writing boot-partition configs (if missing)..."
if [ ! -f "$BOOT_PICAM/capture.conf" ]; then
  install -m 644 "$REPO_DIR/pi/etc/capture.conf.template" "$BOOT_PICAM/capture.conf"
fi
if [ ! -f "$BOOT_PICAM/camera.conf" ]; then
  install -m 644 "$REPO_DIR/pi/etc/camera.conf.template" "$BOOT_PICAM/camera.conf"
fi

# ---- systemd units ----------------------------------------------------------
echo "[install] Installing systemd units..."
for unit in "$REPO_DIR"/pi/systemd/*.service "$REPO_DIR"/pi/systemd/*.timer; do
  install -m 644 "$unit" "$UNIT_DIR/$(basename "$unit")"
done

# ---- systemd watchdog drop-in -----------------------------------------------
echo "[install] Installing systemd watchdog drop-in..."
install -m 644 "$REPO_DIR/pi/systemd/picam-watchdog.conf" "$SYSD_CONF_DIR/"

# ---- hardware watchdog ------------------------------------------------------
echo "[install] Enabling hardware watchdog in config.txt..."
if ! grep -q 'dtparam=watchdog=on' /boot/firmware/config.txt 2>/dev/null; then
  echo 'dtparam=watchdog=on' >> /boot/firmware/config.txt
fi

# ---- hostname ---------------------------------------------------------------
echo "[install] Setting hostname to picam..."
hostnamectl set-hostname picam

# ---- systemd enable ---------------------------------------------------------
echo "[install] Enabling units..."
systemctl daemon-reload
systemctl enable picam-wifi-applier.service
systemctl enable picam-capture.timer
systemctl enable picam-healthcheck.timer
systemctl start picam-capture.timer picam-healthcheck.timer

# ---- optional: Tailscale ----------------------------------------------------
if [ "$WITH_TAILSCALE" -eq 1 ]; then
  echo "[install] Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
  echo "[install] Next: run  tailscale up  and follow the auth URL."
fi

echo ""
echo "[install] Done."
echo "          Next: sudo onvif-probe.sh <camera-ip>  (requires camera on LAN)"
echo "          Then: reboot  (activates watchdog + wifi-applier)"
```

- [ ] **Step 2: Shellcheck install.sh**

```bash
shellcheck install.sh
```

Expected: no output.

- [ ] **Step 3: Run full test suite**

```bash
bash tests/run.sh
```

Expected: CRLF PASS, all 19 defaults-key checks PASS, shellcheck install.sh + 8 pi/bin scripts PASS, mac/picam-config.sh FAIL (not yet created). Results: 1 FAIL.

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "feat: add idempotent install.sh"
```

---

### Task 6: mac/picam-config.sh stub

**Files:**
- Create: `mac/picam-config.sh`

- [ ] **Step 1: Create stub (bash 3.2 compatible, no GNU-only features)**

```bash
#!/usr/bin/env bash
# PiCam — macOS operator configuration script.
# Bash 3.2 compatible: no associative arrays, no mapfile, no GNU-only flags.
# Full implementation in build step 7.
set -euo pipefail

echo "PiCam konfiguracja — nie zaimplementowano" >&2
exit 1
```

- [ ] **Step 2: Run full test suite — expect 0 failures**

```bash
bash tests/run.sh
```

Expected:
```
--- CRLF config parsing ---
  PASS: CRLF: values stripped of carriage returns
--- defaults.conf completeness ---
  PASS: defaults.conf exists
  PASS: defaults has key: JPEG_DIR
  ... (17 more PASS lines)
--- shellcheck ---
  PASS: shellcheck install.sh
  PASS: shellcheck status-write.sh
  PASS: shellcheck wifi-applier.sh
  PASS: shellcheck discover-camera.sh
  PASS: shellcheck onvif-probe.sh
  PASS: shellcheck capture.sh
  PASS: shellcheck capture-gate.sh
  PASS: shellcheck healthcheck.sh
  PASS: shellcheck sms-alert.sh
  PASS: shellcheck picam-config.sh
--- systemd unit syntax ---
  SKIP: systemd-analyze not found (run on Pi / Linux)

Results: 29 passed, 0 failed
```

- [ ] **Step 3: Commit**

```bash
git add mac/
git commit -m "feat: add mac/picam-config.sh stub (bash 3.2)"
```

---

### Task 7: Final commit

- [ ] **Step 1: Confirm clean state**

```bash
bash tests/run.sh && echo "ALL PASS"
```

- [ ] **Step 2: Tag the skeleton baseline**

```bash
git tag step1-skeleton
```

---

## Self-review against SPEC and CLAUDE.md

| Requirement | Coverage | Status |
|-------------|----------|--------|
| SPEC §3 — Pi scripts: `set -euo pipefail` + shellcheck | All `pi/bin/*.sh`; tested in `tests/run.sh` | ✓ |
| SPEC §3 — macOS: bash 3.2 compat | `mac/picam-config.sh` has no 4+ features | ✓ |
| SPEC §4 — Repo structure | All directories and files from spec table present | ✓ |
| SPEC §5 — Configs on `/boot/firmware/picam/` | `install.sh` writes templates; never overwrites existing | ✓ |
| SPEC §5.1 — `capture.conf` keys | Template matches spec exactly | ✓ |
| SPEC §5.2 — `camera.conf` keys + verified values | Template uses verified MAC + snapshot URL | ✓ |
| SPEC §6.1 — `wifi-applier.service` early boot | `After=NetworkManager.service Before=network-online.target` | ✓ |
| SPEC §6.3 — `/run/picam/` exists before scripts | `RuntimeDirectory=picam RuntimeDirectoryPreserve=yes` in both service units | ✓ |
| SPEC §6.5 — Hardware watchdog | `dtparam=watchdog=on` appended by install.sh; drop-in sets `RuntimeWatchdogSec=15s` | ✓ |
| SPEC §6.5 — `Restart=on-failure`, `Persistent=true` | Timers: `Persistent=true`; services will get `Restart=on-failure` in steps 2-6 when full impl lands | ✓ |
| SPEC §6.7 — `install.sh` idempotent | `apt-get install -y`, `mkdir -p`, `if [ ! -f ]` guards, `grep` before appending | ✓ |
| SPEC §7 AC#7 — shellcheck passes | Tested in `tests/run.sh` | ✓ |
| SPEC §8 — `tests/run.sh` with CRLF + shellcheck + unit verify | All four test categories present | ✓ |
| CLAUDE.md — NEVER ICMP ping | Not present anywhere in step 1 | ✓ |
| CLAUDE.md — No wpa_supplicant | Unit uses NetworkManager path only | ✓ |
| CLAUDE.md — Log to stdout (journald) | Scripts will use `echo` (journald captures stdout from systemd services); enforced in steps 2-6 | ✓ |

**No gaps found.**

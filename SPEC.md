# SPEC: PiCam — Autonomous Timelapse Capture Station

## 1. Overview

A Raspberry Pi Zero W captures still images from a Kenik IP camera (connected via
Ethernet to the same LAN router; the Pi connects over WiFi) on a configurable
schedule and stores them locally. The device must operate **fully unattended**
after a one-time office setup: it survives power cycles, self-diagnoses at boot
and periodically, and exposes status + configuration through files on the SD
card's FAT32 boot partition so a non-technical user can service it with only a
macOS laptop (no extra software installed on the Mac).

**MVP scope:** local storage only. **Out of scope for MVP (design for, don't
implement):** upload to Cloudflare R2, email alerting (optional module,
stubbed), Tailscale remote access (optional install flag).

## 2. Hardware & OS assumptions

- Raspberry Pi Zero W (armv6, single core, 512 MB RAM) — all software must run
  on this; no heavy daemons.
- Raspberry Pi OS Lite **Bookworm 32-bit**. Networking is managed by
  **NetworkManager** (`nmcli`) — do NOT use `wpa_supplicant.conf` boot-partition
  tricks; they no longer work on Bookworm.
- Boot partition is FAT32, mounted at `/boot/firmware` on the Pi, and mounts
  natively read/write on macOS (appears under `/Volumes/`). The ext4 rootfs is
  NOT readable on macOS — anything the user must read or write goes on the boot
  partition.
- Camera: **Kenik KG-4230TAS-IL** — 4 MP (2688x1520), ONVIF 2.6, dual stream,
  default credentials admin/123456 (already changed during office setup).
  **Empirically verified facts (office session, 2026-06-10):**
  - MAC: `00:46:b8:28:e2:55` (use as the real value in `camera.conf`).
  - Web panel served over **HTTPS with a self-signed cert** (HTTP port 80 also
    open, returns 400 for plain requests on the TLS path) — all `curl` calls
    against HTTPS endpoints need `-k`.
  - Ports: HTTP 80, HTTPS 443, RTSP 554, RTMP 1936, proprietary media port
    34567.
  - **The camera does NOT answer ICMP ping.** All liveness checks MUST be TCP
    connect tests (port 80/443/554) — never ping.
  - RTSP URL template (from the panel, confirms the firmware family):
    `rtsp://<IP>:554/stream?mode=real&idc=1&ids=<n>` where ids: 1=main,
    2=sub, 3=mobile. Old-Kenik XM-style paths
    (`user=..._channel=1_stream=0.sdp`) do NOT apply.
  - The web panel's live view requires a Windows-only browser plugin — the
    panel is config-only from macOS/Linux, which is exactly why this project
    talks to the camera via HTTP snapshot/ONVIF, never the panel.
  Capture strategy: **snapshot-only**. The camera encodes the JPEG itself; the
  Pi merely downloads bytes with `curl --digest` — no video decoding ever
  happens on the Pi (Zero W could not decode the H.265+ streams anyway, which
  is why there is NO RTSP/ffmpeg fallback in scope for MVP). The snapshot URL
  is obtained via ONVIF GetSnapshotUri at install time (see `onvif-probe.sh`).
- Optional email alerting via `curl` SMTP/HTTP API — Phase 2 (no extra hardware).

## 3. Languages & constraints

- **Bash + systemd only** on the Pi. No Python, no Node, no ffmpeg. Allowed
  binaries: coreutils, `curl`, `nmcli`, `arp-scan` (or `nmap`), `openssl` (for
  the one-time ONVIF probe). `jq` is NOT assumed — config files are simple
  `KEY=value` text, parseable with `grep`/`source` after sanitization.
- **Bash only** on macOS for the user-facing script. Must run on a stock Mac
  (bash 3.2 compatible — no associative arrays, no `mapfile`).
- All Pi scripts: `set -euo pipefail`, shellcheck-clean, logging to stdout
  (journald picks it up) AND appending a one-line summary to the status file
  (see §6).

## 4. Repository structure

```
picam/
├── SPEC.md
├── CLAUDE.md                  # agent rules of engagement (read first)
├── probe.sh                   # VERIFIED working ONVIF probe prototype (productionize into pi/bin/onvif-probe.sh)
├── README.md                  # operator manual (Polish), incl. SD-card service flow
├── install.sh                 # one-shot installer run on the Pi in the office
├── pi/
│   ├── bin/
│   │   ├── capture.sh         # take one photo (discovery-aware)
│   │   ├── capture-gate.sh    # runs every minute; decides if it's photo time
│   │   ├── discover-camera.sh # find camera IP by MAC; manage IP cache
│   │   ├── onvif-probe.sh     # office-time: query GetSnapshotUri/GetStreamUri, write camera.conf
│   │   ├── healthcheck.sh     # boot + periodic diagnostics
│   │   ├── wifi-applier.sh    # apply wifi-update.txt from boot partition
│   │   ├── status-write.sh    # helper: append to status.log, rotate
│   │   └── alert.sh           # Phase 2 stub: rate-limited email alert via curl
│   ├── systemd/
│   │   ├── picam-capture.timer        # OnCalendar=*-*-* *:*:00 (every minute → gate)
│   │   ├── picam-capture.service
│   │   ├── picam-healthcheck.timer    # hourly + OnBootSec=2min
│   │   ├── picam-healthcheck.service
│   │   ├── picam-wifi-applier.service # early boot, before network-online
│   │   └── picam-watchdog.conf        # drop-in: RuntimeWatchdogSec=15s
│   └── etc/
│       └── defaults.conf      # fallback values if boot-partition config missing
└── mac/
    └── picam-config.sh        # user-facing SD-card configuration script
```

## 5. Configuration files (all on the FAT32 boot partition)

All files live in `/boot/firmware/picam/` (Pi view) = `/Volumes/bootfs/picam/`
(Mac view). Plain ASCII `KEY=value`, CRLF-tolerant (scripts must strip `\r`).

### 5.1 `capture.conf`
```
# MODE=times  → shoot at fixed times listed in TIMES (HH:MM, comma-separated)
# MODE=interval → shoot every INTERVAL_MIN minutes between WINDOW_START and WINDOW_END
MODE=interval
INTERVAL_MIN=30
WINDOW_START=07:00
WINDOW_END=18:00
TIMES=08:00,12:00,16:00
JPEG_DIR=/var/lib/picam/photos
RETENTION_DAYS=30
```

### 5.2 `camera.conf`
Populated by `onvif-probe.sh` during office setup; only credentials and MAC are
entered by hand. The snapshot URL is stored as a **template** — `capture.sh`
replaces the `{IP}` placeholder with the address from discovery, so a DHCP
change at the target site does not invalidate the probed path.
```
CAMERA_MAC=00:46:b8:28:e2:55      # verified via tcpdump
CAMERA_USER=admin
CAMERA_PASS=                       # VERIFIED EMPTY on this unit (see security note)
ONVIF_MEDIA_XADDR=http://{IP}/onvif/Media     # device GetCapabilities returns this
SNAPSHOT_URL=http://{IP}:80/onvif/Snapshot    # VERIFIED working snapshot path
```
**Verified auth contract (office session 2026-06-10):**
- ONVIF `GetCapabilities` / `GetSystemDateAndTime` → **no auth**.
- ONVIF `GetProfiles` / `GetSnapshotUri` → **require WS-Security UsernameToken
  PasswordDigest**, computed with an EMPTY password (the SHA1 input is
  `nonce_raw + created + ""`). Without it the camera's front HTTP server
  returns an HTML "Access Error: Unauthorized" page (NOT a SOAP Fault).
- The snapshot URL itself → fetched with HTTP **Digest** auth, user `admin`,
  empty password: `curl --digest -u "admin:" "$SNAPSHOT_URL"`.
- Snapshot endpoint confirmed at `http://<IP>:80/onvif/Snapshot` (capital S).
  The ONVIF media service lives at `/onvif/Media` (capital M);
  `/onvif/media_service` is the WRONG path on this firmware and returns
  `MatchingRuleNotSupported`.

**SECURITY NOTE (must address before field deployment):** the admin password
is currently empty. A camera with an open ONVIF stack and proprietary media
port 34567 exposed on an internet-connected network is a standard Mirai-class
target. Set a strong admin password in the panel before the device goes
on-site, then update `CAMERA_PASS` here. The digest computation works
identically with a non-empty password.

MAC matching in `discover-camera.sh` MUST normalize both sides (lowercase,
two-digit octets, colon separators) — BSD/Linux tools render MACs
inconsistently (e.g. stripped leading zeros).

#### `onvif-probe.sh` (runs once, in the office, on the Pi)
Pure bash + curl + openssl. **This flow is VERIFIED working on the target unit**
— a working prototype (`probe.sh`) is in the repo root; productionize it, don't
reinvent the WS-Security computation. The verified sequence:
1. `GetCapabilities` on `/onvif/device_service` (no auth) → read
   `<tt:Media><tt:XAddr>` → media endpoint (was `http://<IP>/onvif/Media`).
2. `GetProfiles` on the media XAddr **with WS-Security PasswordDigest** (empty
   password) → pick the profile with the highest Width (main stream; the first
   token is often a low-res sub/mobile profile and yields wrong aspect ratio).
3. `GetSnapshotUri` with that ProfileToken (fresh nonce/created per request) →
   the `<tt:Uri>` is the snapshot URL. Rewrite host → `{IP}` template, write
   `camera.conf`, then **verify** by fetching one snapshot
   (`curl --digest -u "admin:"`) and checking JPEG magic bytes.
WS-Security digest = `base64(sha1(nonce_raw + created + password))`, with
`created` in UTC ISO8601 (`date -u +%Y-%m-%dT%H:%M:%SZ`). If the camera clock
drifts far from the Pi clock, some firmware reject the token — fetch the camera
time via `GetSystemDateAndTime` (no auth) and compute `created` against it.
If probing fails, print manual-fallback instructions — do not guess paths.

### 5.3 `wifi-update.txt` (created by the Mac script, consumed once by the Pi)
```
SSID=NazwaSieci
PASS=TajneHaslo
PRIORITY=10
```
After successful application the Pi renames it to `wifi-update.applied` and
scrubs the PASS line. On failure it renames to `wifi-update.failed` with an
error note so the user sees the outcome on the Mac.

### 5.4 `status.log` (written by the Pi, read by the user on the Mac)
Append-only, newest entries at the top is NOT required — keep it simple,
append + rotate at 200 lines. One line per event:
```
2026-06-10 14:00:12 | BOOT OK | wifi=BiuroNet ip=192.168.8.23 | camera=FOUND 192.168.8.40 | test_photo=OK
2026-06-10 15:00:01 | HEALTH OK | disk_free=21G | last_photo=14:30 OK
```
Healthcheck also copies the most recent successful photo to
`/boot/firmware/picam/last_photo.jpg` (overwrite) so the user can visually
verify the camera from the Mac.

## 6. Components — behavior

### 6.1 `wifi-applier.service` (oneshot, early boot)
1. If `wifi-update.txt` exists: parse, validate (non-empty SSID, PASS ≥ 8 chars).
2. `nmcli connection add/modify` a profile named after the SSID, set
   `connection.autoconnect-priority` from PRIORITY. Multiple saved profiles must
   coexist (office WiFi + target WiFi) — never delete other profiles.
3. Attempt activation with timeout 60 s; log result to `status.log`; rename the
   file per §5.3.

### 6.2 `discover-camera.sh`
1. If cached IP in `/var/lib/picam/camera_ip` responds (TCP connect to port 80
   or 554 within 2 s) → use it. **Never use ICMP ping anywhere in this project
   to test the camera — it is confirmed to ignore ping.**
2. Else scan the local /24 (derive from the Pi's own IP) with `arp-scan
   --localnet` (preferred; add to install deps) and match `CAMERA_MAC`
   case-insensitively. Update cache on hit.
3. Exit non-zero with a distinct code if camera not found (3) vs no network (2)
   — healthcheck maps codes to messages.

### 6.3 `capture-gate.sh` + `capture.sh`
- Gate runs every minute via timer. Reads `capture.conf`; in `times` mode fires
  when current HH:MM matches an entry (guard against double-fire with a
  `/run/picam/last_shot` stamp); in `interval` mode fires when inside the window
  and `now - last_shot >= INTERVAL_MIN`.
- `capture.sh`: discovery → substitute `{IP}` in `SNAPSHOT_URL` → `curl
  --digest --user "$CAMERA_USER:$CAMERA_PASS"` (verified: digest auth, empty
  password → `-u "admin:"`) with timeout 15 s → validate output is a JPEG
  (magic bytes `FFD8`, size > 10 KB) → save as
  `JPEG_DIR/YYYY-MM-DD/HHMMSS.jpg`. On failure: one retry after forced
  rediscovery (handles a DHCP-changed camera IP); no other fallback — persistent
  failure is the healthcheck's job to report. Enforce `RETENTION_DAYS` cleanup
  after each successful shot. Note: the snapshot fetch needs only HTTP Digest;
  it does NOT require the full ONVIF/WS-Security dance — that is only for
  discovering the URL at install time.
- Failures increment a counter in `/var/lib/picam/fail_count`; reset on success.

### 6.4 `healthcheck.sh` (boot + hourly)
Checks, in order, writing one summary line to `status.log`:
1. WiFi associated + default gateway pingable.
2. Camera discoverable + test snapshot OK (boot run only; hourly run just
   verifies last photo age is within expected schedule slack).
3. Disk free > 500 MB (else prune oldest photo days and note it).
4. Escalation ladder on consecutive failures: 3× network fail → restart
   NetworkManager; 6× → reboot (max one self-reboot per 6 h, tracked in
   `/var/lib/picam/`); persistent camera fail → email alert stub call.

### 6.5 Watchdog & resilience
- Enable hardware watchdog: `dtparam=watchdog=on` in `config.txt`; systemd
  drop-in `RuntimeWatchdogSec=15`.
- All services `Restart=on-failure`, timers `Persistent=true`.
- Minimize SD writes: logs to journald with `SystemMaxUse=50M`; consider
  `Storage=volatile` acceptable for MVP since `status.log` carries the
  operator-relevant history.

### 6.6 `mac/picam-config.sh` (user-facing)
1. Detect the mounted boot volume (search `/Volumes/*` for `picam/` marker or
   `config.txt`); abort with a friendly Polish message if not found.
2. Menu (Polish): [1] Skonfiguruj/zmień WiFi [2] Zmień harmonogram zdjęć
   [3] Pokaż ostatni status [4] Pokaż ostatnie zdjęcie (`open last_photo.jpg`).
3. WiFi flow: ask for SSID (offer current one from the most recent
   `wifi-update.applied` if present), ask for password twice (hidden input),
   write `wifi-update.txt`, read it back and display parsed values for
   confirmation, then `diskutil eject` the card.
4. Must be bash-3.2 compatible, no dependencies beyond macOS built-ins.

### 6.7 `install.sh` (office, one-time, run on the Pi)
- Installs packages (`arp-scan`, `curl`), copies scripts to
  `/usr/local/bin`, installs/enables units, creates `/boot/firmware/picam/` with
  template configs, enables watchdog, optional `--with-tailscale` flag (install
  + print the auth URL, do not block).
- Idempotent: safe to re-run.
- Does **not** change the hostname — leave it as the operator set it (default `pi`).
  Adds `127.0.1.1 <hostname>` to `/etc/hosts` if missing (suppresses sudo warning).
- All installed services run as root (no `User=` in unit files). `arp-scan` requires
  a raw socket; manual runs of Pi scripts need `sudo`.

## 7. Acceptance criteria

1. Fresh SD card + `install.sh` + office WiFi profile → after `reboot`, a BOOT
   OK line appears in `status.log` and a test photo lands in `last_photo.jpg`,
   with no interactive steps.
2. Pull power mid-operation, restore → device returns to capturing within
   5 minutes, new BOOT line logged.
3. Change router DHCP lease so the camera gets a new IP → next capture succeeds
   via rediscovery (allowed: one missed shot).
4. Put a `wifi-update.txt` with a new valid network on the card from a Mac →
   after boot the Pi joins it, file renamed to `.applied`, password scrubbed.
5. Put a `wifi-update.txt` with a wrong password → file renamed `.failed` with
   readable reason; previously working profiles untouched.
6. `capture.conf` edited on the Mac (e.g. interval 30→10 min) → takes effect
   without reinstall or unit reload.
7. `shellcheck` passes on every script; `mac/picam-config.sh` runs on macOS
   default bash 3.2.

## 8. Testing notes for the agent

- Develop/test Pi scripts in a Linux container or directly over SSH to the Pi;
  systemd units can be validated with `systemd-analyze verify`.
- Camera interactions must be behind a single function so they can be mocked
  (e.g. `CAPTURE_CMD` override env var) for tests without hardware.
- Provide a `make test` or `tests/run.sh` exercising: config parsing (incl. CRLF
  files), gate logic across time edge cases (window boundaries, midnight),
  discovery cache behavior, wifi-update file lifecycle.

## 9. Office setup checklist (manual steps, document in README)

1. ~~Connect camera to office LAN, change the default admin password, note the
   MAC~~ → **DONE** (MAC `00:46:b8:28:e2:55`; camera was found on a stale
   static IP `192.168.0.12` and switched to DHCP).
2. Disable the KENIKP2P cloud feature — panel tab **"Chmura"** (next to
   TCP/IP/DDNS/NAT) — unless explicitly wanted.
3. Verify the snapshot URL: try ONVIF `GetSnapshotUri` first; candidate manual
   paths for this firmware family if probing is deferred:
   `/webcapture.jpg?command=snap&channel=1`, `/snapshot?channel=1`,
   `/onvif/snapshot` (validate with `file` → must be JPEG).
4. Run `install.sh` on the Pi, then `onvif-probe.sh <camera-ip>` — it writes
   and verifies `camera.conf`.
5. Add target-site WiFi via `wifi-update.txt` (or the Mac script) alongside the
   office profile; reboot; confirm BOOT OK + `last_photo.jpg`.
6. **On-site deployment procedure (day one):** plug in camera and Pi, wait
   5 minutes, then verify `status.log` shows `camera=FOUND` and a fresh
   `last_photo.jpg` BEFORE leaving the site. If the camera is not found despite
   being powered, suspect L2 segmentation (WiFi client isolation, guest
   network, VLANs) — resolve with the site admin on the spot; discovery cannot
   cross L2 boundaries by design.

## 10. Open questions (resolve before implementing the affected module)

1. ~~Snapshot URL~~ → **RESOLVED & VERIFIED**: `http://<IP>:80/onvif/Snapshot`,
   fetched with HTTP Digest, user `admin`, empty password. ONVIF probe flow
   verified end to end (see `probe.sh`).
2. Schedule mode actually desired by the operator (config supports both;
   defaults to interval).
3. Router access at the target site (would allow DHCP reservation — nice to
   have, not required thanks to MAC discovery).
4. Tailscale: yes/no (install flag exists either way).
5. Email provider choice → Phase 2 `alert.sh` implementation (Gmail SMTP app-password or HTTP API such as Resend/Mailgun; credentials in `/boot/firmware/picam/alert.conf`).

## Decisions (locked)

- **Timezone:** store all timestamps and filenames/R2 keys in **UTC**; convert
  to local time only at the website display layer. Avoids DST gaps/duplicates
  in the timelapse.
- **Repo:** standalone (`picam`), separate from the website repo. The only
  contract between them is the R2 object key schema
  (`photos/YYYY/MM/DD/HHMMSS.jpg`, UTC) — documented in both repos' READMEs.
- **Camera identity:** MAC `00:46:b8:28:e2:55`; DHCP enabled; web panel HTTPS
  with self-signed cert; camera ignores ICMP (TCP-only liveness checks).

## 11. Phase 2 (do not implement now)

- R2 upload with local queue + retry; healthcheck extends to "R2 reachable".
- Email alerts via `curl` (SMTP with app-password or HTTP API), rate-limited to ≤ 3 emails/day. Credentials in `/boot/firmware/picam/alert.conf` on the FAT32 partition. Provider TBD (Gmail SMTP or Resend/Mailgun).
- Optional overlayfs read-only root with a dedicated writable data partition.
- **Contingency (only if no HTTP snapshot exists on this firmware):** a
  single-frame grab from the **mobile RTSP stream**
  (`rtsp://{IP}:554/stream?mode=real&idc=1&ids=3`, low-res H.264) via ffmpeg —
  the ONLY stream light enough for a Zero W to decode one frame from. Do not
  implement unless the snapshot path is confirmed absent.
- Secondary discovery via ONVIF WS-Discovery multicast (UDP :3702) alongside
  ARP — sometimes survives network policies that block unicast scans.
- **Contingency for hostile networks (client isolation / VLANs):** connect the
  camera directly to the Pi via a USB-OTG→ethernet adapter, forming a private
  two-node L2 segment (camera on a static IP, Pi with a second address on that
  link, internet still via WiFi). Removes the site router from the camera path
  entirely; changes the camera back to static IP, so document as a distinct
  setup mode.

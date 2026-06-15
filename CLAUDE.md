# CLAUDE.md — PiCam build instructions for the agent

Read `SPEC.md` in full before writing anything. This file is the rules of
engagement; SPEC.md is the what-and-why. Where they appear to conflict, ask —
do not guess.

## Mission

Build, from scratch, an autonomous timelapse capture station: a Raspberry Pi
Zero W pulls JPEG snapshots from a Kenik KG-4230TAS-IL IP camera on a schedule,
stores them locally, self-diagnoses, and survives power cycles unattended after
a one-time office setup. MVP = local storage only. R2 upload and SMS alerting
are Phase 2 — design for them, do not build them yet.

## Hard constraints (non-negotiable)

- **Pi runtime: bash + systemd only.** No Python, no Node, no ffmpeg. Allowed
  binaries: coreutils, `curl`, `nmcli`, `arp-scan`, `openssl`. Config files are
  plain `KEY=value`, CRLF-tolerant.
- **macOS user script: bash 3.2 compatible.** No associative arrays, no
  `mapfile`, no GNU-only flags. It must run on a stock MacBook with zero
  installs.
- **Every Pi script:** `set -euo pipefail`, must pass `shellcheck` cleanly, log
  to stdout (journald) AND append a one-line summary to the status file.
- **NEVER use ICMP ping to test the camera.** It is confirmed to ignore ping.
  All camera liveness checks are TCP connect tests (port 80/554). This is the
  single most important runtime rule — a ping-based healthcheck will report
  false failures forever.
- **Snapshot-only.** The Pi downloads camera-encoded JPEGs; it never decodes
  video. Do not add RTSP/ffmpeg fallback (see SPEC §11 for the one narrow
  contingency, which is explicitly out of scope unless instructed).
- **Bookworm uses NetworkManager (`nmcli`).** Do not use legacy
  `wpa_supplicant.conf` boot-partition tricks — they do not work.

## Verified ground truth (do not re-derive)

These were confirmed against the real hardware. Treat as fact:

- Camera MAC: `00:46:b8:28:e2:55`. DHCP enabled. Office IP at verification time:
  `192.168.251.113` (do NOT hardcode — discover by MAC at runtime).
- ONVIF media service endpoint path: `/onvif/Media` (capital M).
  `/onvif/media_service` is WRONG on this firmware.
- Auth contract:
  - `GetCapabilities` / `GetSystemDateAndTime`: no auth.
  - `GetProfiles` / `GetSnapshotUri`: WS-Security UsernameToken PasswordDigest,
    `base64(sha1(nonce_raw + created + password))`, `created` in UTC ISO8601.
  - Snapshot fetch: HTTP Digest, user `admin`, **currently empty password**.
- Verified working snapshot URL: `http://<IP>:80/onvif/Snapshot`.
- Camera web panel: HTTPS with self-signed cert (use `curl -k`); live view
  needs a Windows plugin, so treat the panel as config-only.
- `probe.sh` in the repo root is a VERIFIED working prototype of the ONVIF
  discovery flow. Productionize it into `pi/bin/onvif-probe.sh` — keep the
  WS-Security math, add: profile selection by highest resolution, clock-skew
  handling via `GetSystemDateAndTime`, `camera.conf` writing, tests. Do not
  rewrite the digest computation from scratch.

## Suggested build order

Implement in this sequence; each step should be independently testable.

1. Repo skeleton + `install.sh` (idempotent) + systemd unit scaffolding +
   `etc/defaults.conf`.
2. `wifi-applier.sh` + unit (consume `wifi-update.txt`, `nmcli`, multi-profile,
   scrub password, rename file by outcome).
3. `discover-camera.sh` (derive subnet from Pi's own IP, `arp-scan`, normalize
   MACs, IP cache, distinct exit codes for no-network vs camera-not-found).
4. `onvif-probe.sh` (productionized `probe.sh`).
5. `capture.sh` + `capture-gate.sh` + timer (config-driven schedule, JPEG
   validation, retention, retry-after-rediscovery).
6. `healthcheck.sh` + timer (boot + hourly, escalation ladder, status.log,
   last_photo.jpg copy to boot partition).
7. `mac/picam-config.sh` (the user-facing SD-card menu).
8. `README.md` operator manual in Polish, including the office checklist and
   on-site day-one verification step.

## Testing expectations

- `tests/run.sh` covering: config parsing incl. CRLF files, gate logic across
  time edges (window boundaries, midnight, DST), discovery cache lifecycle,
  wifi-update file lifecycle, MAC normalization.
- Camera interactions behind a single mockable function (env override) so tests
  run without hardware.
- `systemd-analyze verify` on every unit.

## Conventions

- All timestamps and filenames/R2 keys in **UTC**. Photo path:
  `JPEG_DIR/YYYY-MM-DD/HHMMSS.jpg`; future R2 key: `photos/YYYY/MM/DD/HHMMSS.jpg`.
- User-facing files (config, status, last_photo.jpg) live on the FAT32 boot
  partition `/boot/firmware/picam/` so the operator can read/write them from a
  Mac with no tools. The ext4 rootfs is not macOS-readable — nothing the
  operator needs goes there.
- Polish for operator-facing text (README, the Mac script's prompts); English
  for code, comments, and commit messages.

## When in doubt

Ask before: adding a dependency, adding any video/RTSP handling, hardcoding the
camera IP, using ping anywhere, or deviating from the snapshot-only design.
Past assistance in chat is context, not license to skip these rules.

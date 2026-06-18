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
echo "[install] Installing watchdog drop-in..."
install -m 644 "$REPO_DIR/pi/systemd/picam-watchdog.conf" "$SYSD_CONF_DIR/"

# ---- hardware watchdog ------------------------------------------------------
echo "[install] Enabling hardware watchdog in config.txt..."
if ! grep -q 'dtparam=watchdog=on' /boot/firmware/config.txt 2>/dev/null; then
  echo 'dtparam=watchdog=on' >> /boot/firmware/config.txt
fi

# ---- /etc/hosts — suppress "sudo: unable to resolve host" warning -----------
# Does not change the hostname; leave it as the operator set it.
# Remove stale entry added by previous versions that incorrectly ran
# hostnamectl set-hostname picam.
sed -i '/^127\.0\.1\.1[[:space:]]\+picam$/d' /etc/hosts 2>/dev/null || true
CURRENT_HOST=$(hostname)
if ! grep -qE "^127\.0\.1\.1[[:space:]]+$CURRENT_HOST([[:space:]]|$)" /etc/hosts 2>/dev/null; then
  echo "127.0.1.1 $CURRENT_HOST" >> /etc/hosts
  echo "[install] Added 127.0.1.1 $CURRENT_HOST to /etc/hosts"
fi

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

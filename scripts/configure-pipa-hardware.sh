#!/usr/bin/env bash
# Enable pipa hardware services on the openSUSE rootfs.
# Called from ci-build-image.sh with ROOTFS_DIR set.
set -euo pipefail

ROOTFS_DIR="${ROOTFS_DIR:?}"

echo "=== Pipa hardware configuration ==="

enable_svc() {
  local svc="$1"
  if [ -f "$ROOTFS_DIR/usr/lib/systemd/system/$svc" ]; then
    mkdir -p "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
    ln -sfn "/usr/lib/systemd/system/$svc" \
      "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/$svc"
  else
    echo "  (skip: $svc not present — check pipa-pkgs injection)"
  fi
}

# Qualcomm / pipa bring-up order — same dependency chain as the Fedora and
# Nemo builds, this is hardware-level, not distro-level.
for svc in \
  pd-mapper.service \
  tqftpserv.service \
  rmtfs.service \
  qrtr-ns.service \
  pipa-sensors-persist.service \
  bootmac-bluetooth.service \
  swclock-offset-boot.service \
  hexagonrpcd-sdsp.service \
  hexagonrpcd-adsp-rootpd.service \
  pipa-audio-init.service \
  cameras_setup.service \
  bluetooth.service \
  iio-sensor-proxy.service \
  systemd-timesyncd.service
do
  enable_svc "$svc"
done

# --- Lesson from the Fedora build: gdm can get pulled in transitively by a
# desktop pattern and race sddm for display-manager.service. Mask it
# defensively; harmless no-op if it was never installed. ---
systemctl --root "$ROOTFS_DIR" mask gdm.service 2>/dev/null || true

# --- Lesson from the Fedora build: don't assume a weak dep pulled in the
# session bus. Verify, don't guess. ---
if ! rpm --root "$ROOTFS_DIR" -q dbus-1-daemon >/dev/null 2>&1; then
  echo "WARNING: dbus-1-daemon missing — Plasma will not start without it."
  echo "         Re-run: zypper --root \"$ROOTFS_DIR\" install -y dbus-1-daemon dbus-1-x11"
fi

# rtc0 on pipa returns I/O errors; prefer rtc1 (same fix as the Nemo build)
install -Dm644 /dev/stdin "$ROOTFS_DIR/etc/udev/rules.d/55-pipa-rtc.rules" <<'EOF'
SUBSYSTEM=="rtc", KERNEL=="rtc0", OPTIONS+="ignore_device"
EOF

echo "Pipa hardware units enabled"

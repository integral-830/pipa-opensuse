#!/usr/bin/env bash
# Extract pipa-pkgs (Arch pacman .pkg.tar.xz/.zst) directly onto an openSUSE
# rootfs. pacman packages are plain tarballs with no package-manager
# database requirement to unpack — so `tar -x` + stripping the Arch
# metadata files works on any distro's rootfs. This is the same technique
# manjaro-nemo-pipa uses to put pipa-pkgs onto an openSUSE Tumbleweed rootfs.
#
# Usage: ROOTFS_DIR=/path/to/rootfs ./inject-pipa-pkgs.sh
set -euo pipefail

ROOTFS_DIR="${ROOTFS_DIR:?}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIPA_REPO_URL="${PIPA_REPO_URL:-https://thespider2.github.io/pipa-pkgs/repo/}"
PKG_CACHE="${PKG_CACHE:-$REPO_ROOT/images/.cache/pipa-pkgs}"
mkdir -p "$PKG_CACHE"

# Everything under [pipa-pkgs] in profiles/devices/pipa
PIPA_PKGS=(
  linux-pipa pipa-dracut pipa-grub-config pipa-kernel-flasher-hook
  pipa-metapkg qbootctl
  xiaomi-pipa-firmware linux-firmware wireless-regdb
  qrtr rmtfs tqftpserv pd-mapper hexagonrpc libssc bootmac swclock-offset
  ath10k-shutdown make-dynpart-mappings msm-modem-uim-selection q6voiced
  qca-swiss-army-knife usb-network
  alsa-ucm-conf-sm8250 pipa-sound-conf pulseaudio pulseaudio-utils pulseaudio-bluetooth
  pipa-sensors iio-sensor-proxy libcamera libcamera-ipa libcamera-tools
  bluez bluez-git
  mesa
  wpa_supplicant iwd connman-client
)

echo "==> Fetching pipa-pkgs repo index"
INDEX=$(curl -fsSL "$PIPA_REPO_URL")

inject_one() {
  local name="$1" file dest
  file=$(printf '%s\n' "$INDEX" \
    | grep -oE "href=\"${name}-[^\"]+\.pkg\.tar\.(xz|zst)\"" \
    | sed 's/href="//;s/"$//' | sort -V | tail -n1 || true)
  if [ -z "$file" ]; then
    echo "WARNING: package not found in pipa-pkgs: $name"
    return 0
  fi
  dest="$PKG_CACHE/$file"
  if [ ! -f "$dest" ]; then
    echo "  downloading $file"
    curl -fL --retry 3 -o "$dest" "${PIPA_REPO_URL%/}/$file"
  fi
  echo "  extracting $file"
  tar -C "$ROOTFS_DIR" -xf "$dest" \
    --exclude='.PKGINFO' --exclude='.MTREE' --exclude='.BUILDINFO' --exclude='.INSTALL' \
    2>/dev/null || tar -C "$ROOTFS_DIR" -xf "$dest"
}

for pkg in "${PIPA_PKGS[@]}"; do
  inject_one "$pkg"
done

# Clean up any Arch package metadata that landed at rootfs top level
rm -f "$ROOTFS_DIR"/.PKGINFO "$ROOTFS_DIR"/.MTREE "$ROOTFS_DIR"/.BUILDINFO "$ROOTFS_DIR"/.INSTALL 2>/dev/null || true

# pipa-pkgs (Arch) installs shared libs under /usr/lib; openSUSE's ldconfig
# on aarch64 only scans /usr/lib64 by default. Without this, libssc,
# hexagonrpc, and friends link but can't find their .so at runtime.
install -Dm644 /dev/stdin "$ROOTFS_DIR/etc/ld.so.conf.d/pipa-arch-libs.conf" <<'EOF'
/usr/lib
EOF

echo "==> pipa-pkgs injection done"

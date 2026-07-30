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
# NOTE: generic userspace/firmware packages (pulseaudio, mesa, wpa_supplicant,
# iwd, connman, linux-firmware, wireless-regdb) are deliberately NOT listed
# here — they were never published in this Arch-style device repo (every
# build logged "WARNING: package not found in pipa-pkgs" for them) and are
# installed from the real openSUSE Tumbleweed repos in ci-build-image.sh
# instead. Only put a package here if it's pipa/Qualcomm-hardware-specific
# or a patched fork (bluez-git, libcamera-ipa, etc. carry pipa-specific
# patches openSUSE's stock builds don't have).
PIPA_PKGS=(
  linux-pipa pipa-dracut pipa-grub-config pipa-kernel-flasher-hook
  pipa-metapkg qbootctl
  xiaomi-pipa-firmware
  qrtr rmtfs tqftpserv pd-mapper hexagonrpc libssc bootmac swclock-offset
  ath10k-shutdown make-dynpart-mappings msm-modem-uim-selection q6voiced
  qca-swiss-army-knife usb-network
  alsa-ucm-conf-sm8250 pipa-sound-conf
  pipa-sensors iio-sensor-proxy libcamera libcamera-ipa libcamera-tools
  bluez-git
)

echo "==> Fetching pipa-pkgs repo index"
INDEX=$(curl -fsSL "$PIPA_REPO_URL")

inject_one() {
  local name="$1" file dest tar_err
  # The char right after "name-" must start a version (digit, or an epoch
  # like "1:"), never just "[^\"]+" — otherwise requesting "libcamera"
  # also matches "libcamera-docs-...", "libcamera-ipa-...",
  # "libcamera-tools-..." (all real, separate packages in this repo), and
  # requesting "bluez" matches "bluez-git-...". sort -V | tail -n1 then
  # silently picks whichever of those wrong candidates sorts last, so the
  # wrong archive can get extracted under the right package's name.
  file=$(printf '%s\n' "$INDEX" \
    | grep -oE "href=\"${name}-[0-9][^\"]*\.pkg\.tar\.(xz|zst)\"" \
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
  # Single extraction attempt with errors surfaced. The previous
  # "try with --exclude, silently swallow any error, then blindly retry
  # without --exclude" pattern could mask a real tar failure (disk space,
  # a truncated/corrupt download, an unsupported entry) behind a retry
  # that looked identical in the log either way.
  if ! tar_err=$(tar -C "$ROOTFS_DIR" -xf "$dest" \
        --exclude='.PKGINFO' --exclude='.MTREE' --exclude='.BUILDINFO' --exclude='.INSTALL' \
        2>&1); then
    echo "ERROR: extraction failed for $file" >&2
    printf '%s\n' "$tar_err" >&2
    return 1
  fi
}

for pkg in "${PIPA_PKGS[@]}"; do
  inject_one "$pkg"
done

# Clean up any Arch package metadata that landed at rootfs top level
rm -f "$ROOTFS_DIR"/.PKGINFO "$ROOTFS_DIR"/.MTREE "$ROOTFS_DIR"/.BUILDINFO "$ROOTFS_DIR"/.INSTALL 2>/dev/null || true

# --- Verify linux-pipa actually landed, right here, right after extracting
# it -- not 20 packages and 2 scripts later in post-process-pipa.sh, where a
# failure here just reads as a confusing "no kernel modules" at the very end
# of the build.
echo "==> Verifying linux-pipa kernel modules"
KVER=""
for d in "$ROOTFS_DIR"/usr/lib/modules/*/; do
  d="${d%/}"; d="${d##*/}"
  case "$d" in *pipa*|*PIPA*) KVER="$d"; break ;; esac
done
if [ -z "$KVER" ]; then
  echo "ERROR: linux-pipa was extracted but no /usr/lib/modules/*pipa* directory exists." >&2
  echo "       Contents of $ROOTFS_DIR/usr/lib/modules:" >&2
  ls -la "$ROOTFS_DIR/usr/lib/modules" 2>&1 >&2 || echo "       (directory does not exist)" >&2
  exit 1
fi
echo "  found kernel: $KVER"

# The raw-tarball technique bypasses pacman/ALPM install hooks entirely, and
# depmod is normally run by one of those hooks (not shipped as plain files
# in the package payload). Without it, modules.dep/modules.alias/
# modules.symbols never get (re)generated for this kernel, so systemd/udev
# can't resolve module aliases and dracut can't reliably tell what to pull
# into the initramfs. Regenerate it now that the module tree is in place.
if [ -x "$ROOTFS_DIR/usr/sbin/depmod" ] || [ -x "$ROOTFS_DIR/sbin/depmod" ]; then
  chroot "$ROOTFS_DIR" depmod -a "$KVER" \
    || echo "WARNING: depmod -a $KVER failed inside the chroot (check binfmt/qemu-aarch64 setup)" >&2
else
  echo "WARNING: no depmod binary in the rootfs yet (module-init-tools/kmod not installed?) — skipping depmod" >&2
fi

# pipa-pkgs (Arch) installs shared libs under /usr/lib; openSUSE's ldconfig
# on aarch64 only scans /usr/lib64 by default. Without this, libssc,
# hexagonrpc, and friends link but can't find their .so at runtime.
install -Dm644 /dev/stdin "$ROOTFS_DIR/etc/ld.so.conf.d/pipa-arch-libs.conf" <<'EOF'
/usr/lib
EOF

echo "==> pipa-pkgs injection done"

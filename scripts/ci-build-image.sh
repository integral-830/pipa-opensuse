#!/usr/bin/env bash
# Bootstrap a real openSUSE Tumbleweed aarch64 rootfs with zypper
# --installroot, install Plasma from the actual repos, inject pipa-pkgs,
# emit the pipa flash layout (esp/boot/rootfs + Mu-Silicium).
#
# Unlike the Nemo image (which downloads a pre-built OBS rootfs tarball),
# this builds the base rootfs itself — there is no pre-baked "openSUSE
# Plasma for pipa" tarball anywhere, so bootstrap is step one.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/images}"
IMAGE_MODE="${IMAGE_MODE:-full}" # full | bringup (bringup = console only, no Plasma)

TW_ARCH="aarch64"
TW_REPO_OSS="https://download.opensuse.org/ports/${TW_ARCH}/tumbleweed/repo/oss/"
TW_REPO_NONOSS="https://download.opensuse.org/ports/${TW_ARCH}/tumbleweed/repo/non-oss/"
TW_REPO_UPDATE="https://download.opensuse.org/ports/${TW_ARCH}/update/tumbleweed/"

mkdir -p "$OUT_DIR"
chmod +x "$ROOT/scripts"/*.sh

if [ "$(id -u)" -ne 0 ]; then
    echo "==> Must run as root (zypper --installroot + loop mounts). Re-exec with sudo."
    exec sudo -E OUT_DIR="$OUT_DIR" IMAGE_MODE="$IMAGE_MODE" "$0" "$@"
fi

echo "==> Host: $(uname -a)"
"$ROOT/scripts/validate-recipe.sh"

ROOTFS_DIR="$OUT_DIR/rootfs-build"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

# zypper --root relocates the repo/cache/solv directories under $ROOTFS_DIR,
# but it does NOT read zypp.conf from inside the target root -- libzypp still
# autodetects the *build host's* CPU architecture (uname -m) for the solver.
# On the amd64 CI container that's x86_64, so every package in the aarch64
# ports repo gets filtered out as "incompatible", which is exactly the
# "No provider of 'coreutils' found" (and glibc/systemd/bash/...) failure:
# the solver isn't missing the packages, it's refusing all of them on arch
# grounds. ZYPP_CONF points libzypp at a conf file that overrides the
# detected system architecture to the actual target, aarch64. This has been
# verified against real zypper/libzypp: without it, zypper logs
# "SystemArchitecture: 'x86_64_v4'" even with --root pointed at an aarch64
# tree; with it, it logs "Overriding system architecture ... aarch64".
echo "==> Forcing libzypp target architecture to ${TW_ARCH} (build host is $(uname -m))"
ZYPP_CONF_OVERRIDE="$OUT_DIR/zypp-${TW_ARCH}.conf"
cat >"$ZYPP_CONF_OVERRIDE" <<EOF
[main]
arch = ${TW_ARCH}
EOF
export ZYPP_CONF="$ZYPP_CONF_OVERRIDE"

echo "==> Registering Tumbleweed repos into the target root"
zypper --root "$ROOTFS_DIR" ar -f "$TW_REPO_OSS" repo-oss
zypper --root "$ROOTFS_DIR" ar -f "$TW_REPO_NONOSS" repo-non-oss
zypper --root "$ROOTFS_DIR" ar -f "$TW_REPO_UPDATE" repo-update
zypper --root "$ROOTFS_DIR" --gpg-auto-import-keys refresh

echo "==> Bootstrapping base system (filesystem, systemd, zypper itself)"
zypper --root "$ROOTFS_DIR" --non-interactive install -y \
    --no-recommends \
    filesystem glibc systemd zypper rpm bash coreutils util-linux \
    NetworkManager dbus-1 dbus-1-daemon iputils openssh sudo shadow \
    grub2-arm64-efi shim dracut

if [[ "$IMAGE_MODE" == "full" ]]; then
    echo "==> Installing Plasma desktop (patterns-kde-plasma) from real Tumbleweed repos"
    # This is the whole point of doing openSUSE this way: no manual RPM
    # extraction for the desktop, zypper resolves everything normally.
    zypper --root "$ROOTFS_DIR" --non-interactive install -y \
        patterns-kde-plasma sddm plymouth
else
    echo "==> IMAGE_MODE=bringup — skipping Plasma, console-only rootfs for hardware bring-up"
fi

echo "==> Extra libs pipa-pkgs binaries need (installed from real Tumbleweed repos)"
zypper --root "$ROOTFS_DIR" --non-interactive install -y \
    --no-recommends \
    libqmi-glib5 libqrtr-glib0 libprotobuf-c1 libmbim-glib4

echo "==> Injecting pipa-pkgs (kernel + hardware) into the rootfs"
ROOTFS_DIR="$ROOTFS_DIR" "$ROOT/scripts/inject-pipa-pkgs.sh"

echo "==> Configuring Plasma session + pipa hardware glue"
if [[ "$IMAGE_MODE" == "full" ]]; then
    ROOTFS_DIR="$ROOTFS_DIR" "$ROOT/scripts/configure-plasma-session.sh"
fi
ROOTFS_DIR="$ROOTFS_DIR" "$ROOT/scripts/configure-pipa-hardware.sh"

echo "==> Handing off to post-process-pipa.sh (boot/esp/rootfs raw images)"
"$ROOT/scripts/post-process-pipa.sh" "$ROOTFS_DIR" "$OUT_DIR/flashable"

if [[ -d "$OUT_DIR/flashable" ]]; then
    cp -a "$OUT_DIR/flashable"/. "$OUT_DIR"/
fi

ls -lah "$OUT_DIR"
echo "==> Done"

#!/usr/bin/env bash
# Turn a finished openSUSE + pipa rootfs directory into the pipa flash
# layout (esp/boot/rootfs raw images + Mu-Silicium + flash scripts).
# This stage is almost entirely distro-agnostic — it's the same boot-chain
# logic as the Ultramarine/Fedora and Nemomobile/openSUSE pipa builds.
#
# Usage (as root): post-process-pipa.sh <rootfs-dir> [output-dir]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATE=$(date +%Y%m%d)
ROOTFS_DIR_IN="${1:?usage: $0 <rootfs-dir> [output-dir]}"
OUTPUT_DIR="${2:-$REPO_ROOT/images/plasma-pipa-${DATE}}"

ROOTFS_LABEL="plasma-pipa"
BOOT_LABEL="boot"
ESP_LABEL="PLASMAPIPA"

SILICIUM_URL="${SILICIUM_URL:-https://github.com/onesaladleaf/Mu-Silicium/releases/download/v3.5-pocketblue/Mu-pipa.img}"
VBMETA_DISABLED="$REPO_ROOT/assets/vbmeta-disabled.img"
EFI_TEMPLATE="$REPO_ROOT/efi-template"

if [ "$(id -u)" -ne 0 ]; then
    echo "Must run as root (loop mounts)" >&2
    exit 1
fi

ROOTFS_DIR="$ROOTFS_DIR_IN"
mkdir -p "$OUTPUT_DIR"
WORK=$(mktemp -d)
BOOT_MNT="$WORK/boot"
ESP_MNT="$WORK/esp"
mkdir -p "$BOOT_MNT" "$ESP_MNT"

cleanup() {
    umount "$BOOT_MNT" 2>/dev/null || true
    umount "$ESP_MNT" 2>/dev/null || true
    umount "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount "$ROOTFS_DIR/sys" 2>/dev/null || true
    umount "$ROOTFS_DIR/dev" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# --- Find the pipa kernel, drop any stock kernel that came along ---
MODULES_DIR="$ROOTFS_DIR/usr/lib/modules"
[ -d "$MODULES_DIR" ] || MODULES_DIR="$ROOTFS_DIR/lib/modules"
mapfile -t _mod_dirs < <(find "$MODULES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V || true)
KERNEL_VER=""
for d in "${_mod_dirs[@]}"; do
    case "$d" in *pipa* | *PIPA*)
        KERNEL_VER="$d"
        break
        ;;
    esac
done
if [ -z "$KERNEL_VER" ]; then
    for d in "${_mod_dirs[@]}"; do
        case "$d" in *-default | *-vanilla) continue ;; *)
            KERNEL_VER="$d"
            break
            ;;
        esac
    done
fi
if [ -z "$KERNEL_VER" ]; then
    echo "ERROR: no kernel modules after pipa-pkgs inject" >&2
    echo "       Checked: $MODULES_DIR" >&2
    ls -la "$ROOTFS_DIR/usr/lib/modules" >&2 2>&1 || echo "       $ROOTFS_DIR/usr/lib/modules does not exist" >&2
    ls -la "$ROOTFS_DIR/lib/modules" >&2 2>&1 || echo "       $ROOTFS_DIR/lib/modules does not exist" >&2
    echo "       inject-pipa-pkgs.sh now verifies this right after extraction —" >&2
    echo "       if it got this far, something removed/moved the module tree" >&2
    echo "       between injection and this step (check configure-plasma-session.sh" >&2
    echo "       and configure-pipa-hardware.sh for anything touching /usr/lib)." >&2
    exit 1
fi
# usr/lib/modules/$KERNEL_VER is referenced throughout the rest of this
# script — keep it correct if we fell back to the legacy lib/modules path.
ROOTFS_MODULES_PREFIX="${MODULES_DIR#"$ROOTFS_DIR"/}"
for d in "${_mod_dirs[@]}"; do
    if [ "$d" != "$KERNEL_VER" ]; then
        echo "Removing unused stock kernel modules: $d"
        rm -rf "$ROOTFS_DIR/usr/lib/modules/$d"
    fi
done
echo "Kernel version: $KERNEL_VER"

mkdir -p "$ROOTFS_DIR/boot/dtbs/qcom" "$ROOTFS_DIR/boot/grub" "$ROOTFS_DIR/boot/grub2"

KERNEL_IMAGE=""
for f in \
    "$ROOTFS_DIR/boot/vmlinuz-linux-pipa" \
    "$ROOTFS_DIR/boot/vmlinuz-$KERNEL_VER" \
    "$ROOTFS_DIR/usr/lib/modules/$KERNEL_VER/vmlinuz" \
    "$ROOTFS_DIR/boot/Image.gz" \
    "$ROOTFS_DIR/boot/Image"; do
    [ -f "$f" ] && KERNEL_IMAGE="$f" && break
done
[ -n "$KERNEL_IMAGE" ] || {
    echo "ERROR: kernel image missing" >&2
    ls -la "$ROOTFS_DIR/boot" >&2
    exit 1
}
echo "Kernel image: $KERNEL_IMAGE"

DEST_GZ="$ROOTFS_DIR/boot/Image.gz"
if [[ "$KERNEL_IMAGE" == *.gz ]]; then
    [ "$KERNEL_IMAGE" -ef "$DEST_GZ" ] || cp -f "$KERNEL_IMAGE" "$DEST_GZ"
else
    gzip -c -9 "$KERNEL_IMAGE" >"$DEST_GZ"
fi
if [ ! -f "$ROOTFS_DIR/boot/Image" ]; then
    if [[ "$KERNEL_IMAGE" == *.gz ]]; then
        gunzip -c "$KERNEL_IMAGE" >"$ROOTFS_DIR/boot/Image" || true
    else
        cp -f "$KERNEL_IMAGE" "$ROOTFS_DIR/boot/Image"
    fi
fi

shopt -s nullglob
dtb_files=("$ROOTFS_DIR"/boot/dtbs/qcom/sm8250-xiaomi-pipa*.dtb)
[ ${#dtb_files[@]} -eq 0 ] && dtb_files=("$ROOTFS_DIR"/usr/lib/modules/"$KERNEL_VER"/dtb/qcom/sm8250-xiaomi-pipa*.dtb)
shopt -u nullglob
if [ ${#dtb_files[@]} -eq 0 ]; then
    echo "ERROR: no pipa DTB found" >&2
    find "$ROOTFS_DIR" -name 'sm8250-xiaomi-pipa*.dtb' 2>/dev/null | head >&2 || true
    exit 1
fi
mkdir -p "$ROOTFS_DIR/boot/dtbs/qcom"
for f in "${dtb_files[@]}"; do
    cp -f "$f" "$ROOTFS_DIR/boot/dtbs/qcom/" 2>/dev/null || true
done
echo "DTBs: ${dtb_files[*]}"

TARGET_KERNEL_CMDLINE="root=LABEL=$ROOTFS_LABEL rw rootwait boot=LABEL=$BOOT_LABEL console=tty0 quiet splash clk_ignore_unused pd_ignore_unused"
printf '%s\n' "$TARGET_KERNEL_CMDLINE" >"$ROOTFS_DIR/boot/cmdline.txt"

echo "=== Generating initramfs (dracut) ==="
INITRAMFS_STABLE="initramfs-linux-pipa.img"
mount --bind /proc "$ROOTFS_DIR/proc" 2>/dev/null || true
mount --bind /sys "$ROOTFS_DIR/sys" 2>/dev/null || true
mount --bind /dev "$ROOTFS_DIR/dev" 2>/dev/null || true
if chroot "$ROOTFS_DIR" /usr/bin/dracut --force --kver "$KERNEL_VER" "/boot/initramfs-$KERNEL_VER.img" 2>/dev/null; then
    cp -f "$ROOTFS_DIR/boot/initramfs-$KERNEL_VER.img" "$ROOTFS_DIR/boot/$INITRAMFS_STABLE"
else
    echo "WARNING: dracut failed; looking for existing initramfs"
fi
umount "$ROOTFS_DIR/proc" 2>/dev/null || true
umount "$ROOTFS_DIR/sys" 2>/dev/null || true
umount "$ROOTFS_DIR/dev" 2>/dev/null || true

INITRAMFS=""
for f in "$ROOTFS_DIR/boot/initramfs-$KERNEL_VER.img" "$ROOTFS_DIR/boot/$INITRAMFS_STABLE"; do
    [ -f "$f" ] && INITRAMFS="$f" && break
done
if [ -z "$INITRAMFS" ]; then
    echo "ERROR: dracut produced no initramfs — this image will not boot. Fix dracut/kver before flashing." >&2
    exit 1
fi
[ "$INITRAMFS" -ef "$ROOTFS_DIR/boot/$INITRAMFS_STABLE" ] || cp -f "$INITRAMFS" "$ROOTFS_DIR/boot/$INITRAMFS_STABLE"

cat >"$ROOTFS_DIR/etc/fstab" <<FSTAB
LABEL=$ROOTFS_LABEL / ext4 defaults,x-systemd.growfs 0 1
LABEL=$BOOT_LABEL /boot ext4 defaults 0 2
FSTAB

mkdir -p "$ROOTFS_DIR/boot/grub"
cat >"$ROOTFS_DIR/boot/grub/grub.cfg" <<GRUB
search --no-floppy --label --set=boot $BOOT_LABEL
set prefix=(\$boot)/grub2
configfile (\$boot)/grub2/grub.cfg
GRUB

echo "=== Creating boot.raw ==="
truncate -s 1024M "$OUTPUT_DIR/plasma_boot.raw"
mkfs.ext4 -F -L "$BOOT_LABEL" -O ^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file "$OUTPUT_DIR/plasma_boot.raw"
mount -o loop "$OUTPUT_DIR/plasma_boot.raw" "$BOOT_MNT"

cp -f "$ROOTFS_DIR/boot/Image.gz" "$BOOT_MNT/Image.gz"
[ -f "$ROOTFS_DIR/boot/Image" ] && cp -f "$ROOTFS_DIR/boot/Image" "$BOOT_MNT/Image"
cp -f "$ROOTFS_DIR/boot/$INITRAMFS_STABLE" "$BOOT_MNT/$INITRAMFS_STABLE"
mkdir -p "$BOOT_MNT/dtbs/qcom" "$BOOT_MNT/grub2"
cp -f "$ROOTFS_DIR"/boot/dtbs/qcom/sm8250-xiaomi-pipa*.dtb "$BOOT_MNT/dtbs/qcom/"
printf '%s\n' "$TARGET_KERNEL_CMDLINE" >"$BOOT_MNT/cmdline.txt"

kernel_rel="Image"
[ -f "$BOOT_MNT/Image" ] || kernel_rel="Image.gz"
dtb_rels=()
for dtb in "$BOOT_MNT"/dtbs/qcom/sm8250-xiaomi-pipa*.dtb; do
    dtb_rels+=("dtbs/qcom/$(basename "$dtb")")
done

"$REPO_ROOT/scripts/write-pipa-grub-cfg.sh" \
    "$BOOT_MNT/grub2/grub.cfg" "$BOOT_LABEL" "$TARGET_KERNEL_CMDLINE" \
    "$kernel_rel" "$INITRAMFS_STABLE" "${dtb_rels[@]}"

umount "$BOOT_MNT"

echo "=== Creating esp.raw ==="
# 4096-byte sectors (UFS) — Mu-Silicium/pocketblue needs this or it gets
# stuck in MsTemp without ever loading BOOTAA64.
truncate -s 128M "$OUTPUT_DIR/plasma_esp.raw"
mkfs.fat -F 16 -S 4096 -s 4 -n "$ESP_LABEL" "$OUTPUT_DIR/plasma_esp.raw"
mount -o loop "$OUTPUT_DIR/plasma_esp.raw" "$ESP_MNT"
mkdir -p "$ESP_MNT/EFI/BOOT" "$ESP_MNT/EFI/opensuse"

for src in \
    "$EFI_TEMPLATE/EFI/BOOT/BOOTAA64.EFI" \
    "$EFI_TEMPLATE/EFI/BOOT/FBAA64.EFI" \
    "$EFI_TEMPLATE/EFI/BOOT/grubaa64.efi" \
    "$EFI_TEMPLATE/EFI/BOOT/shimaa64.efi" \
    "$EFI_TEMPLATE/EFI/BOOT/BOOTAA64.CSV"; do
    [ -f "$src" ] && cp -f "$src" "$ESP_MNT/EFI/BOOT/"
done
# Reuse the "nemo" vendor-dir binaries as the opensuse ones — same shim/grub
# chain works for any distro on this boot path.
for f in grubaa64.efi shimaa64.efi mmaa64.efi BOOTAA64.CSV; do
    [ -f "$EFI_TEMPLATE/EFI/nemo/$f" ] && cp -f "$EFI_TEMPLATE/EFI/nemo/$f" "$ESP_MNT/EFI/opensuse/"
done
[ -f "$EFI_TEMPLATE/EFI/nemo/shimaa64.efi" ] &&
    cp -f "$EFI_TEMPLATE/EFI/nemo/shimaa64.efi" "$ESP_MNT/EFI/opensuse/BOOTAA64.EFI"

for shim_vendor in opensuse BOOT; do
    mkdir -p "$ESP_MNT/EFI/$shim_vendor"
    cat >"$ESP_MNT/EFI/$shim_vendor/grub.cfg" <<ESPCFG
search --label $BOOT_LABEL --set prefix --no-floppy
if [ -d (\$prefix)/grub2 ]; then
  set prefix=(\$prefix)/grub2
  configfile \$prefix/grub.cfg
else
  set prefix=(\$prefix)/boot/grub2
  configfile \$prefix/grub.cfg
fi
boot
ESPCFG
done
umount "$ESP_MNT"

echo "=== Creating rootfs.raw ==="
rm -rf "$ROOTFS_DIR/boot"/*
mkdir -p "$ROOTFS_DIR/boot/grub"
cat >"$ROOTFS_DIR/boot/grub/grub.cfg" <<GRUB
search --no-floppy --label --set=boot $BOOT_LABEL
set prefix=(\$boot)/grub2
configfile (\$boot)/grub2/grub.cfg
GRUB

SIZE=$(du -sBM "$ROOTFS_DIR" | awk '{print $1}' | tr -d 'M')
SIZE=$((SIZE + SIZE / 8 + 512))
echo "Rootfs size: ${SIZE}M"
truncate -s "${SIZE}M" "$OUTPUT_DIR/plasma_rootfs.raw"
mkfs.ext4 -L "$ROOTFS_LABEL" "$OUTPUT_DIR/plasma_rootfs.raw"
ROOT_MNT=$(mktemp -d)
mount -o loop "$OUTPUT_DIR/plasma_rootfs.raw" "$ROOT_MNT"
rsync -aHAX --exclude '/tmp/*' "$ROOTFS_DIR"/ "$ROOT_MNT"/
umount "$ROOT_MNT"
rmdir "$ROOT_MNT"

echo "=== Fetching Mu-Silicium ==="
curl -fL --retry 3 -o "$OUTPUT_DIR/silicium.img" "$SILICIUM_URL"
cp -f "$VBMETA_DISABLED" "$OUTPUT_DIR/vbmeta-disabled.img"

echo "=== Writing flash scripts ==="
cat >"$OUTPUT_DIR/flash.sh" <<'FLASH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
echo "### openSUSE Plasma - Xiaomi Pad 6 single-boot flasher"
need() {
  local f="$1"
  if [[ -f "$f" ]]; then echo "$f"
  elif [[ -f "$f.xz" ]]; then echo "==> Decompressing $f.xz" >&2; xz -dkf "$f.xz"; echo "$f"
  else echo "ERROR: missing $f or $f.xz" >&2; exit 1; fi
}
fastboot getvar product 2>&1 | grep pipa
read -r -p "Proceed with flashing? [Y/n]: " CONFIRM
case "${CONFIRM:-Y}" in y|Y|yes|YES|"") ;; *) echo "Aborted."; exit 0 ;; esac
if [[ -f vbmeta-disabled.img || -f vbmeta-disabled.img.xz ]]; then
  fastboot flash vbmeta_ab "$(need vbmeta-disabled.img)" || true
fi
fastboot flash boot_ab "$(need silicium.img)"
fastboot flash rawdump "$(need plasma_esp.raw)"
fastboot flash cust "$(need plasma_boot.raw)"
fastboot flash userdata "$(need plasma_rootfs.raw)"
fastboot reboot
FLASH
chmod +x "$OUTPUT_DIR/flash.sh"

cat >"$OUTPUT_DIR/flash-multiboot.sh" <<'MFLASH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
echo "### openSUSE Plasma - Xiaomi Pad 6 multiboot flasher"
ROOTFS_PART="${1:-linux}"
BOOT_SLOT="${2:-boot_ab}"
need() {
  local f="$1"
  if [[ -f "$f" ]]; then echo "$f"
  elif [[ -f "$f.xz" ]]; then echo "==> Decompressing $f.xz" >&2; xz -dkf "$f.xz"; echo "$f"
  else echo "ERROR: missing $f or $f.xz" >&2; exit 1; fi
}
fastboot getvar product 2>&1 | grep pipa
read -r -p "Proceed? [Y/n]: " CONFIRM
case "${CONFIRM:-Y}" in y|Y|yes|YES|"") ;; *) echo "Aborted."; exit 0 ;; esac
if [[ -f vbmeta-disabled.img || -f vbmeta-disabled.img.xz ]]; then
  fastboot flash vbmeta_ab "$(need vbmeta-disabled.img)" || true
fi
fastboot flash "$BOOT_SLOT" "$(need silicium.img)"
fastboot flash rawdump "$(need plasma_esp.raw)"
fastboot flash cust "$(need plasma_boot.raw)"
fastboot flash "$ROOTFS_PART" "$(need plasma_rootfs.raw)"
fastboot reboot
MFLASH
chmod +x "$OUTPUT_DIR/flash-multiboot.sh"

cat >"$OUTPUT_DIR/BUILDINFO.txt" <<INFO
openSUSE Plasma Pipa Image
===========================
Build date:   $DATE
Kernel:       $KERNEL_VER
Rootfs label: $ROOTFS_LABEL
Boot label:   $BOOT_LABEL
ESP label:    $ESP_LABEL
Silicium URL: $SILICIUM_URL
Flash (decompress .xz first, or use flash.sh):
  silicium.img(.xz)      -> boot_ab
  plasma_esp.raw(.xz)    -> rawdump
  plasma_boot.raw(.xz)   -> cust
  plasma_rootfs.raw(.xz) -> userdata (or linux for multiboot)
INFO

echo "=== Compressing flashables with xz ==="
for f in plasma_esp.raw plasma_boot.raw plasma_rootfs.raw silicium.img vbmeta-disabled.img; do
    [[ -f "$OUTPUT_DIR/$f" ]] && xz -T0 -9 -f "$OUTPUT_DIR/$f"
done

(cd "$OUTPUT_DIR" && sha256sum -- *.xz *.sh BUILDINFO.txt >SHA256SUMS 2>/dev/null || true)

echo "=== Done ==="
echo "Output: $OUTPUT_DIR"
ls -lah "$OUTPUT_DIR"

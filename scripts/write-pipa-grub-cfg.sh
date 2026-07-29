#!/usr/bin/env bash
# Usage: write-pipa-grub-cfg.sh <out> <boot_label> <cmdline> <kernel_rel> <initramfs_rel> [dtb_rel ...]
set -euo pipefail
out="$1"; boot_label="$2"; cmdline="$3"; kernel_rel="$4"; initramfs_rel="$5"
shift 5
dtb_rels=("$@")
[ ${#dtb_rels[@]} -gt 0 ] || { echo "no DTB paths" >&2; exit 1; }

{
  printf 'set default=0\nset timeout=5\n\n'
  printf 'insmod part_gpt\ninsmod ext2\ninsmod gzio\n\n'
  printf 'search --no-floppy --label %s --set=root\n\n' "$boot_label"
  for dtb_rel in "${dtb_rels[@]}"; do
    dtb_name="$(basename "$dtb_rel" .dtb)"
    case "$dtb_name" in
      sm8250-xiaomi-pipa-csot) title="CSOT Panel" ;;
      sm8250-xiaomi-pipa-tianma) title="Tianma Panel" ;;
      sm8250-xiaomi-pipa) title="Generic DTB" ;;
      *) title="$dtb_name" ;;
    esac
    printf 'menuentry "openSUSE Plasma (Xiaomi Pad 6) - %s" {\n' "$title"
    printf '    linux /%s --- %s\n' "$kernel_rel" "$cmdline"
    printf '    initrd /%s\n' "$initramfs_rel"
    printf '    devicetree /%s\n' "$dtb_rel"
    printf '}\n\n'
    printf 'menuentry "openSUSE recovery - %s" {\n' "$title"
    printf '    linux /%s --- %s systemd.unit=multi-user.target\n' "$kernel_rel" "$cmdline"
    printf '    initrd /%s\n' "$initramfs_rel"
    printf '    devicetree /%s\n' "$dtb_rel"
    printf '}\n\n'
  done
} > "$out"

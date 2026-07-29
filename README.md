# KDE Plasma for Xiaomi Pad 6 (openSUSE Tumbleweed + pipa flash layout)

Bootstraps a real **openSUSE Tumbleweed aarch64** rootfs via `zypper
--installroot`, installs `patterns-kde-plasma` from the actual Tumbleweed
repos (no manual RPM extraction needed for the desktop itself), then injects
`pipa-pkgs` (kernel, firmware, Qualcomm userspace, audio/sensor config) the
same way the Nemomobile/openSUSE pipa image does — by extracting the raw
pacman package tarballs directly onto the rootfs.

Output layout matches the same pipa flash convention as the Ultramarine and
Nemomobile builds:

| Image file | Target partition | Contents |
|---|---|---|
| `silicium.img.xz` | `boot_ab` | Mu-Silicium UEFI |
| `plasma_esp.raw.xz` | `rawdump` | ESP (FAT, GRUB EFI) |
| `plasma_boot.raw.xz` | `cust` | `/boot` (kernel, initramfs, DTB, GRUB) |
| `plasma_rootfs.raw.xz` | `userdata` / `linux` | Full openSUSE Plasma + pipa HW |

```bash
./flash.sh                  # single-boot → userdata
./flash-multiboot.sh linux  # multiboot → linux partition
```

## What a build includes

1. `zypper --installroot` bootstrap of openSUSE Tumbleweed aarch64 (`oss` +
   `non-oss` + `update` repos)
2. `patterns-kde-plasma` + `sddm` from the real Tumbleweed repos — a normal
   `zypper` transaction, not manual extraction
3. **pipa-pkgs**: `linux-pipa`, firmware, UCM, sensors, Qualcomm helpers —
   extracted directly (same raw-tarball technique as `manjaro-nemo-pipa`)
4. User/session setup: real user, `sddm` (or `plasmalogin` if present),
   `graphical.target` default
5. pipa hardware glue: GPU firmware handover fix (`GSK_RENDERER`), speaker
   TDM route, sensor persistence, dbus/session-bus packages pinned explicitly

Default logins: `root`/`linux` (change before shipping), real user created by
`configure-plasma-session.sh`.

## Build locally

```bash
# Needs root for loop mounts + zypper --installroot
sudo ./scripts/ci-build-image.sh
```

Bring-up / console-only (no desktop, for hardware bring-up):
```bash
sudo IMAGE_MODE=bringup ./scripts/ci-build-image.sh
```

## Sources

| | |
|--|--|
| Base rootfs | `zypper --installroot`, `https://download.opensuse.org/ports/aarch64/tumbleweed/` |
| Desktop | openSUSE Tumbleweed `patterns-kde-plasma` (real repo, no extraction needed) |
| Hardware | [pipa-pkgs](https://thespider2.github.io/pipa-pkgs/repo/) |
| Boot layout reference | `manjaro-nemo-pipa` (same pipa flash convention) |

## A note on where this can actually be built

`ci-build-image.sh` needs to reach `download.opensuse.org` and
`thespider2.github.io` — real internet access, not a sandboxed or heavily
firewalled environment. Run it on your own machine, a VM, or a CI runner
with normal network egress.

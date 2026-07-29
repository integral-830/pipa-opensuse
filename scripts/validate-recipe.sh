#!/usr/bin/env bash
# Cheap sanity check: catches a missing file or a renamed package before you
# burn 20 minutes on a real bootstrap+build. Run this first, every time.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

test -f "$ROOT/profiles/devices/pipa"
test -f "$ROOT/scripts/ci-build-image.sh"
test -f "$ROOT/scripts/inject-pipa-pkgs.sh"
test -f "$ROOT/scripts/configure-plasma-session.sh"
test -f "$ROOT/scripts/configure-pipa-hardware.sh"
test -f "$ROOT/scripts/write-pipa-grub-cfg.sh"
test -f "$ROOT/scripts/post-process-pipa.sh"

grep -q 'linux-pipa' "$ROOT/profiles/devices/pipa"
grep -q 'xiaomi-pipa-firmware' "$ROOT/profiles/devices/pipa"
grep -q 'pipa-sound-conf' "$ROOT/profiles/devices/pipa"
grep -q 'pipa-sensors' "$ROOT/profiles/devices/pipa"
grep -q 'rmtfs' "$ROOT/profiles/devices/pipa"
grep -q 'hexagonrpc' "$ROOT/profiles/devices/pipa"
grep -q 'libssc' "$ROOT/profiles/devices/pipa"
grep -q 'qrtr' "$ROOT/profiles/devices/pipa"
grep -q 'patterns-kde-kde_plasma' "$ROOT/profiles/devices/pipa"
grep -q 'sddm' "$ROOT/profiles/devices/pipa"

echo "OK: pipa openSUSE Plasma recipe present"

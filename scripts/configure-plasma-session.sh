#!/usr/bin/env bash
# Configure the openSUSE rootfs for a graphical Plasma session on pipa:
# create the real user, enable sddm, set the default boot target.
# Called from ci-build-image.sh with ROOTFS_DIR set.
set -euo pipefail

ROOTFS_DIR="${ROOTFS_DIR:?}"
PLASMA_USER="${PLASMA_USER:-pipa}"
PLASMA_UID="${PLASMA_UID:-1000}"
PLASMA_GID="${PLASMA_GID:-1000}"
PLASMA_PASS="${PLASMA_PASS:-changeme}"

echo "=== Configuring Plasma graphical session (user=$PLASMA_USER) ==="

# --- Create the real user (root/linux is a bring-up fallback, not the daily driver) ---
ensure_group() {
  local name="$1" gid="$2"
  grep -q "^${name}:" "$ROOTFS_DIR/etc/group" || echo "${name}:x:${gid}:" >> "$ROOTFS_DIR/etc/group"
}
ensure_group "$PLASMA_USER" "$PLASMA_GID"

if command -v openssl >/dev/null 2>&1; then
  HASH=$(openssl passwd -6 "$PLASMA_PASS")
else
  HASH=$(python3 -c "import crypt; print(crypt.crypt('$PLASMA_PASS', crypt.mksalt(crypt.METHOD_SHA512)))")
fi

if ! grep -q "^${PLASMA_USER}:" "$ROOTFS_DIR/etc/passwd"; then
  echo "${PLASMA_USER}:x:${PLASMA_UID}:${PLASMA_GID}:Pipa User:/home/${PLASMA_USER}:/bin/bash" \
    >> "$ROOTFS_DIR/etc/passwd"
  echo "${PLASMA_USER}:${HASH}:19000:0:99999:7:::" >> "$ROOTFS_DIR/etc/shadow"
fi

for g in users video input audio wheel; do
  grep -q "^${g}:" "$ROOTFS_DIR/etc/group" && \
    sed -i "s/^\(${g}:[^:]*:[^:]*:\)\(.*\)$/\1\2,${PLASMA_USER}/;s/:,/:/" "$ROOTFS_DIR/etc/group" || true
done

mkdir -p "$ROOTFS_DIR/home/${PLASMA_USER}"
chown -R "${PLASMA_UID}:${PLASMA_GID}" "$ROOTFS_DIR/home/${PLASMA_USER}" 2>/dev/null || true

# --- Display manager + default target ---
mkdir -p "$ROOTFS_DIR/etc/systemd/system"
ln -sfn /usr/lib/systemd/system/graphical.target "$ROOTFS_DIR/etc/systemd/system/default.target"

if [ -f "$ROOTFS_DIR/usr/lib/systemd/system/sddm.service" ]; then
  mkdir -p "$ROOTFS_DIR/etc/systemd/system/display-manager.service.d"
  ln -sfn /usr/lib/systemd/system/sddm.service "$ROOTFS_DIR/etc/systemd/system/display-manager.service"
fi

# --- GSK renderer fix (carried over from the Fedora/katsu build) ---
# GTK4/libadwaita apps let GSK auto-select a rendering backend; on pipa's
# Adreno 650, Turnip's Vulkan driver is immature enough to crash/misrender
# them. Force GL, the mature Freedreno path, for every login shell.
install -d "$ROOTFS_DIR/etc/profile.d"
cat > "$ROOTFS_DIR/etc/profile.d/90-pipa-gsk-renderer.sh" <<'EOF'
# Force GTK4/GSK onto the stable Freedreno GL path on pipa (Adreno 650).
export GSK_RENDERER=gl
EOF
chmod 644 "$ROOTFS_DIR/etc/profile.d/90-pipa-gsk-renderer.sh"

# --- D-Bus session bus: don't rely on weak-dep resolution pulling this in ---
if ! rpm --root "$ROOTFS_DIR" -q dbus-1-daemon dbus-1-x11 >/dev/null 2>&1; then
  echo "WARNING: dbus-1-daemon not confirmed installed — verify zypper install included it"
fi

echo "Plasma session configured: user=$PLASMA_USER, default.target=graphical.target, sddm enabled"

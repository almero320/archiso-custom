#!/usr/bin/env bash
set -Eeuo pipefail

trap '
    rc=$?
    echo
    echo "========== ARCHFORGE BUILD FAILURE =========="
    echo "Exit code : $rc"
    echo "Line      : ${BASH_LINENO[0]}"
    echo "Command   : ${BASH_COMMAND}"
    echo "============================================="
    exit "$rc"
' ERR

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/out"
WORK="$ROOT/work"
PROFILE="$WORK/profile"
REPO="$PROFILE/airootfs/opt/archforge/repo"
STAMP="$(date -u +%Y%m%d-%H%M)"
ARCHISO_PROFILE="/usr/share/archiso/configs/releng"

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
command -v mkarchiso >/dev/null || { echo "Install archiso first." >&2; exit 1; }
[[ -d "$ARCHISO_PROFILE" ]] || { echo "Missing Archiso releng profile." >&2; exit 1; }
[[ -f "$ROOT/installer/archforge-install" ]] || { echo "Missing installer/archforge-install." >&2; exit 1; }
[[ -f "$ROOT/packages/target.txt" ]] || { echo "Missing packages/target.txt." >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$OUT" "$WORK"
cp -a "$ARCHISO_PROFILE" "$PROFILE"

# Keep the live ISO lean, but include the tools required by the interactive installer.
# Preserve all mandatory Archiso releng packages.
{
    cat "$PROFILE/packages.x86_64"
    cat "$ROOT/profile/packages.x86_64"
    printf '%s\n' \
        dialog \
        gptfdisk \
        dosfstools \
        e2fsprogs \
        parted \
        arch-install-scripts
} | sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' | sort -u \
  > "$WORK/packages.x86_64"

install -m644 "$WORK/packages.x86_64" "$PROFILE/packages.x86_64"
mkdir -p "$REPO"

mapfile -t TARGET_PKGS < <(grep -Ev '^[[:space:]]*(#|$)' "$ROOT/packages/target.txt" | sed -E 's/[[:space:]]+#.*$//' | awk 'NF' | sort -u)
((${#TARGET_PKGS[@]} > 0)) || { echo "Target package list is empty." >&2; exit 1; }
printf 'Resolving and downloading %s requested package roots...\n' "${#TARGET_PKGS[@]}"

# Resolve against an empty package database so dependencies already installed
# in the build container are still downloaded into the offline repository.
mkdir -p "$WORK/repo-root" "$WORK/repo-db"
pacman -Sy --noconfirm --root "$WORK/repo-root" --dbpath "$WORK/repo-db"
pacman -Sw --noconfirm --root "$WORK/repo-root" --dbpath "$WORK/repo-db" \
  --cachedir "$REPO" "${TARGET_PKGS[@]}"

# Build the repository database from every downloaded package archive.
shopt -s nullglob
PKG_FILES=("$REPO"/*.pkg.tar.zst)
((${#PKG_FILES[@]} > 0)) || { echo "No package archives were downloaded into $REPO." >&2; exit 1; }
repo-add "$REPO/archforge.db.tar.gz" "${PKG_FILES[@]}"

# Rewrite Archiso boot entries to use the Zen kernel shipped in the live profile.
while IFS= read -r -d '' cfg; do
    if grep -IqE 'vmlinuz-linux|initramfs-linux' "$cfg"; then
        echo "Updating kernel references: $cfg"
        sed -i \
          -e 's/initramfs-linux-fallback\.img/initramfs-linux-zen-fallback.img/g' \
          -e 's/initramfs-linux\.img/initramfs-linux-zen.img/g' \
          -e 's/vmlinuz-linux/vmlinuz-linux-zen/g' \
          "$cfg"
    fi
done < <(find "$PROFILE" -type f -print0)

# Install the offline repository and installer into the live root.
install -d "$PROFILE/airootfs/usr/local/bin"
install -Dm755 "$ROOT/installer/archforge-install" \
  "$PROFILE/airootfs/usr/local/bin/archforge-install"
chmod 0755 "$PROFILE/airootfs/usr/local/bin/archforge-install"
[[ -x "$PROFILE/airootfs/usr/local/bin/archforge-install" ]] || {
    echo "Installer is not executable in the Archiso profile." >&2
    exit 1
}

install -Dm644 "$ROOT/installer/archforge-live-pacman.conf" \
  "$PROFILE/airootfs/etc/archforge-live-pacman.conf"
install -Dm644 "$ROOT/installer/archforge-target-pacman.conf" \
  "$PROFILE/airootfs/etc/archforge-target-pacman.conf"
install -Dm644 "$ROOT/README.md" \
  "$PROFILE/airootfs/usr/share/doc/archforge/README.md"
install -Dm644 "$ROOT/packages/target.txt" \
  "$PROFILE/airootfs/usr/share/archforge/target.txt"

# Make the command available directly as: archforge-install
# /usr/local/bin is already on the standard Arch root PATH.

# Boot the live environment into a root TTY; no graphical login.
mkdir -p "$PROFILE/airootfs/etc/systemd/system"
ln -sf /usr/lib/systemd/system/multi-user.target \
  "$PROFILE/airootfs/etc/systemd/system/default.target"

mkarchiso -v -w "$WORK/build" -o "$OUT" "$PROFILE"

ISO="$(find "$OUT" -maxdepth 1 -type f -name '*.iso' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
[[ -n "$ISO" && -f "$ISO" ]] || { echo "ISO build produced no image." >&2; exit 1; }
mv "$ISO" "$OUT/archforge-$STAMP.iso"
sha256sum "$OUT/archforge-$STAMP.iso" > "$OUT/archforge-$STAMP.iso.sha256"
echo "Build complete: $OUT/archforge-$STAMP.iso"

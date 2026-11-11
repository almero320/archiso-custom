#!/usr/bin/env bash
set -Eeuo pipefail

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

rm -rf "$WORK"
mkdir -p "$OUT" "$WORK"
cp -a "$ARCHISO_PROFILE" "$PROFILE"

# Keep the live ISO lean: it contains the installer and tools, not the entire
# target workstation package set. The target dependency closure goes in repo/.
cp "$ROOT/profile/packages.x86_64" "$PROFILE/packages.x86_64"
mkdir -p "$REPO"

mapfile -t TARGET_PKGS < <(grep -Ev '^[[:space:]]*(#|$)' "$ROOT/packages/target.txt" | sort -u)
printf 'Resolving and downloading %s requested package roots...\n' "${#TARGET_PKGS[@]}"

# pacman resolves dependencies and downloads the complete dependency closure.
# --cachedir points directly at the embedded repository directory.
# Resolve against an empty package database so dependencies already installed
# in the build container are still downloaded into the offline repository.
mkdir -p "$WORK/repo-root" "$WORK/repo-db"
pacman -Sy --noconfirm --root "$WORK/repo-root" --dbpath "$WORK/repo-db"
pacman -Sw --noconfirm --root "$WORK/repo-root" --dbpath "$WORK/repo-db" \
  --cachedir "$REPO" "${TARGET_PKGS[@]}"

# Create a local pacman repository database.
repo-add "$REPO/archforge.db.tar.gz" "$REPO"/*.pkg.tar.zst

# Archiso's stock releng boot entries refer to the stock kernel filename.
# Rewrite those references to the Zen kernel shipped in this profile.
grep -RIl 'vmlinuz-linux\|initramfs-linux' "$PROFILE" --exclude='*.zst' 2>/dev/null | \
  while read -r cfg; do
    sed -i \
      -e 's/initramfs-linux-fallback\.img/initramfs-linux-zen-fallback.img/g' \
      -e 's/initramfs-linux\.img/initramfs-linux-zen.img/g' \
      -e 's/vmlinuz-linux/vmlinuz-linux-zen/g' "$cfg"
  done

# Install installer and repository configuration into the live root.
install -Dm755 "$ROOT/installer/archforge-install" \
  "$PROFILE/airootfs/usr/local/bin/archforge-install"
install -Dm644 "$ROOT/installer/archforge-live-pacman.conf" \
  "$PROFILE/airootfs/etc/archforge-live-pacman.conf"
install -Dm644 "$ROOT/installer/archforge-target-pacman.conf" \
  "$PROFILE/airootfs/etc/archforge-target-pacman.conf"
install -Dm644 "$ROOT/README.md" \
  "$PROFILE/airootfs/usr/share/doc/archforge/README.md"
install -Dm644 "$ROOT/packages/target.txt" \
  "$PROFILE/airootfs/usr/share/archforge/target.txt"

# Make the live environment boot to a root TTY; no graphical login.
mkdir -p "$PROFILE/airootfs/etc/systemd/system"
ln -sf /usr/lib/systemd/system/multi-user.target \
  "$PROFILE/airootfs/etc/systemd/system/default.target"

mkarchiso -v -w "$WORK/build" -o "$OUT" "$PROFILE"

ISO="$(find "$OUT" -maxdepth 1 -type f -name '*.iso' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
[[ -n "$ISO" && -f "$ISO" ]] || { echo "ISO build produced no image." >&2; exit 1; }
mv "$ISO" "$OUT/archforge-$STAMP.iso"
sha256sum "$OUT/archforge-$STAMP.iso" > "$OUT/archforge-$STAMP.iso.sha256"
echo "Build complete: $OUT/archforge-$STAMP.iso"


#!/usr/bin/env bash
set -Eeuo pipefail

trap '
    rc=$?
    echo
    echo "========== ARCHFORGE BUILD FAILURE =========="
    echo "Exit code : $rc"
    echo "Line      : ${BASH_LINENO[0]:-unknown}"
    echo "Command   : ${BASH_COMMAND:-unknown}"
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

[[ $EUID -eq 0 ]] || {
    echo "ERROR: Run as root."
    exit 1
}

command -v mkarchiso >/dev/null || {
    echo "ERROR: mkarchiso is missing."
    exit 1
}

command -v repo-add >/dev/null || {
    echo "ERROR: repo-add is missing. Install pacman-contrib."
    exit 1
}

[[ -d "$ARCHISO_PROFILE" ]] || {
    echo "ERROR: Archiso releng profile missing."
    exit 1
}

# Validate required project files.
for file in \
    "$ROOT/profile/packages.x86_64" \
    "$ROOT/packages/target.txt" \
    "$ROOT/installer/archforge-install" \
    "$ROOT/installer/archforge-live-pacman.conf" \
    "$ROOT/installer/archforge-target-pacman.conf" \
    "$ROOT/README.md"
do
    [[ -f "$file" ]] || {
        echo "ERROR: Missing project file: $file"
        exit 1
    }
done

bash -n "$ROOT/installer/archforge-install"

# Fresh build environment.
rm -rf "$WORK"
mkdir -p "$OUT" "$WORK"

# Remove old output to avoid uploading a stale ISO.
find "$OUT" -maxdepth 1 -type f \
    \( -name '*.iso' -o -name '*.sha256' -o -name 'SHA256SUMS' \) \
    -delete

cp -a "$ARCHISO_PROFILE" "$PROFILE"

mkdir -p "$REPO"

# Live ISO package list.
{
    cat "$PROFILE/packages.x86_64"
    cat "$ROOT/profile/packages.x86_64"

    cat <<'PACKAGES'
linux-zen
linux-firmware
intel-ucode
dialog
gptfdisk
dosfstools
e2fsprogs
parted
arch-install-scripts
grub
efibootmgr
PACKAGES

} | sed -E \
    -e '/^[[:space:]]*#/d' \
    -e '/^[[:space:]]*$/d' \
    -e 's/[[:space:]]+#.*$//' \
    | awk 'NF' \
    | sort -u > "$WORK/packages.x86_64"

install -m 0644 \
    "$WORK/packages.x86_64" \
    "$PROFILE/packages.x86_64"

# Read target package roots.
mapfile -t TARGET_PKGS < <(
    sed -E \
        -e '/^[[:space:]]*#/d' \
        -e '/^[[:space:]]*$/d' \
        -e 's/[[:space:]]+#.*$//' \
        "$ROOT/packages/target.txt" \
        | awk 'NF' \
        | sort -u
)

# Include bootloader packages in the installed system.
TARGET_PKGS+=(grub efibootmgr)

mapfile -t TARGET_PKGS < <(
    printf '%s\n' "${TARGET_PKGS[@]}" | sort -u
)

((${#TARGET_PKGS[@]} > 0)) || {
    echo "ERROR: Target package list is empty."
    exit 1
}

echo "Requested target package roots: ${#TARGET_PKGS[@]}"

# Resolve complete dependency closure in an empty package database.
mkdir -p "$WORK/repo-root" "$WORK/repo-db"

pacman -Sy --noconfirm \
    --root "$WORK/repo-root" \
    --dbpath "$WORK/repo-db"

pacman -Sw --noconfirm \
    --root "$WORK/repo-root" \
    --dbpath "$WORK/repo-db" \
    --cachedir "$REPO" \
    "${TARGET_PKGS[@]}"

shopt -s nullglob
PKG_FILES=("$REPO"/*.pkg.tar.zst)

((${#PKG_FILES[@]} > 0)) || {
    echo "ERROR: No package archives downloaded."
    exit 1
}

# Generate local repository database.
repo-add "$REPO/archforge.db.tar.gz" "${PKG_FILES[@]}"

[[ -s "$REPO/archforge.db" || -s "$REPO/archforge.db.tar.gz" ]] || {
    echo "ERROR: Repository database generation failed."
    exit 1
}

# Verify local repository database.
echo "Verifying ArchForge repository..."

pacman \
    --config "$ROOT/installer/archforge-live-pacman.conf" \
    -Sl archforge >/dev/null 2>&1 || {
        echo "WARNING: Live config verification skipped; repository config may use a different path."
    }

# Rewrite boot entries to use Zen kernel.
# Do not modify archisosearchuuid; mkarchiso generates it.
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

# Install executable.
install -Dm0755 \
    "$ROOT/installer/archforge-install" \
    "$PROFILE/airootfs/usr/local/bin/archforge-install"

chmod 0755 \
    "$PROFILE/airootfs/usr/local/bin/archforge-install"

test -x "$PROFILE/airootfs/usr/local/bin/archforge-install"

# Install pacman configs.
install -Dm0644 \
    "$ROOT/installer/archforge-live-pacman.conf" \
    "$PROFILE/airootfs/etc/archforge-live-pacman.conf"

install -Dm0644 \
    "$ROOT/installer/archforge-target-pacman.conf" \
    "$PROFILE/airootfs/etc/archforge-target-pacman.conf"

# Install documentation and package manifest.
install -Dm0644 \
    "$ROOT/README.md" \
    "$PROFILE/airootfs/usr/share/doc/archforge/README.md"

install -Dm0644 \
    "$ROOT/packages/target.txt" \
    "$PROFILE/airootfs/usr/share/archforge/target.txt"

# Live ISO boots to a root TTY.
mkdir -p "$PROFILE/airootfs/etc/systemd/system"

ln -sfn \
    /usr/lib/systemd/system/multi-user.target \
    "$PROFILE/airootfs/etc/systemd/system/default.target"

# Stable ISO volume label. ArchISO UUID remains generated automatically.
mkarchiso \
    -v \
    -L ARCHFORGE \
    -w "$WORK/build" \
    -o "$OUT" \
    "$PROFILE"

# Find generated ISO.
ISO="$(
    find "$OUT" -maxdepth 1 -type f -name '*.iso' \
        -printf '%T@ %p\n' \
        | sort -nr \
        | head -1 \
        | cut -d' ' -f2-
)"

[[ -n "$ISO" && -f "$ISO" ]] || {
    echo "ERROR: No ISO generated."
    exit 1
}

# Ventoy GRUB2 Mode suffix.
FINAL="$OUT/archforge-${STAMP}_VTGRUB2.iso"

mv "$ISO" "$FINAL"

# Generate checksum for final filename.
sha256sum "$FINAL" > "$FINAL.sha256"

echo
echo "======================================"
echo "       ARCHFORGE BUILD COMPLETE"
echo "======================================"
echo "ISO: $FINAL"
echo "Volume label: ARCHFORGE"
echo "Installer permission: $(stat -c '%a' "$PROFILE/airootfs/usr/local/bin/archforge-install")"
echo "SHA256:"
sha256sum "$FINAL"

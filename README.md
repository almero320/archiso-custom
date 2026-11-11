# ArchForge Offline

A research-grade Arch Linux offline installer project for x86_64 PCs.

## Design

- `linux-zen` only (no stock/LTS fallback)
- Intel integrated graphics through the in-kernel `i915` DRM driver and Mesa
- Haswell/Broadwell use Mesa Crocus; Skylake and newer supported generations generally use Iris
- Xorg + Wayland libraries, but **no DE, WM, compositor, display manager, or GUI applications**
- Native PulseAudio + ALSA
- CLI utilities and hardware diagnostics
- Local package repository embedded in the ISO for offline target installation
- UEFI and legacy BIOS boot support inherited from Archiso `releng`

`i915` is a kernel driver, not a separately installable package. `mesa` is userspace graphics support.

## Important limitations

1. Arch is rolling release. Build the ISO and its embedded package repository from the same synchronized package snapshot. Do not mix package files from different builds.
2. The included installer is deliberately conservative and interactive. It **erases the selected target disk** after explicit confirmation.
3. This is a starter project, not a certified installer. Test in QEMU first, then on spare hardware. Back up data.
4. Hardware support depends on the exact device. `intel-media-driver` and Vulkan are not guaranteed on every old Intel GPU. Haswell does not have modern Vulkan support through `vulkan-intel`.
5. The project intentionally does not install a compositor or window manager. GUI apps are omitted; Xorg/Wayland libraries alone do not create a usable graphical desktop.
6. This initial workflow builds on GitHub-hosted Ubuntu using a privileged Arch Linux container. GitHub runner capacity and ISO size may limit a full package repository. For very large builds, use a self-hosted x86_64 Linux runner with sufficient disk space.

## Build locally

Use an Arch Linux x86_64 build host. The live ISO and installed system both use `linux-zen` only:

```bash
sudo pacman -Syu --needed archiso git
git clone https://github.com/YOURNAME/archforge-offline.git
cd archforge-offline
sudo bash scripts/build.sh
```

Output: `out/archforge-YYYYMMDD-HHMM.iso`

## GitHub Actions

Push to `main`, or run **Actions → Build ArchForge ISO → Run workflow**.
The ISO and SHA256 file are uploaded as workflow artifacts.

## Installer

Boot the ISO, log in as root if needed, then run:

```bash
archforge-install
```

The installer asks for a target disk, hostname, username, timezone, and root password. It creates GPT partitions, formats them, installs the Zen kernel and package set from the embedded local repository, configures GRUB, networking, PulseAudio, and a TTY-first system.

## Package policy

Package manifests live in `packages/`. `packages/target.txt` is the complete target package selection. The build script resolves and downloads the full dependency closure into the ISO's local repository using pacman.

## License

MIT. Arch Linux trademarks and packages remain subject to their respective owners' terms.

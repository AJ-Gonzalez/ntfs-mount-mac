# NTFS Mount

NTFS Mount is a menu bar utility that gives Apple Silicon Macs full read-write access to NTFS volumes using FUSE-T and ntfs-3g, without kernel extensions or lowering SIP. It lists every attached NTFS partition, remounts Apple's read-only NTFS mounts read-write, and keeps them writable after sleep or reconnection. A one-time privileged helper performs mount, unmount, and eject; a disk-sleep assertion keeps flaky USB bridges awake. It distinguishes NTFS metadata errors from USB failures, refusing to mount damaged volumes to protect data. Volumes appear at /Volumes/<label>, so Finder, Transmission, and other applications can read and write normally.

## Install with Homebrew

NTFS Mount is distributed as a Homebrew cask (Homebrew's package type for GUI apps).

```bash
brew tap AJ-Gonzalez/ntfs-mount-mac https://github.com/AJ-Gonzalez/ntfs-mount-mac
brew install --cask AJ-Gonzalez/ntfs-mount-mac/ntfs-mount
```

FUSE-T is required and free for personal use:

```bash
brew install --cask macos-fuse-t/cask/fuse-t
```

You can also install the signed FUSE-T package from https://www.fuse-t.org.

On first launch, click the menu bar icon and choose **Install Helper**, then approve the administrator prompt once. On macOS 26 or later, also enable NTFSMount under **System Settings → Menu Bar → Allow in the Menu Bar**.

## Build from source

Requirements: Apple Silicon, macOS 14 or later, Xcode command line tools, and FUSE-T.

```bash
git clone https://github.com/AJ-Gonzalez/ntfs-mount-mac.git
cd ntfs-mount-mac

brew install autoconf automake libtool pkgconf libgcrypt
brew install --cask macos-fuse-t/cask/fuse-t

swift test
./scripts/build-ntfs3g.sh
./scripts/build.sh --install
```

`build-ntfs3g.sh` clones and builds the FUSE-T ntfs-3g fork into `build/ntfs-3g`. `build.sh` produces `build/NTFSMount.app`; `--install` copies it to `/Applications`. The root helper is installed from the app on first launch.

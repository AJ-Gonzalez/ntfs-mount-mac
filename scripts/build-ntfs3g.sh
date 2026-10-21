#!/bin/bash
# Builds the FUSE-T ntfs-3g driver into build/ntfs-3g.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/ntfs-3g"
OUT="$ROOT/build"
REPO="https://github.com/macos-fuse-t/ntfs-3g"
COMMIT="f0e5cb0274e30334dd03aefb4fd5a14c239e6756"

mkdir -p "$ROOT/vendor" "$OUT"

if [[ ! -d "$VENDOR/.git" ]]; then
    git clone "$REPO" "$VENDOR"
fi
git -C "$VENDOR" fetch --depth 1 origin "$COMMIT"
git -C "$VENDOR" checkout --detach "$COMMIT"

cd "$VENDOR"
./autogen.sh >/tmp/ntfsmount-autogen.log 2>&1
CPPFLAGS="-I/usr/local/include/fuse" \
LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib" \
./configure \
    --prefix=/usr/local \
    --exec-prefix=/usr/local \
    --with-fuse=external \
    --disable-ntfsprogs \
    --disable-plugins \
    --disable-shared \
    --enable-static \
    --sbindir=/usr/local/bin \
    --bindir=/usr/local/bin >/tmp/ntfsmount-configure.log 2>&1
make -j"$(sysctl -n hw.ncpu)" >/tmp/ntfsmount-make.log 2>&1

install -m 0755 src/ntfs-3g "$OUT/ntfs-3g"
echo "Built $OUT/ntfs-3g"

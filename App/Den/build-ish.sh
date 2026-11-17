#!/bin/bash
# Builds 斗室's Linux: the iSH ARM64 kernel as static libraries for iOS, and an Alpine root in iSH's fakefs format.
# Runs on a macOS GitHub runner before the app is built. Outputs, next to this script:
#   ish-src/             iSH source (headers for DenKernel.m)
#   build/ios/           libish.a, libish_emu.a, libfakefs.a (+ generated headers)
#   build/rootfs/alpine/ data/ + meta.db, copied into the app bundle
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/ish-src"
OUT="$HERE/build"
ISH_REPO="https://github.com/OpenMinis/ish-arm64"
ISH_COMMIT="c5c264da19148512167aa493d7bd4e50aae1b74e"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz"

if [ -f "$OUT/ios/libish.a" ] && [ -f "$OUT/ios/libish_emu.a" ] && [ -f "$OUT/ios/libfakefs.a" ] && [ -f "$OUT/rootfs/alpine/meta.db" ] && [ -d "$SRC/kernel" ]; then
  echo "斗室 is already built (cache); skipping."
  exit 0
fi

echo "::group::tools"
brew install meson ninja llvm lld libarchive >/dev/null 2>&1 || brew install meson ninja llvm lld libarchive
export PATH="$(brew --prefix llvm)/bin:$(brew --prefix lld)/bin:$PATH"
meson --version; ninja --version
echo "::endgroup::"

echo "::group::source"
if [ ! -d "$SRC/.git" ]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$ISH_REPO"
fi
git -C "$SRC" fetch -q --depth 1 origin "$ISH_COMMIT"
git -C "$SRC" checkout -q FETCH_HEAD
git -C "$SRC" log -1 --oneline
echo "::endgroup::"

mkdir -p "$OUT"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
AR="$(xcrun --sdk iphoneos --find ar)"

echo "::group::kernel for iOS"
cat > "$OUT/cross-ios.txt" <<CROSS
[binaries]
c = '$CLANG'
ar = '$AR'
strip = 'strip'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=17.0']
c_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=17.0']

[properties]
needs_exe_wrapper = true
CROSS
rm -rf "$OUT/ios"
(
  unset SDKROOT IPHONEOS_DEPLOYMENT_TARGET
  export CC="xcrun --sdk macosx clang"
  meson setup "$OUT/ios" "$SRC" --cross-file "$OUT/cross-ios.txt" \
    -Dguest_arch=arm64 -Djit=false --buildtype=release -Db_ndebug=true -Dlog_handler=nslog 2>&1 | tail -n 60
)
ninja -C "$OUT/ios" libish.a libish_emu.a libfakefs.a 2>&1 | tail -n 40
ls -lh "$OUT/ios"/*.a
echo "::endgroup::"

echo "::group::root"
# fakefsify runs on this Mac only once, so build it straight from its few sources (works on Intel and Apple runners alike).
ARCHIVE="$(brew --prefix libarchive)"
FAKEFSIFY="$OUT/fakefsify"
(
  unset SDKROOT IPHONEOS_DEPLOYMENT_TARGET
  xcrun --sdk macosx clang -O2 -w -I"$SRC" -I"$OUT/ios" -I"$ARCHIVE/include" \
    "$SRC/tools/fakefsify.c" "$SRC/tools/fakefs.c" "$SRC/util/fchdir.c" \
    "$SRC/fs/fake-db.c" "$SRC/fs/fake-migrate.c" "$SRC/fs/fake-rebuild.c" \
    -L"$ARCHIVE/lib" -larchive -lsqlite3 -o "$FAKEFSIFY"
)
curl -fsSL "$ALPINE_URL" -o "$OUT/alpine.tar.gz"
rm -rf "$OUT/rootfs"
mkdir -p "$OUT/rootfs"
"$FAKEFSIFY" "$OUT/alpine.tar.gz" "$OUT/rootfs/alpine"
du -sh "$OUT/rootfs/alpine"
ls "$OUT/rootfs/alpine"
echo "::endgroup::"

#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <crossover-version>" >&2
    exit 2
fi

VERSION="$1"
SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "${SCRIPTDIR}/.." && pwd)"
SOURCE_URL="https://media.codeweavers.com/pub/crossover/source/crossover-sources-${VERSION}.tar.gz"
TARBALL="${WORKSPACE}/crossover-sources-${VERSION}.tar.gz"
WORKDIR="${WORKSPACE}/workdir"
BUILDDIR="${WORKDIR}/build-wine"
STAGEDIR="${WORKDIR}/stage"
APPNAME="Wine Crossover ${VERSION}"
APPDIR="${STAGEDIR}/${APPNAME}.app"
BUNDLE_CONTENTS="${APPDIR}/Contents"
BUNDLE_RES="${BUNDLE_CONTENTS}/Resources"
BUNDLE_MACOS="${BUNDLE_CONTENTS}/MacOS"
DESTROOT="${STAGEDIR}/destroot"
ARTIFACT="${WORKSPACE}/winecx-${VERSION}-osx64.tar.gz"

group()    { echo "::group::$1"; }
endgroup() { echo "::endgroup::"; }

group "Download crossover-sources-${VERSION}.tar.gz"
if [[ ! -f "${TARBALL}" ]]; then
    curl -fsSL -o "${TARBALL}" "${SOURCE_URL}"
fi
ls -lh "${TARBALL}"
endgroup

group "Extract sources"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
tar -xzf "${TARBALL}" -C "${WORKDIR}"
test -x "${WORKDIR}/sources/wine/configure"
endgroup

group "Configure environment"
BREW_PREFIX="$(brew --prefix)"
export CC="ccache clang"
export CXX="ccache clang++"
export i386_CC="ccache i686-w64-mingw32-gcc"
export x86_64_CC="ccache x86_64-w64-mingw32-gcc"
export CPATH="${BREW_PREFIX}/include"
export LIBRARY_PATH="${BREW_PREFIX}/lib"
export MACOSX_DEPLOYMENT_TARGET=10.15
export CFLAGS="-O2 -Wno-deprecated-declarations -Wno-format"
export CROSSCFLAGS="-O2 -Wno-incompatible-pointer-types"
export LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-rpath,@loader_path/../lib -Wl,-rpath,@loader_path/../../ -Wl,-rpath,${BREW_PREFIX}/lib"
export PATH="${BREW_PREFIX}/opt/bison/bin:${PATH}"
endgroup

group "Configure wine"
mkdir -p "${BUILDDIR}"
pushd "${BUILDDIR}" >/dev/null
"${WORKDIR}/sources/wine/configure" \
    --prefix= \
    --disable-tests \
    --disable-winedbg \
    --enable-win64 \
    --enable-archs=i386,x86_64 \
    --with-coreaudio \
    --with-cups \
    --with-freetype \
    --with-gettext \
    --with-gnutls \
    --with-mingw \
    --with-opencl \
    --with-pcap \
    --with-pthread \
    --with-sdl \
    --with-unwind \
    --with-vulkan \
    --without-alsa \
    --without-capi \
    --without-dbus \
    --without-fontconfig \
    --without-gettextpo \
    --without-gphoto \
    --without-gssapi \
    --with-gstreamer \
    --without-inotify \
    --without-krb5 \
    --without-netapi \
    --without-opengl \
    --without-oss \
    --without-pulse \
    --without-sane \
    --without-udev \
    --without-usb \
    --without-v4l2 \
    --without-x
popd >/dev/null
endgroup

group "Build wine"
make -C "${BUILDDIR}" -j"$(sysctl -n hw.ncpu)"
endgroup

group "Stage bundle"
rm -rf "${STAGEDIR}"
mkdir -p "${BUNDLE_RES}/wine" "${BUNDLE_MACOS}" "${DESTROOT}"
make -C "${BUILDDIR}" install DESTDIR="${DESTROOT}"
mv "${DESTROOT}"/* "${BUNDLE_RES}/wine/"
rmdir "${DESTROOT}"
test -x "${BUNDLE_RES}/wine/bin/wine"
file "${BUNDLE_RES}/wine/bin/wine"
"${BUNDLE_RES}/wine/bin/wine" --version
cat > "${BUNDLE_MACOS}/wine" <<'EOF'
#!/bin/sh
exec "$(dirname "$0")/../Resources/wine/bin/wine" "$@"
EOF
chmod +x "${BUNDLE_MACOS}/wine"
cp "${SCRIPTDIR}/bundle/PkgInfo" "${BUNDLE_CONTENTS}/PkgInfo"
sed "s/@VERSION@/${VERSION}/g" "${SCRIPTDIR}/bundle/Info.plist.in" > "${BUNDLE_CONTENTS}/Info.plist"
endgroup

group "Bundle external dylibs"
WINE_LIB="${BUNDLE_RES}/wine/lib"

collect_brew_deps() {
  xargs otool -L 2>/dev/null \
    | awk '/^\t/{print $1}' \
    | grep -E '^/(usr/local|opt/homebrew)' \
    | grep -v '\.framework' \
    | grep -v "${BUNDLE_RES}" \
    | sort -u || true
    
}

copy_to_lib() {
  while IFS= read -r dep; do
    [[ -z "$dep" || ! -f "$dep" ]] && continue
    depname="$(basename "$dep")"
    cp -n "$dep" "${WINE_LIB}/${depname}" 2>/dev/null && echo "  ✓ ${depname}"
  done < "$1"
}

echo "=== Pass 1: direct Wine deps ==="
{
  find "${BUNDLE_RES}/wine/bin" -type f
  find "${BUNDLE_RES}/wine/lib/wine" \( -name "*.so" -o -name "*.dylib" \) -type f
} | collect_brew_deps > /tmp/deps1.txt || true
copy_to_lib /tmp/deps1.txt

echo "=== Pass 2: transitive deps ==="
find "${WINE_LIB}" -maxdepth 1 -name "*.dylib" \
  | collect_brew_deps > /tmp/deps2.txt || true
copy_to_lib /tmp/deps2.txt

echo "=== GStreamer plugins ==="
mkdir -p "${WINE_LIB}/gstreamer-1.0"
for gst_dir in \
  "${BREW_PREFIX}/lib/gstreamer-1.0" \
  "/Library/Frameworks/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0"; do
  [[ -d "$gst_dir" ]] || continue
  cp "$gst_dir"/*.dylib "${WINE_LIB}/gstreamer-1.0/" 2>/dev/null || true
  echo "  ✓ plugins from ${gst_dir}"
done

echo "Total dylibs bundled: $(ls -1 "${WINE_LIB}" | grep '\.dylib$' | wc -l | tr -d ' ')"
endgroup

group "Package artifact"
rm -f "${ARTIFACT}"
tar -C "${STAGEDIR}" -czf "${ARTIFACT}" "${APPNAME}.app"
ls -lh "${ARTIFACT}"
endgroup

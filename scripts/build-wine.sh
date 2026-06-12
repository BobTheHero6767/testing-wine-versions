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
echo "=== winemetal stub check ==="
ls "${WORKDIR}/sources/wine/dlls/" | grep winemetal || echo "winemetal NOT found"
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
export ac_cv_lib_soname_vulkan=""
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
DLL_COUNT=$(find "${BUNDLE_RES}/wine/lib/wine/x86_64-windows" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
echo "=== Build sanity: ${DLL_COUNT} PE DLLs ==="
[[ "${DLL_COUNT}" -lt 200 ]] && { echo "✗ FATAL: build incomplete — only ${DLL_COUNT} PE DLLs (expect 200+)"; exit 1; }
cat > "${BUNDLE_MACOS}/wine" <<'EOF'
#!/bin/sh
exec "$(dirname "$0")/../Resources/wine/bin/wine" "$@"
EOF
chmod +x "${BUNDLE_MACOS}/wine"
cp "${SCRIPTDIR}/bundle/PkgInfo" "${BUNDLE_CONTENTS}/PkgInfo"
sed "s/@VERSION@/${VERSION}/g" "${SCRIPTDIR}/bundle/Info.plist.in" > "${BUNDLE_CONTENTS}/Info.plist"
endgroup

group "Bundle external dylibs"
set +o pipefail
WINE_LIB="${BUNDLE_RES}/wine/lib"
WINE_UNIX_LIB="${BUNDLE_RES}/wine/lib/wine/x86_64-unix"

echo "=== Bundle all Wine runtime deps (otool-recursive) ==="
bundle_dep() {
  local src="$1" depname
  depname=$(basename "$src")
  [[ -f "${WINE_LIB}/${depname}" ]] && return 0
  [[ -f "$src" ]] || return 0
  cp -Lf "$src" "${WINE_LIB}/"
  echo "  ✓ ${depname}"
  while IFS= read -r tdep; do
    [[ "$tdep" =~ ^(/usr/local/|/opt/homebrew/) ]] || continue
    bundle_dep "$tdep"
  done < <(otool -L "$src" 2>/dev/null | awk 'NR>1{print $1}')
}
find "${BUNDLE_RES}/wine/bin" "${WINE_UNIX_LIB}" -type f \
  \( -name "wine" -o -name "wine64" -o -name "wineserver" -o -name "*.so" \) \
| while read -r f; do
  while IFS= read -r dep; do
    [[ "$dep" =~ ^(/usr/local/|/opt/homebrew/) ]] || continue
    bundle_dep "$dep"
  done < <(otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}')
done

echo "=== Bundle dlopen dependencies (freetype / gnutls / SDL2) ==="
for candidate in \
  "${BREW_PREFIX}/opt/freetype/lib/libfreetype.6.dylib" \
  "/usr/local/opt/freetype/lib/libfreetype.6.dylib"; do
  [[ -f "$candidate" ]] && { bundle_dep "$candidate"; break; }
done
for candidate in \
  "${BREW_PREFIX}/opt/gnutls/lib/libgnutls.30.dylib" \
  "/usr/local/opt/gnutls/lib/libgnutls.30.dylib"; do
  [[ -f "$candidate" ]] && { bundle_dep "$candidate"; break; }
done
for candidate in \
  "${BREW_PREFIX}/opt/sdl2/lib/libSDL2-2.0.0.dylib" \
  "/usr/local/opt/sdl2/lib/libSDL2-2.0.0.dylib" \
  "${BREW_PREFIX}/lib/libSDL2-2.0.0.dylib" \
  "/usr/local/lib/libSDL2-2.0.0.dylib"; do
  [[ -f "$candidate" ]] && { bundle_dep "$candidate"; break; }
done

echo "=== Bundle MoltenVK ==="
MOLTEN_FOUND=""
for candidate in \
  "${BREW_PREFIX}/opt/molten-vk/lib/libMoltenVK.dylib" \
  "${BREW_PREFIX}/lib/libMoltenVK.dylib" \
  "/usr/local/opt/molten-vk/lib/libMoltenVK.dylib" \
  "/usr/local/lib/libMoltenVK.dylib"; do
  if [[ -f "$candidate" ]]; then
    cp -Lf "$candidate" "${WINE_LIB}/"
    echo "  ✓ libMoltenVK.dylib"
    MOLTEN_FOUND=1; break
  fi
done
[[ -n "$MOLTEN_FOUND" ]] || echo "  ✗ WARNING: libMoltenVK.dylib not found — Vulkan/Metal bridge absent"

echo "=== Rewrite Homebrew paths in bundled dylibs ==="
for dylib in "${WINE_LIB}"/*.dylib; do
  [[ -f "$dylib" ]] || continue
  while IFS= read -r dep; do
    [[ "$dep" =~ ^(/usr/local/|/opt/homebrew/) ]] || continue
    depname=$(basename "$dep")
    [[ -f "${WINE_LIB}/${depname}" ]] || continue
    install_name_tool -change "$dep" "@loader_path/${depname}" "$dylib" 2>/dev/null \
      && echo "  ✓ $(basename $dylib) → ${depname}"
  done < <(otool -L "$dylib" 2>/dev/null | awk 'NR>1{print $1}')
done

echo "=== Rewrite Homebrew paths in Wine binaries ==="
find "${BUNDLE_RES}/wine/bin" -type f \( -name "wine" -o -name "wine64" -o -name "wineserver" \) \
| while read -r binary; do
  while IFS= read -r dep; do
    [[ "$dep" =~ ^(/usr/local/|/opt/homebrew/) ]] || continue
    depname=$(basename "$dep")
    [[ -f "${WINE_LIB}/${depname}" ]] || continue
    install_name_tool -change "$dep" "@loader_path/../lib/${depname}" "$binary" 2>/dev/null \
      && echo "  ✓ bin/$(basename $binary) → ${depname}"
  done < <(otool -L "$binary" 2>/dev/null | awk 'NR>1{print $1}')
done

echo "=== Rewrite Homebrew paths in .so modules ==="
find "${WINE_UNIX_LIB}" -name "*.so" | while read -r sofile; do
  while IFS= read -r dep; do
    [[ "$dep" =~ ^(/usr/local/|/opt/homebrew/) ]] || continue
    depname=$(basename "$dep")
    [[ -f "${WINE_LIB}/${depname}" ]] || continue
    install_name_tool -change "$dep" "@loader_path/../../${depname}" "$sofile" 2>/dev/null \
      && echo "  ✓ $(basename $sofile) → ${depname}"
  done < <(otool -L "$sofile" 2>/dev/null | awk 'NR>1{print $1}')
done

echo "=== GStreamer plugins ==="
mkdir -p "${WINE_LIB}/gstreamer-1.0"
for gst_dir in \
  "${BREW_PREFIX}/lib/gstreamer-1.0" \
  "/usr/local/lib/gstreamer-1.0" \
  "/Library/Frameworks/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0"; do
  [[ -d "$gst_dir" ]] || continue
  cp "$gst_dir"/*.dylib "${WINE_LIB}/gstreamer-1.0/" 2>/dev/null || true
  echo "  ✓ GStreamer plugins from ${gst_dir}"
done

echo "Total dylibs bundled: $(ls -1 "${WINE_LIB}" | grep '\.dylib$' | wc -l | tr -d ' ')"
echo "=== Critical lib check ==="
ls "${WINE_LIB}" | grep -iE 'freetype|gnutls|MoltenVK|SDL' || echo "WARNING: missing critical libs"
endgroup

group "Package artifact"
rm -f "${ARTIFACT}"
tar -C "${STAGEDIR}" -czf "${ARTIFACT}" "${APPNAME}.app"
ls -lh "${ARTIFACT}"
endgroup

#!/usr/bin/env bash
# Builds an LGPL libmpv-2.dll for Windows x64, cross-compiled from Linux (WSL
# Ubuntu 24.04 works). Every dependency is linked statically into the one DLL,
# so the app ships a single file, and the DLL as a whole can still be replaced
# by the user (LGPL requirement).
#
# No GPL code: mpv is built with -Dgpl=false, FFmpeg without --enable-gpl or
# --enable-nonfree, and no GPL dependency (x264, x265, rubberband, dvdnav...).
# The script checks both before packaging.
#
# Usage: bash scripts/libmpv/build-lgpl.sh [work dir]   (default ~/watchnear-libmpv)
# Output: <work dir>/out/ with libmpv-2.dll, licenses/, sources.tar.xz, versions.txt;
# the DLL and licenses are also copied into this repository
# (src-tauri/lib/libmpv-2.dll, src-tauri/licenses/libmpv/).
#
# Packages (Ubuntu): mingw-w64 nasm pkg-config python3-venv ninja-build cmake
# git wget xz-utils autoconf automake libtool gperf
set -euo pipefail

# --- Pinned versions --------------------------------------------------------
MPV=v0.41.0
FFMPEG=n8.1.3
LIBPLACEBO=v7.351.0
LIBASS=0.17.4
DAV1D=1.5.3
SHADERC=v2026.4
SPIRV_CROSS=vulkan-sdk-1.4.363.0
LCMS2=lcms2.19.1
ZLIB_NG=2.3.3
NV_HEADERS=n13.0.19.0
AMF=1.5.2
ICONV=1.18
FREETYPE=2.14.3
FRIBIDI=1.0.16
HARFBUZZ=14.2.0
MESON=1.9.1

WORK=${1:-$HOME/watchnear-libmpv}
SRC=$WORK/src
PREFIX=$WORK/prefix
OUT=$WORK/out
TARGET=x86_64-w64-mingw32
JOBS=$(nproc)
mkdir -p "$SRC" "$PREFIX" "$OUT"

# --- Toolchain --------------------------------------------------------------
# The -posix variant has the std::thread support shaderc needs.
export CC=$TARGET-gcc-posix CXX=$TARGET-g++-posix AR=$TARGET-ar RANLIB=$TARGET-ranlib
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
export PKG_CONFIG_PATH=
export CFLAGS="-O2 -I$PREFIX/include" CXXFLAGS="-O2 -I$PREFIX/include" LDFLAGS="-L$PREFIX/lib"
# Meson's find_library (iconv) only searches gcc's own dirs, which include LIBRARY_PATH.
export LIBRARY_PATH=$PREFIX/lib

# Recent meson (Ubuntu's is too old for some subprojects), in a venv.
if [ ! -x "$WORK/venv/bin/meson" ]; then
    python3 -m venv "$WORK/venv"
    "$WORK/venv/bin/pip" install -q "meson==$MESON"
fi
export PATH=$WORK/venv/bin:$PATH

cat >"$WORK/crossfile" <<EOF
[built-in options]
buildtype = 'release'
default_library = 'static'
prefer_static = true
wrap_mode = 'nodownload'
# Meson ignores CFLAGS/LDFLAGS when cross-compiling.
c_args = ['-I$PREFIX/include']
cpp_args = ['-I$PREFIX/include']
c_link_args = ['-L$PREFIX/lib']
cpp_link_args = ['-L$PREFIX/lib']
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$TARGET-strip'
pkg-config = 'pkg-config'
windres = '$TARGET-windres'
dlltool = '$TARGET-dlltool'
nasm = 'nasm'
[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

cat >"$WORK/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER $CC)
set(CMAKE_CXX_COMPILER $CXX)
set(CMAKE_RC_COMPILER $TARGET-windres)
set(CMAKE_FIND_ROOT_PATH $PREFIX /usr/$TARGET)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF

MESON_ARGS=(--cross-file "$WORK/crossfile" --prefix "$PREFIX" --libdir lib)
CMAKE_ARGS=(-G Ninja -Wno-dev -DCMAKE_TOOLCHAIN_FILE="$WORK/toolchain.cmake"
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF)
AT_ARGS=(--host=$TARGET --prefix="$PREFIX" --enable-static --disable-shared)

# --- Helpers ----------------------------------------------------------------
# git_get <dir> <url> <tag>
git_get() {
    [ -d "$SRC/$1" ] || git clone -q --depth 1 --branch "$3" --recurse-submodules --shallow-submodules "$2" "$SRC/$1"
}
# tar_get <dir> <url>
tar_get() {
    [ -d "$SRC/$1" ] && return 0
    wget -q -O "$SRC/$1.tar" "$2"
    tar -xf "$SRC/$1.tar" -C "$SRC"
    rm "$SRC/$1.tar"
}
# step <name> <command...>: runs once, logs to $WORK/logs/<name>.log
step() {
    local name=$1; shift
    [ -e "$WORK/done/$name" ] && return 0
    mkdir -p "$WORK/logs" "$WORK/done"
    echo ">> $name"
    if ! ("$@") >"$WORK/logs/$name.log" 2>&1; then
        echo "!! $name failed, see $WORK/logs/$name.log"; tail -30 "$WORK/logs/$name.log"; exit 1
    fi
    touch "$WORK/done/$name"
}
meson_build() { # <src dir> <meson options...>
    local dir=$SRC/$1; shift
    rm -rf "$dir/_build"
    meson setup "$dir/_build" "$dir" "${MESON_ARGS[@]}" "$@"
    ninja -C "$dir/_build" install
}
cmake_build() { # <src dir> <cmake options...>
    local dir=$SRC/$1; shift
    rm -rf "$dir/_build"
    cmake -S "$dir" -B "$dir/_build" "${CMAKE_ARGS[@]}" "$@"
    ninja -C "$dir/_build" install
}

# --- Dependencies -----------------------------------------------------------
b_iconv() {
    tar_get libiconv-$ICONV https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$ICONV.tar.gz
    cd "$SRC/libiconv-$ICONV" && ./configure "${AT_ARGS[@]}" && make -j"$JOBS" && make install
}
b_zlib() {
    git_get zlib-ng https://github.com/zlib-ng/zlib-ng $ZLIB_NG
    cmake_build zlib-ng -DZLIB_COMPAT=ON -DBUILD_TESTING=OFF -DZLIBNG_ENABLE_TESTS=OFF -DWITH_GTEST=OFF
    # mingw builds name it libzlib*.a; FFmpeg and freetype look for -lz.
    [ -e "$PREFIX/lib/libz.a" ] || cp "$PREFIX/lib/libzlibstatic.a" "$PREFIX/lib/libz.a" 2>/dev/null || cp "$PREFIX"/lib/libzlib*.a "$PREFIX/lib/libz.a"
}
b_headers() {
    git_get nv-codec-headers https://github.com/FFmpeg/nv-codec-headers $NV_HEADERS
    make -C "$SRC/nv-codec-headers" PREFIX="$PREFIX" install
    tar_get amf-headers-v$AMF https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v$AMF/AMF-headers-v$AMF.tar.gz
    mkdir -p "$PREFIX/include" && cp -r "$SRC/amf-headers-v$AMF/AMF" "$PREFIX/include/"
}
b_dav1d() {
    git_get dav1d https://code.videolan.org/videolan/dav1d.git $DAV1D
    meson_build dav1d -Denable_tools=false -Denable_tests=false
}
b_lcms2() {
    git_get lcms2 https://github.com/mm2/Little-CMS $LCMS2
    meson_build lcms2 -Dtests=disabled -Dutils=false -Djpeg=disabled -Dtiff=disabled
}
b_shaderc() {
    if [ ! -d "$SRC/shaderc" ]; then
        git_get shaderc https://github.com/google/shaderc $SHADERC
        (cd "$SRC/shaderc" && python3 utils/git-sync-deps)
    fi
    cmake_build shaderc -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
        -DSHADERC_SKIP_COPYRIGHT_CHECK=ON -DSPIRV_SKIP_EXECUTABLES=ON -DENABLE_GLSLANG_BINARIES=OFF
    # libplacebo and mpv look for "shaderc": point it at the static, all-in-one library.
    sed 's/-lshaderc_combined$/-lshaderc_combined -lstdc++/' "$PREFIX/lib/pkgconfig/shaderc_combined.pc" \
        >"$PREFIX/lib/pkgconfig/shaderc.pc"
}
b_spirv_cross() {
    git_get SPIRV-Cross https://github.com/KhronosGroup/SPIRV-Cross $SPIRV_CROSS
    cmake_build SPIRV-Cross -DSPIRV_CROSS_SHARED=OFF -DSPIRV_CROSS_STATIC=ON -DSPIRV_CROSS_CLI=OFF \
        -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_ENABLE_MSL=OFF -DSPIRV_CROSS_ENABLE_CPP=OFF \
        -DSPIRV_CROSS_ENABLE_REFLECT=OFF -DSPIRV_CROSS_ENABLE_UTIL=OFF -DSPIRV_CROSS_EXCEPTIONS_TO_ASSERTIONS=ON
    # libplacebo and mpv look for "spirv-cross-c-shared"; the static .pc lists
    # only the C wrapper, not the libraries it needs.
    cat >"$PREFIX/lib/pkgconfig/spirv-cross-c-shared.pc" <<EOF
prefix=$PREFIX
Name: spirv-cross-c-shared
Description: SPIRV-Cross C API (static)
Version: $(sed -n 's/^Version: //p' "$PREFIX/lib/pkgconfig/spirv-cross-c.pc")
Libs: -L\${prefix}/lib -lspirv-cross-c -lspirv-cross-hlsl -lspirv-cross-glsl -lspirv-cross-core -lstdc++
Cflags: -I\${prefix}/include/spirv_cross
EOF
}
b_ffmpeg() {
    git_get ffmpeg https://github.com/FFmpeg/FFmpeg $FFMPEG
    rm -rf "$SRC/ffmpeg/_build" && mkdir -p "$SRC/ffmpeg/_build" && cd "$SRC/ffmpeg/_build"
    ../configure --prefix="$PREFIX" --target-os=mingw32 --arch=x86_64 --enable-cross-compile \
        --cross-prefix=$TARGET- --cc="$CC" --cxx="$CXX" \
        --pkg-config=pkg-config --pkg-config-flags=--static \
        --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib" \
        --enable-static --disable-shared --disable-programs --disable-doc --disable-debug \
        --enable-libdav1d --disable-encoders --enable-encoder=mjpeg,png \
        --disable-muxers --enable-muxer=spdif --disable-indevs --disable-outdevs \
        | tee configure.out
    grep -q "^License: LGPL version 2.1 or later" configure.out || { echo "FFmpeg is not LGPL 2.1+"; exit 1; }
    make -j"$JOBS" && make install
}
b_libplacebo() {
    git_get libplacebo https://code.videolan.org/videolan/libplacebo.git $LIBPLACEBO
    meson_build libplacebo -Ddemos=false -Dtests=false -Dd3d11=enabled -Dshaderc=enabled \
        -Dlcms=enabled -Dvulkan=disabled -Dopengl=disabled -Dglslang=disabled
}
b_freetype() {
    tar_get freetype-$FREETYPE https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE.tar.xz
    meson_build freetype-$FREETYPE -Dharfbuzz=disabled -Dpng=disabled -Dbrotli=disabled -Dbzip2=disabled -Dzlib=system
}
b_fribidi() {
    tar_get fribidi-$FRIBIDI https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI/fribidi-$FRIBIDI.tar.xz
    meson_build fribidi-$FRIBIDI -Dtests=false -Ddocs=false -Dbin=false
}
b_harfbuzz() {
    tar_get harfbuzz-$HARFBUZZ https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ/harfbuzz-$HARFBUZZ.tar.xz
    meson_build harfbuzz-$HARFBUZZ -Dfreetype=enabled -Dtests=disabled -Dglib=disabled -Dgobject=disabled \
        -Dcairo=disabled -Dicu=disabled -Ddocs=disabled -Dutilities=disabled -Dintrospection=disabled
}
b_libass() {
    git_get libass https://github.com/libass/libass $LIBASS
    if [ -f "$SRC/libass/meson.build" ]; then
        meson_build libass -Ddirectwrite=enabled -Dfontconfig=disabled -Dtest=disabled
    else
        cd "$SRC/libass" && ./autogen.sh && ./configure "${AT_ARGS[@]}" --disable-fontconfig --enable-directwrite \
            && make -j"$JOBS" && make install
    fi
}

step iconv b_iconv
step zlib b_zlib
step headers b_headers
step dav1d b_dav1d
step lcms2 b_lcms2
step shaderc b_shaderc
step spirv-cross b_spirv_cross
step ffmpeg b_ffmpeg
step libplacebo b_libplacebo
step freetype b_freetype
step fribidi b_fribidi
step harfbuzz b_harfbuzz
step libass b_libass

# --- mpv --------------------------------------------------------------------
b_mpv() {
    git_get mpv https://github.com/mpv-player/mpv $MPV
    # No scripting of any kind (Lua, JavaScript, C plugins): WatchNear never runs scripts.
    local off=(cplugins cdda dvdnav dvbin libbluray libarchive javascript lua rubberband vapoursynth uchardet
        sdl2-audio sdl2-video sdl2-gamepad jpeg vulkan win32-smtc caca sixel openal zimg libavdevice
        gl egl-angle egl-angle-lib egl-angle-win32 gl-win32 gl-dxinterop plain-gl direct3d
        html-build manpage-build pdf-build)
    local on=(d3d11 shaderc spirv-cross wasapi d3d-hwaccel lcms2 iconv zlib win32-threads)
    local args=(-Dlibmpv=true -Dcplayer=false -Dgpl=false -Dtests=false -Dbuild-date=false
        -Ddefault_library=shared
        "-Dc_link_args=['-L$PREFIX/lib','-static','-static-libgcc','-static-libstdc++']")
    for f in "${off[@]}"; do args+=(-D$f=disabled); done
    for f in "${on[@]}"; do args+=(-D$f=enabled); done
    # Meson's built-in iconv lookup ignores our prefix: provide it through a
    # local subproject (implicit fallback), without touching mpv's sources.
    mkdir -p "$SRC/mpv/subprojects/iconv"
    printf '[wrap-file]\ndirectory = iconv\n[provide]\ndependency_names = iconv\n' >"$SRC/mpv/subprojects/iconv.wrap"
    cat >"$SRC/mpv/subprojects/iconv/meson.build" <<EOF
project('iconv', 'c')
lib = meson.get_compiler('c').find_library('iconv', dirs: ['$PREFIX/lib'], static: true)
meson.override_dependency('iconv', declare_dependency(dependencies: lib))
EOF
    rm -rf "$SRC/mpv/_build"
    meson setup "$SRC/mpv/_build" "$SRC/mpv" "${MESON_ARGS[@]}" "${args[@]}"
    ninja -C "$SRC/mpv/_build" libmpv-2.dll
}
step mpv b_mpv

# --- Checks and packaging ---------------------------------------------------
DLL=$SRC/mpv/_build/libmpv-2.dll
cp "$DLL" "$OUT/libmpv-2.dll"
$TARGET-strip "$OUT/libmpv-2.dll"

# The DLL must only depend on Windows system DLLs.
deps=$($TARGET-objdump -p "$OUT/libmpv-2.dll" | awk '/DLL Name:/ {print $3}' | sort -u)
echo "Imports:"; echo "$deps" | sed 's/^/  /'
if echo "$deps" | grep -qiE "^(lib|avcodec|avformat|avutil|avfilter|avdevice|swscale|swresample|postproc|zlib|shaderc|dav1d|spirv)"; then
    echo "The DLL depends on a non-system DLL"; exit 1
fi
# mpv must report an LGPL build.
grep -q "\-Dgpl=false" "$SRC/mpv/_build/meson-logs/meson-log.txt" || { echo "mpv was not configured with -Dgpl=false"; exit 1; }
# FFmpeg embeds its license string; GPL libraries leave their own marks.
# (Plain names such as "dvdnav" or "x264" also appear in LGPL code, so they are not checked.)
grep -aq "LGPL version 2.1 or later" "$OUT/libmpv-2.dll" || { echo "FFmpeg license string missing"; exit 1; }
if grep -aqE "(^|[^L])GPL version [23] or later|nonfree and unredistributable|RubberBandStretcher|x265 \(build|libdvdnav:" "$OUT/libmpv-2.dll"; then
    echo "GPL component found in the DLL"; exit 1
fi

# License texts of everything inside the DLL.
L=$OUT/licenses
rm -rf "$L" && mkdir -p "$L"
cp "$SRC/mpv/LICENSE.LGPL" "$L/LGPL-2.1.txt"
cp "$SRC/mpv/Copyright" "$L/mpv-Copyright.txt"
cp "$SRC/ffmpeg/LICENSE.md" "$L/ffmpeg-LICENSE.md"
cp "$SRC/libplacebo/LICENSE" "$L/libplacebo-LICENSE.txt"
cp "$SRC/libass/COPYING" "$L/libass-COPYING.txt"
cp "$SRC/dav1d/COPYING" "$L/dav1d-COPYING.txt"
cp "$SRC/lcms2/LICENSE" "$L/lcms2-LICENSE.txt" 2>/dev/null || cp "$SRC/lcms2/COPYING" "$L/lcms2-LICENSE.txt"
cp "$SRC/zlib-ng/LICENSE.md" "$L/zlib-ng-LICENSE.md"
cp "$SRC/freetype-$FREETYPE/docs/FTL.TXT" "$L/freetype-FTL.txt"
cp "$SRC/fribidi-$FRIBIDI/COPYING" "$L/fribidi-COPYING.txt"
cp "$SRC/harfbuzz-$HARFBUZZ/COPYING" "$L/harfbuzz-COPYING.txt"
cp "$SRC/libiconv-$ICONV/COPYING.LIB" "$L/libiconv-COPYING.LIB.txt"
cp "$SRC/shaderc/LICENSE" "$L/shaderc-LICENSE.txt"
cp "$SRC/shaderc/third_party/glslang/LICENSE.txt" "$L/glslang-LICENSE.txt"
cp "$SRC/shaderc/third_party/spirv-tools/LICENSE" "$L/spirv-tools-LICENSE.txt"
cp "$SRC/shaderc/third_party/spirv-headers/LICENSE" "$L/spirv-headers-LICENSE.txt"
cp "$SRC/SPIRV-Cross/LICENSE" "$L/spirv-cross-LICENSE.txt"
# The AMF headers tarball has no license file: the MIT notice is in each header.
sed -n '1,30p' "$SRC/amf-headers-v$AMF/AMF/core/Version.h" >"$L/amf-headers-LICENSE.txt"
sed -n '1,30p' "$SRC/nv-codec-headers/include/ffnvcodec/dynlink_loader.h" >"$L/nv-codec-headers-LICENSE.txt"
# mingw-w64 runtime (winpthreads) linked statically.
cp /usr/share/doc/mingw-w64-common/copyright "$L/mingw-w64-copyright.txt" 2>/dev/null || true

cat >"$OUT/versions.txt" <<EOF
mpv $MPV (-Dgpl=false, LGPL-2.1-or-later)
FFmpeg $FFMPEG (LGPL-2.1-or-later, no --enable-gpl, no --enable-nonfree)
libplacebo $LIBPLACEBO
libass $LIBASS
dav1d $DAV1D
shaderc $SHADERC
SPIRV-Cross $SPIRV_CROSS
Little-CMS $LCMS2
zlib-ng $ZLIB_NG
nv-codec-headers $NV_HEADERS
AMF headers $AMF
libiconv $ICONV
FreeType $FREETYPE
FriBidi $FRIBIDI
HarfBuzz $HARFBUZZ
Toolchain: $($CC --version | head -1)
EOF

cp "$OUT/versions.txt" "$L/versions.txt"

# Corresponding sources (LGPL section 6) with the build script, without build
# trees or git history. Publish this archive with every release.
cp "$0" "$WORK/build-lgpl.sh"
cp "$OUT/versions.txt" "$WORK/versions.txt"
tar -C "$WORK" --exclude=_build --exclude=.git -cJf "$OUT/sources.tar.xz" src build-lgpl.sh versions.txt
cp "$0" "$OUT/build-lgpl.sh"

# Install into the repository this script belongs to.
REPO=$(cd "$(dirname "$0")/../.." && pwd)
if [ -d "$REPO/src-tauri" ]; then
    cp "$OUT/libmpv-2.dll" "$REPO/src-tauri/lib/libmpv-2.dll"
    rm -rf "$REPO/src-tauri/licenses/libmpv"
    mkdir -p "$REPO/src-tauri/licenses"
    cp -r "$L" "$REPO/src-tauri/licenses/libmpv"
    echo "Installed into $REPO/src-tauri (lib/libmpv-2.dll, licenses/libmpv/)"
fi
echo "Done: $OUT"
ls -la "$OUT"

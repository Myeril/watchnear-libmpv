# watchnear-libmpv

The LGPL build of **libmpv** used by [WatchNear](https://myeril.com), a video player with synchronized watch sessions by Myeril.

WatchNear loads `libmpv-2.dll`, a single DLL that bundles mpv, FFmpeg and their dependencies, all built without any GPL code. This repository provides, as required by the GNU LGPL 2.1:

- the **exact source code** of every library inside the DLL, for each WatchNear release (`sources.tar.xz` in [Releases](../../releases));
- the **build script** used to produce the DLL from those sources (`build-lgpl.sh`);
- the **license texts** of every component (`licenses/`).

## Contents of the DLL

See `versions.txt` for the exact versions.

| Component | License |
|---|---|
| mpv (libmpv), built with `-Dgpl=false` | LGPL-2.1-or-later |
| FFmpeg, built without `--enable-gpl` and `--enable-nonfree` | LGPL-2.1-or-later |
| libplacebo, FriBidi, libiconv | LGPL-2.1-or-later |
| libass | ISC |
| dav1d | BSD-2-Clause |
| FreeType | FTL |
| HarfBuzz, Little-CMS, nv-codec-headers, AMF headers | MIT |
| zlib-ng | Zlib |
| shaderc, glslang, SPIRV-Tools, SPIRV-Headers, SPIRV-Cross | Apache-2.0 / BSD-3-Clause |
| mingw-w64 runtime (winpthreads) | MIT / ZPL-2.1 |

## Rebuilding

The script cross-compiles for Windows x64 from Linux (tested on WSL Ubuntu 24.04).

```bash
sudo apt install mingw-w64 nasm pkg-config python3-venv ninja-build cmake git wget xz-utils autoconf automake libtool gperf
bash build-lgpl.sh            # work directory: ~/watchnear-libmpv
```

The first build takes about 20 minutes. The result is in `~/watchnear-libmpv/out/`: `libmpv-2.dll`, `licenses/`, `versions.txt` and `sources.tar.xz`. The script stops if FFmpeg is not configured as LGPL, if the DLL contains GPL code, or if it depends on a DLL other than Windows system libraries.

`sources.tar.xz`, attached to each release, holds the exact source trees used for that WatchNear version (`src/`), along with the script and `versions.txt`.

## Replacing the DLL in WatchNear

You may modify these libraries and use your own build with WatchNear: replace `libmpv-2.dll` in WatchNear's installation folder (by default `%LOCALAPPDATA%\WatchNear`) with your build, keeping the same file name. Your DLL must expose the libmpv client API (`libmpv-2`).

## License

Each library keeps its own license (see `licenses/`). The build script `build-lgpl.sh` is provided under the same terms as the libraries it builds, LGPL-2.1-or-later.

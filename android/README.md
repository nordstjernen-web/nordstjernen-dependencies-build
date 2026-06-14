# Nordstjernen Android prebuilt dependencies

This directory builds and publishes a **prebuilt native dependency sysroot** for
the Nordstjernen browser engine's Android port. The engine's own build script
(`android/scripts/build-deps.sh`, in the
[`nordstjernen-web/nordstjernen`](https://github.com/nordstjernen-web/nordstjernen)
repo) expects a ready-made sysroot at:

```
$NORDSTJERNEN_ANDROID_SYSROOT/<abi>/{include,lib,lib/pkgconfig}
```

Building that sysroot by hand is slow and blocks CI from producing real
(non-stub) APKs. The GitHub Actions workflow here cross-compiles **all** the
third-party native libraries for **every** target ABI and uploads them as
downloadable artifacts, so CI and local developers can consume prebuilt
binaries instead of compiling the world.

## Targets

| Setting        | Value                                            |
|----------------|--------------------------------------------------|
| NDK            | `27.3.13750724` (r27)                            |
| ABIs           | `arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86`      |
| API / minSdk   | `35`                                             |
| Page size      | every link passes `-Wl,-z,max-page-size=16384` (16 KB pages, Google Play) |
| Build systems  | Meson + Ninja + pkg-config, CMake ≥ 3.22 where required |

## What gets built

Pinned versions and verified checksums live in
[`deps/manifest.txt`](deps/manifest.txt). The stack is built in dependency
order:

- **Base:** zlib, libffi, pcre2, expat
- **GLib stack:** glib (glib-2.0, gobject-2.0, gio-2.0, gmodule-2.0), plus
  glib's bundled `proxy-libintl` meson subproject for `libintl` (see note below)
- **Text / font:** freetype2, libpng, harfbuzz, fontconfig, pixman, fribidi
  (freetype↔harfbuzz is a cycle: freetype is built once *without* harfbuzz,
  then harfbuzz, then freetype is rebuilt *with* harfbuzz)
- **Graphics:** cairo, pango, pangocairo
- **Network:** OpenSSL (libcrypto + libssl), nghttp2, brotli (libcurl decodes
  `Content-Encoding: br`), libcurl (HTTP/2 + brotli)
- **Misc:** sqlite3, uchardet, libpsl, libwebp
- **On-device inference:** llama.cpp (libllama + ggml), built with
  `GGML_NATIVE=OFF`/`GGML_OPENMP=OFF` for a clean NDK cross-compile

> `lexbor`, `quickjs-ng`, `WAMR` and `Wuffs` are **not** built here — they are
> vendored in the engine tree and compiled together with the engine.

### Android libc (bionic) notes

The `API / minSdk` level above is not arbitrary — glib drags in two libc
features that Android's bionic only provides on newer API levels:

- **`iconv`** — `iconv_open`/`iconv`/`iconv_close` were added to bionic at
  **API 28**. Below that, glib's meson configure aborts with
  `Dependency "iconv" not found`.
- **`libintl` / gettext** — bionic ships **no** gettext at any API level. glib
  always needs `libintl`, so it falls back to its bundled **`proxy-libintl`**
  meson subproject (a tiny stub that satisfies the gettext symbols). Because
  these builds run meson with `--wrap-mode nodownload` (offline / reproducible),
  the pinned `proxy-libintl` source is **vendored into glib's
  `subprojects/proxy-libintl-0.5/`** by `dep_glib` before configuring, rather
  than downloaded from wrapdb. Its version and sha256 are pinned in
  `deps/manifest.txt` and match glib's own `subprojects/proxy-libintl.wrap`.

## Consuming the prebuilt sysroot (the fast path)

Successful builds on `main` publish the sysroots as assets on a **public GitHub
Release** under the rolling tag
[`sysroot-latest`](https://github.com/nordstjernen-web/nordstjernen-android/releases/tag/sysroot-latest):

```
nordstjernen-android-sysroot-arm64-v8a.tar.gz
nordstjernen-android-sysroot-armeabi-v7a.tar.gz
nordstjernen-android-sysroot-x86_64.tar.gz
nordstjernen-android-sysroot-x86.tar.gz
SHA256SUMS
manifest.txt
```

Because the release is public, no authentication (and no `gh` CLI) is needed —
just `curl`, `tar` and `sha256sum`.

1. **Download** and lay the sysroots out (downloads all four ABIs and verifies
   each against `SHA256SUMS`):

   ```bash
   export NORDSTJERNEN_ANDROID_SYSROOT="$HOME/.cache/nordstjernen-android-sysroot"
   android/scripts/fetch-prebuilt-deps.sh --sysroot "$NORDSTJERNEN_ANDROID_SYSROOT"
   ```

   Use `--abi arm64-v8a` for a single ABI, or `--tag <tag>` to pin a specific
   release. You can also just download a `*.tar.gz` from the Releases page and
   `tar -xzf` it into `$NORDSTJERNEN_ANDROID_SYSROOT` (each archive already
   carries a top-level `<abi>/` directory).

2. **Point the engine build at it** and run the engine's dependency script as
   usual — it will find the prebuilt libraries and skip compilation:

   ```bash
   export NORDSTJERNEN_ANDROID_SYSROOT="$HOME/.cache/nordstjernen-android-sysroot"
   # in the nordstjernen engine repo:
   android/scripts/build-deps.sh
   ```

## Building the sysroot locally (the slow path)

If you need to build the sysroot yourself (e.g. to add a dependency or test a
version bump):

```bash
export ANDROID_NDK_HOME=/path/to/ndk/27.3.13750724
export NORDSTJERNEN_ANDROID_SYSROOT="$PWD/sysroot"

# Build one ABI (repeat for the others, or loop):
android/scripts/build-android-deps.sh arm64-v8a
android/scripts/build-android-deps.sh armeabi-v7a
android/scripts/build-android-deps.sh x86_64
android/scripts/build-android-deps.sh x86
```

Requirements: NDK r27, `meson` (≥ 1.5), `ninja`, `cmake` (≥ 3.22),
`pkg-config`, `python3`, and the usual autotools for the few autotools-based
deps (`autoconf`, `automake`, `libtool`, `gperf`).

Useful flags:

- `--sysroot DIR` — install base (default `$NORDSTJERNEN_ANDROID_SYSROOT`).
- `--only name1,name2` — build only some deps (for debugging a single library).

Meson cross-files are regenerated automatically per build, but you can also
emit them standalone:

```bash
android/scripts/gen-cross-files.sh            # all ABIs
android/scripts/gen-cross-files.sh arm64-v8a  # one ABI
```

## Layout

```
android/
├── cross/                     # generated Meson cross-files (<abi>.cross)
├── deps/
│   └── manifest.txt           # pinned versions + sha256 + URLs
└── scripts/
    ├── lib/common.sh          # shared: ABI map, NDK detection, build helpers
    ├── gen-cross-files.sh     # write Meson cross-files for the NDK toolchain
    ├── build-android-deps.sh  # cross-compile the full stack for one ABI
    └── fetch-prebuilt-deps.sh # download the CI sysroot artifact
```

## Reproducibility

Every dependency is pinned to an exact version in `deps/manifest.txt`, and each
downloaded tarball's SHA-256 is verified before extraction. Bumping a version
means editing the manifest and updating its checksum; the source-tarball cache
key is derived from the manifest, so a bump invalidates the cache automatically.

## Build speed

`build-android-deps.sh` prefetches **all** source tarballs in parallel (a few at
a time, `PREFETCH_JOBS=4` by default) before the serial compile loop, so network
latency overlaps instead of stalling each step. This is independent of the CI
caches — a completely cold build still benefits. The four ABIs build as parallel
matrix jobs, and `ccache` only accelerates *reruns*.

## CI triggers

The `build-deps` workflow runs on:

- `workflow_dispatch` (manual),
- `push` touching `android/deps/**`, `android/scripts/**`, `android/cross/**`
  or the workflow file,
- a nightly `schedule` (04:17 UTC) to catch toolchain / runner drift.

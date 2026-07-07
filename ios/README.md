# Nordstjernen iOS prebuilt dependencies

This directory builds and publishes a **prebuilt native dependency sysroot** for
the Nordstjernen browser engine's iOS port. The engine's own build script
(`ios/scripts/build-deps.sh`, in the
[`nordstjernen-web/nordstjernen`](https://github.com/nordstjernen-web/nordstjernen)
repo) expects a ready-made sysroot at:

```
$NORDSTJERNEN_IOS_SYSROOT/<platform>/{include,lib,lib/pkgconfig}
```

Building that sysroot by hand is slow and blocks CI from producing real
(non-stub) app bundles. The GitHub Actions workflow here cross-compiles **all**
the third-party native libraries for **every** target platform and uploads them
as downloadable artifacts, so CI and local developers can consume prebuilt
binaries instead of compiling the world.

## Status

**This iOS infrastructure is newly authored and has not yet completed a green CI
run.** It mirrors the battle-tested Android tooling in
[`../android`](../android) line for line, adapted to the Xcode/iOS toolchain, but
the recipes have not been verified end-to-end on a macOS runner yet. Treat the
published sysroot (once it exists) as **experimental** until the
[`build-ios-deps`](../.github/workflows/build-ios-deps.yml) workflow has a
recorded successful run. Expect to iterate on individual dependency recipes as
real build logs come in.

## Targets

| Setting            | Value                                            |
|--------------------|--------------------------------------------------|
| Toolchain          | Xcode clang (resolved via `xcrun`)               |
| Platforms          | `device` (`iphoneos`), `simulator` (`iphonesimulator`) |
| Architecture       | `arm64` (both platforms)                         |
| Deployment target  | iOS `15.0`                                        |
| Linkage            | **static** (`.a`); no bitcode                    |
| Build systems      | Meson + Ninja + pkg-config, CMake ≥ 3.22 where required |

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

> `lexbor`, `quickjs-ng`, `WAMR` and `Wuffs` are **not** built here — they are
> vendored in the engine tree and compiled together with the engine.
>
> `llama.cpp` is **not** built for iOS: on-device inference is not part of the
> mobile iOS engine, so it is omitted from the manifest and build plan (it *is*
> built for Android).

### Apple libc notes

Apple's C library ships **no** gettext at any version, so glib always needs an
external `libintl`. It falls back to its bundled **`proxy-libintl`** meson
subproject (a tiny stub that satisfies the gettext symbols). Because these
builds run meson with `--wrap-mode nodownload` (offline / reproducible), the
pinned `proxy-libintl` source is **vendored into glib's
`subprojects/proxy-libintl-0.5/`** by `dep_glib` before configuring, rather than
downloaded from wrapdb. Its version and sha256 are pinned in
[`deps/manifest.txt`](deps/manifest.txt) and match glib's own
`subprojects/proxy-libintl.wrap`.

## Consuming the prebuilt sysroot (the fast path)

Successful builds on `main` publish the sysroots as assets on a **public GitHub
Release** under the rolling tag
[`ios-sysroot-latest`](https://github.com/nordstjernen-web/nordstjernen-android/releases/tag/ios-sysroot-latest):

```
nordstjernen-ios-sysroot-device.tar.gz
nordstjernen-ios-sysroot-simulator.tar.gz
SHA256SUMS
manifest.txt
```

Because the release is public, no authentication (and no `gh` CLI) is needed —
just `curl`, `tar` and a sha256 tool (`sha256sum` or macOS's `shasum`).

1. **Download** and lay the sysroots out (downloads both platforms and verifies
   each against `SHA256SUMS`):

   ```bash
   export NORDSTJERNEN_IOS_SYSROOT="$HOME/.cache/nordstjernen-ios-sysroot"
   ios/scripts/fetch-prebuilt-deps.sh --sysroot "$NORDSTJERNEN_IOS_SYSROOT"
   ```

   Use `--platform device` for a single platform, or `--tag <tag>` to pin a
   specific release. You can also just download a `*.tar.gz` from the Releases
   page and `tar -xzf` it into `$NORDSTJERNEN_IOS_SYSROOT` (each archive already
   carries a top-level `<platform>/` directory).

2. **Point the engine build at it** and run the engine's dependency script as
   usual — it will find the prebuilt libraries and skip compilation:

   ```bash
   export NORDSTJERNEN_IOS_SYSROOT="$HOME/.cache/nordstjernen-ios-sysroot"
   # in the nordstjernen engine repo:
   ios/scripts/build-deps.sh
   ```

## Building the sysroot locally (the slow path)

If you need to build the sysroot yourself (e.g. to add a dependency or test a
version bump), on a macOS host with Xcode installed:

```bash
export NORDSTJERNEN_IOS_SYSROOT="$PWD/sysroot"

# Build one platform (repeat for the other, or loop):
ios/scripts/build-ios-deps.sh device
ios/scripts/build-ios-deps.sh simulator
```

Requirements: Xcode with the iOS SDK (`xcrun` on `PATH`), `meson` (≥ 1.5),
`ninja`, `cmake` (≥ 3.22), `pkg-config`, `python3`, and the usual autotools for
the few autotools-based deps (`autoconf`, `automake`, `libtool`, `gperf`).
Install the Homebrew tooling with:

```bash
brew install meson ninja pkg-config cmake autoconf automake libtool gperf nasm
```

Useful flags:

- `--sysroot DIR` — install base (default `$NORDSTJERNEN_IOS_SYSROOT`).
- `--only name1,name2` — build only some deps (for debugging a single library).

Meson cross-files are regenerated automatically per build, but you can also
emit them standalone:

```bash
ios/scripts/gen-cross-files.sh            # both platforms
ios/scripts/gen-cross-files.sh device     # one platform
```

## Layout

```
ios/
├── cross/                     # generated Meson cross-files (<platform>.cross)
├── deps/
│   └── manifest.txt           # pinned versions + sha256 + URLs
└── scripts/
    ├── lib/common.sh          # shared: platform map, toolchain detection, build helpers
    ├── gen-cross-files.sh     # write Meson cross-files for the Xcode toolchain
    ├── build-ios-deps.sh      # cross-compile the full stack for one platform
    └── fetch-prebuilt-deps.sh # download the CI sysroot artifact
```

## Reproducibility

Every dependency is pinned to an exact version in `deps/manifest.txt`, and each
downloaded tarball's SHA-256 is verified before extraction. Bumping a version
means editing the manifest and updating its checksum; the source-tarball cache
key is derived from the manifest, so a bump invalidates the cache automatically.

## Build speed

`build-ios-deps.sh` prefetches **all** source tarballs in parallel (a few at a
time, `PREFETCH_JOBS=4` by default) before the serial compile loop, so network
latency overlaps instead of stalling each step. This is independent of the CI
caches — a completely cold build still benefits. The two platforms build as
parallel matrix jobs, and `ccache` only accelerates *reruns*.

## CI triggers

The `build-ios-deps` workflow runs on:

- `workflow_dispatch` (manual),
- `push` touching `ios/deps/**`, `ios/scripts/**`, `ios/cross/**` or the
  workflow file,
- a nightly `schedule` (04:47 UTC) to catch toolchain / runner drift.

The build matrix runs on `macos-14` (Apple Silicon) runners so the iOS SDK and
`xcrun` are available; the release-publishing job runs on Linux.

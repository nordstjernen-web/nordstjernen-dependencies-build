# nordstjernen-dependencies-build

Mobile build support for the [Nordstjernen](https://github.com/nordstjernen-web/nordstjernen)
web browser engine.

This repository hosts the CI/CD that builds Nordstjernen's native third-party
dependencies — cross-compiled for every **Android** ABI and for **iOS** (device
+ simulator), and a development **GTK 4** for desktop **Linux** — and publishes
them as downloadable **prebuilt binaries**, so the engine's build scripts (and
local developers) can consume them instead of compiling from scratch.

- **Android:** `android/` → `sysroot-latest` release, consumed by nordstjernen's
  `android/scripts/build-deps.sh`.
- **iOS:** `ios/` → `ios-sysroot-latest` release, consumed by nordstjernen's
  `ios/scripts/build-engine.sh`. **Newly authored — not yet verified by a green
  CI run** (see [`ios/README.md`](ios/README.md)).
- **Linux:** `linux/` → `linux-gtk-latest` release, a bleeding-edge dev GTK 4
  overlay for testing the desktop engine on Ubuntu (see
  [`linux/README.md`](linux/README.md)).

On **mobile** the engine drops GTK 4, librsvg and gdk-pixbuf, so the Android/iOS
dependency set is the GLib/cairo/pango graphics stack plus the network, storage
and image libraries — all plain C, no Rust toolchain. The **desktop Linux** port
*does* use GTK 4: it runs on a normal Ubuntu with a full system graphics stack,
so the Linux build compiles only GTK itself (against the system libraries)
rather than the whole stack.

## Libraries built

Both sysroots build the same stack from pinned, checksummed upstream release
tarballs. Versions below are the current pins; the authoritative source is each
platform's manifest
([`android/deps/manifest.txt`](android/deps/manifest.txt),
[`ios/deps/manifest.txt`](ios/deps/manifest.txt)).

| Group | Library | Version | Purpose |
|-------|---------|---------|---------|
| Base | zlib | 1.3.2 | deflate/gzip |
| Base | libffi | 3.5.2 | GObject closures |
| Base | pcre2 | 10.47 | GLib regex |
| Base | expat | 2.8.1 | XML (fontconfig) |
| GLib | glib | 2.88.1 | glib/gobject/gio/gmodule |
| GLib | proxy-libintl | 0.5 | libintl shim (no bionic/Darwin gettext) |
| Text/font | freetype | 2.14.3 | font rasterizer (two-stage with harfbuzz) |
| Text/font | libpng | 1.6.58 | PNG (freetype/cairo) |
| Text/font | harfbuzz | 14.2.1 | text shaping |
| Text/font | fontconfig | 2.18.1 | font discovery |
| Text/font | pixman | 0.46.4 | cairo pixel ops |
| Text/font | fribidi | 1.0.16 | bidi (pango) |
| Graphics | cairo | 1.18.4 | 2D rendering |
| Graphics | pango | 1.57.1 | text layout |
| Network | openssl | 3.6.3 | TLS (curl) |
| Network | nghttp2 | 1.69.0 | HTTP/2 (curl) |
| Network | brotli | 1.2.0 | `Content-Encoding: br` (curl) |
| Network | curl | 8.20.0 | HTTP(S) |
| Misc | sqlite3 | 3.53.2 | storage |
| Misc | uchardet | 0.0.8 | charset detection |
| Misc | libpsl | 0.21.5 | public-suffix / cookie policy |
| Misc | libwebp | 1.6.0 | WebP decode |
| Media | libogg | 1.3.6 | Ogg container framing |
| Media | libvorbis | 1.3.7 | Vorbis audio decode |
| Media | opus | 1.6.1 | Opus audio decode |
| Media | dav1d | 1.5.3 | AV1 video decode (Firefox's decoder) |
| Media | libvpx | 1.16.0 | VP8/VP9 video decode (Android only for now; static) |
| Android only | llama | b9632 | on-device LLM (libllama + ggml) |

`llama.cpp` is built for **Android only** — mobile iOS does not ship the
on-device AI feature. lexbor, QuickJS, WAMR and Wuffs are **not** listed here:
they are vendored in the engine tree and compiled together with the engine, not
as sysroot libraries.

### Media codecs (`<video>` / `<audio>`)

The **Media** group is the open-web decode stack the engine needs to play
`<video>` and `<audio>`. It mirrors the royalty-free codecs Firefox vendors in
mozilla-central (`media/libdav1d`, `media/libvpx`, `media/libopus`,
`media/libvorbis`, `media/libogg`): **dav1d** decodes AV1, **libvpx** decodes
VP8/VP9, **opus** and **libvorbis** decode the two open web audio codecs, and
**libogg** provides Ogg container framing. Firefox pins these to specific
upstream revisions; we pin the latest upstream *stable release* (≥ Firefox's
revision in each case, so its security fixes are carried). Because codecs are the
browser's most hostile-input-exposed surface, each is — like every other
dependency — pinned by exact version and verified `sha256`, and built
decode-oriented (encoders, CLI tools, tests and examples dropped).

`libvpx` is currently built for **Android only** and as a **static** `libvpx.a`
(the one static library in the otherwise-shared Android sysroot): it ships its
own ffmpeg-style `configure` whose Android path is static-oriented, and a static
archive — linked into the engine's own shared objects — sidesteps the shared-lib
`-static`/`-shared` conflict and the 16 KB page-size link flag. iOS `libvpx` is
a tracked follow-up (its `configure` hardcodes the iphoneos SDK and needs
`external_build` + separate simulator handling); on iOS, VP8/VP9 content is far
rarer than the platform's H.264/HLS, so it is lower priority.

#### How the rest of the media surface is covered

Not every format needs a new sysroot library; the full `<video>`/`<audio>`/image
surface is split across three places, and only the gap belongs here:

| Format(s) | Handled by | Where |
|-----------|-----------|-------|
| AV1 · VP8/VP9 video · Opus/Vorbis audio · Ogg | **this repo** (dav1d, libvpx, opus, libvorbis, libogg) | sysroot |
| H.264, HEVC, AAC (patent-encumbered) | the **OS** decoders | Android `MediaCodec`, iOS VideoToolbox/AudioToolbox |
| GIF, PNG, JPEG, BMP images | **Wuffs** (memory-safe) | vendored in the engine tree |
| WebP images | **libwebp** | sysroot (already built) |
| HTML/CSS/JS, MP4/WebM demux glue | **lexbor / QuickJS / engine** | engine tree |

So JPEG/GIF/PNG are deliberately *not* sysroot libraries (Wuffs decodes them in
the engine), and H.264/AAC/HEVC come from the platform — which is why this group
is just the open codecs the OS and Wuffs do not provide.

#### Candidate follow-up libraries (also vendored by Firefox)

Firefox's `media/` tree carries a few more third-party libraries. They are *not*
built here yet, with reasons — this is the shortlist if the engine's media
pipeline grows:

- **libvpx on iOS** (VP8/VP9 decode) — built for Android (above); iOS is the
  remaining half. Its `configure` hardcodes the iphoneos SDK, so a static iOS
  slice needs `external_build` plus separate device/simulator handling — its own
  CI-verified change. Lower priority because iOS video is overwhelmingly
  H.264/HLS via the platform.
- **libnestegg** (WebM demuxer) — small C library that frames VP9/AV1/Opus/Vorbis
  out of `.webm`. Like lexbor/QuickJS/Wuffs it is a candidate for *engine-tree*
  vendoring rather than a sysroot library; where it lands depends on how the
  engine's demux layer is organised.
- **libspeex_resampler · libsoundtouch · kiss_fft** — Web Audio DSP helpers
  (sample-rate conversion, `playbackRate` time-stretch, `AnalyserNode` FFT).
  Small and header-light; typically engine-vendored.
- **libcubeb** — the audio *output* backend. It is platform glue over
  AAudio/AudioUnit, not a decode library, so it belongs to the engine, not here.
- **libaom** (AV1 *encode*) — only needed for sending AV1 over WebRTC; large.
  Playback (decode) is already covered by dav1d.
- **mp4parse** (Rust) — MP4 / fragmented-MP4 demux. Excluded from the mobile
  sysroot by the repo's no-Rust-toolchain-on-mobile policy.

On **desktop Linux** the engine links the distro's media libraries, so the GTK
overlay builds none of the above.

## Quick start

### Android

```bash
# Download the prebuilt sysroot for all ABIs from the public GitHub Release
# (no auth / no `gh` needed -- just curl + tar + sha256sum):
export NORDSTJERNEN_ANDROID_SYSROOT="$HOME/.cache/nordstjernen-android-sysroot"
android/scripts/fetch-prebuilt-deps.sh --sysroot "$NORDSTJERNEN_ANDROID_SYSROOT"
```

Then point the engine's build at `$NORDSTJERNEN_ANDROID_SYSROOT` and run
`build-deps.sh` as usual.

- **Targets:** NDK `27.3.13750724` (r27); ABIs `arm64-v8a`, `x86_64`;
  minSdk 34 (Android 14); 16 KB page size; shared libraries.
- **CI:** [`.github/workflows/build-deps.yml`](.github/workflows/build-deps.yml)
  publishes [`sysroot-latest`](https://github.com/nordstjernen-web/nordstjernen-dependencies-build/releases/tag/sysroot-latest)
  on every successful build of `main`.

### iOS

```bash
export NORDSTJERNEN_IOS_SYSROOT="$HOME/.cache/nordstjernen-ios-sysroot"
ios/scripts/fetch-prebuilt-deps.sh --sysroot "$NORDSTJERNEN_IOS_SYSROOT"
```

Then run nordstjernen's `ios/scripts/build-engine.sh device` (and `simulator`).

- **Targets:** iOS 15+; `arm64` device (`iphoneos`) and `arm64` simulator
  (`iphonesimulator`); static libraries; no bitcode. Built with the Xcode
  toolchain via `xcrun`.
- **CI:** [`.github/workflows/build-ios-deps.yml`](.github/workflows/build-ios-deps.yml)
  publishes `ios-sysroot-latest`. See [`ios/README.md`](ios/README.md) for the
  current (experimental) status.

### Linux (desktop GTK)

```bash
export NORDSTJERNEN_LINUX_SYSROOT="$HOME/.cache/nordstjernen-linux-sysroot"
linux/scripts/fetch-prebuilt-deps.sh --sysroot "$NORDSTJERNEN_LINUX_SYSROOT"
```

Then put the overlay ahead of the system GTK (`PKG_CONFIG_PATH` +
`LD_LIBRARY_PATH`, see [`linux/README.md`](linux/README.md)) and build/run the
desktop engine as usual.

- **Targets:** a development **GTK 4** (`4.23.2`, the series toward GTK 4.24)
  built on Ubuntu against the system graphics stack; `x86_64`, shared libraries.
  Only GTK is built — every other dependency comes from the distro — so consume
  it on the same Ubuntu release it was built on.
- **CI:** [`.github/workflows/build-linux-deps.yml`](.github/workflows/build-linux-deps.yml)
  publishes `linux-gtk-latest` on every successful build of `main`.

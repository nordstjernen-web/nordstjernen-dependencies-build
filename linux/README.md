# Nordstjernen Linux GTK overlay

This directory builds and publishes a bleeding-edge **development GTK 4** for
Ubuntu so the desktop [Nordstjernen](https://github.com/nordstjernen-web/nordstjernen)
engine can be tested against the latest dev GTK without waiting for the distro
to package it.

It is deliberately **different** from the `android/` and `ios/` sysroots. Those
cross-compile the *entire* GLib/cairo/pango stack, because mobile ships no
system libraries. The desktop Linux port, by contrast, runs on a normal Ubuntu
with a full graphics stack already installed — so here we build **only GTK**,
against the system libraries, and overlay it on top of the distro. Everything
else (glib, cairo, pango, gdk-pixbuf, graphene, libepoxy, harfbuzz, wayland, …)
comes from Ubuntu via `apt build-dep gtk4`.

## Targets

| Setting        | Value                                                        |
|----------------|--------------------------------------------------------------|
| GTK            | `4.23.2` (development series toward GTK 4.24)                |
| Build host     | Ubuntu (`ubuntu-26.04` runner)                              |
| Arch           | `x86_64` (shared libraries)                                 |
| Build system   | Meson + Ninja + pkg-config                                  |
| Dependencies   | system libraries from `apt build-dep gtk4` (not rebuilt)    |

GTK 4.23.x is the **unstable development series** leading to GTK 4.24; Ubuntu
packages only stable GTK, which is why it is built from the GNOME source
tarball here.

## What gets built

The pinned version and verified checksum live in
[`deps/manifest.txt`](deps/manifest.txt). Only one thing is built:

- **GTK 4** — `libgtk-4.so` + headers + `gtk4.pc`, with the wayland and X11
  backends and the GL/Vulkan renderers (whatever the system deps support).
  Docs, man pages, demos, the test suite, GObject introspection and the
  GStreamer media backend are disabled to keep the overlay small.

> `lexbor`, `quickjs-ng`, `WAMR` and `Wuffs` are vendored in the engine tree;
> `llama.cpp` is an Android-only feature. None of them are built here.

## Consuming the prebuilt overlay (the fast path)

Successful builds on `main` publish the overlay as an asset on a **public
GitHub Release** under the rolling tag
[`linux-gtk-latest`](https://github.com/nordstjernen-web/nordstjernen-dependencies-build/releases/tag/linux-gtk-latest):

```
nordstjernen-linux-gtk-x86_64.tar.gz
SHA256SUMS
manifest.txt
```

Because the release is public, no authentication (and no `gh` CLI) is needed —
just `curl`, `tar` and `sha256sum`.

1. **Download** and lay the overlay out (verifies against `SHA256SUMS`):

   ```bash
   export NORDSTJERNEN_LINUX_SYSROOT="$HOME/.cache/nordstjernen-linux-sysroot"
   linux/scripts/fetch-prebuilt-deps.sh --sysroot "$NORDSTJERNEN_LINUX_SYSROOT"
   ```

   Use `--tag <tag>` to pin a specific release. You can also just download the
   `*.tar.gz` from the Releases page and `tar -xzf` it into
   `$NORDSTJERNEN_LINUX_SYSROOT` (the archive carries a top-level `x86_64/`
   directory).

2. **Put it ahead of the system GTK** and build/run the engine as usual:

   ```bash
   ARCH=x86_64
   export PKG_CONFIG_PATH="$NORDSTJERNEN_LINUX_SYSROOT/$ARCH/lib/pkgconfig:$PKG_CONFIG_PATH"
   export LD_LIBRARY_PATH="$NORDSTJERNEN_LINUX_SYSROOT/$ARCH/lib:$LD_LIBRARY_PATH"
   export PKG_CONFIG="pkg-config --define-prefix"   # relocate the .pc prefix
   ```

> **Same-distro requirement.** The overlay is only GTK; it links the system
> glib/cairo/pango/… it was compiled against, so consume it on the **same
> Ubuntu release** it was built on.

## Building the overlay locally (the slow path)

On an Ubuntu host:

```bash
sudo apt-get build-dep gtk4          # system GTK build dependencies
sudo apt-get install -y meson ninja-build pkg-config build-essential ccache

export NORDSTJERNEN_LINUX_SYSROOT="$PWD/sysroot"
linux/scripts/build-linux-deps.sh    # defaults to the host arch (x86_64)
```

Useful flags:

- `--sysroot DIR` — install base (default `$NORDSTJERNEN_LINUX_SYSROOT`).
- `--only name1,name2` — build only some deps (there is only `gtk` today).

## Layout

```
linux/
├── deps/
│   └── manifest.txt           # pinned version + sha256 + URL
└── scripts/
    ├── lib/common.sh          # shared: manifest, download/verify, meson build
    ├── build-linux-deps.sh    # build the GTK overlay for the host arch
    └── fetch-prebuilt-deps.sh # download the published overlay
```

## Reproducibility & pinning

The GTK version is pinned to an exact release in `deps/manifest.txt`, and the
downloaded tarball's SHA-256 is verified before extraction. Bumping the version
means editing the manifest and updating its checksum.

Pinning a **new** version whose checksum you do not have yet: set the sha256
field to the literal `AUTO`. CI then downloads the tarball, prints its real
checksum as a `PINME gtk <sha256>` line (and a `::warning::`) and builds without
verifying. Copy that checksum back into the manifest to pin it. `AUTO` is a
pin-time convenience only — the `build-linux-deps` workflow **fails the build on
`main`** if any manifest entry is still `AUTO`, so a real checksum must be in
place before merging.

## CI triggers

The `build-linux-deps` workflow runs on:

- `workflow_dispatch` (manual),
- `push` touching `linux/deps/**`, `linux/scripts/**` or the workflow file,
- a nightly `schedule` (05:17 UTC) to catch toolchain / runner drift.

The build runs on an `ubuntu-26.04` runner; the release-publishing job runs on
`ubuntu-latest` and only on `main` / manual / scheduled runs.

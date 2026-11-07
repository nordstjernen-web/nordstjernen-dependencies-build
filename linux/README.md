# Nordstjernen Linux GTK overlay

This directory builds and publishes a bleeding-edge **development GTK 4** for
Ubuntu so the desktop [Nordstjernen](https://github.com/nordstjernen-web/nordstjernen-browser)
engine can be tested against the latest dev GTK without waiting for the distro
to package it.

It is deliberately **different** from the `android/` and `ios/` sysroots. Those
cross-compile the *entire* GLib/cairo/pango stack, because mobile ships no
system libraries. The desktop Linux port, by contrast, runs on a normal Ubuntu
with a full graphics stack already installed — so here we build **only GTK**
(plus the GLib and Pango releases it requires) against the system libraries,
and overlay it on top of the distro. Everything else (cairo, gdk-pixbuf,
graphene, libepoxy, harfbuzz, wayland, …) comes from Ubuntu via
`apt build-dep gtk4`.

## Targets

| Setting        | Value                                                        |
|----------------|--------------------------------------------------------------|
| GTK            | `4.25.0` (development series toward GTK 4.26)                |
| Build host     | Ubuntu (`ubuntu-26.04` runner)                              |
| Arch           | `x86_64` (shared libraries)                                 |
| Build system   | Meson + Ninja + pkg-config                                  |
| Dependencies   | GLib `2.90.1` + Pango `1.58.2` built into the overlay (GTK 4.25 needs newer than Ubuntu's); the rest from `apt build-dep gtk4` |

GTK 4.25.x is the **unstable development series** leading to GTK 4.26; Ubuntu
packages only stable GTK, which is why it is built from the GNOME source
tarball here.

## What gets built

The pinned versions and verified checksums live in
[`deps/manifest.txt`](deps/manifest.txt). Four things are built, in this order:

- **wayland-protocols** — XML-only; GTK needs a release newer than Ubuntu's.
- **GLib** and **Pango** — GTK 4.25 requires glib ≥ 2.89.3 and pango ≥ 1.58,
  newer than Ubuntu 26.04's 2.88 / 1.57. GLib is ABI-backward-compatible, so the
  system cairo/gdk-pixbuf/harfbuzz keep working once the overlay is first on
  `LD_LIBRARY_PATH`.

- **GTK 4** — `libgtk-4.so` + headers + `gtk4.pc`, with the wayland and X11
  backends and the GL/Vulkan renderers (whatever the system deps support).
  Docs, man pages, demos, the test suite, GObject introspection and the
  GStreamer media backend are disabled to keep the overlay small.

> `lexbor`, `quickjs-ng`, `WAMR` and `Wuffs` are vendored in the engine tree,
> so none of them are built here.

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

> **Same-distro requirement.** The overlay links the system cairo/harfbuzz/
> gdk-pixbuf/… it was compiled against, so consume it on the **same Ubuntu
> release** it was built on.

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
- `--only name1,name2` — build only some deps (`wayland-protocols`, `glib`,
  `pango`, `gtk`).

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

Pinning a **new** version: download the tarball from the upstream URL, verify it
against upstream's own checksum or signature (GNOME publishes a `.sha256sum`
next to every tarball; freedesktop GitLab archives can be cross-checked against
a second packager such as Homebrew), then paste the sha256 into the manifest and
name the cross-check in the commit message. Do **not** copy a checksum from a CI
log: that pins whatever the mirror happened to serve.

The literal `AUTO` checksum still exists as a *local* convenience: the build
script then downloads without verifying and prints the real checksum as a
`PINME gtk <sha256>` line. CI rejects `AUTO` on **every** branch (the
`build-linux-deps` workflow fails before building), so nothing unverified is ever
built by CI, let alone published.

## CI triggers

The `build-linux-deps` workflow runs on:

- `workflow_dispatch` (manual),
- `push` touching `linux/deps/**`, `linux/scripts/**` or the workflow file,
- a nightly `schedule` (05:17 UTC) to catch toolchain / runner drift.

The build runs on an `ubuntu-26.04` runner; the release-publishing job runs on
`ubuntu-latest`. The release-publishing job runs only for commits on `main` (push or a manual
`workflow_dispatch` *from* `main`); a dispatch from any other branch builds but
never publishes, and the nightly schedule builds but does not republish, so the
released assets change only when `main` changes. Every publish uploads the
assets twice: to the rolling `-latest` release (overwritten in place) and to an
immutable per-commit release (`<prefix>-<YYYYMMDD>-<sha>-r<run>`, never updated) that
consumers can pin. Each asset carries a GitHub build-provenance attestation;
`fetch-prebuilt-deps.sh` verifies it with `gh attestation verify` when the `gh`
CLI is installed (set `NORDSTJERNEN_REQUIRE_ATTESTATION=1` to make that
mandatory).

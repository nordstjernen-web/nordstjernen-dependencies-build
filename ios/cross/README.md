# Meson cross-files

This directory holds the per-platform Meson cross-files used to cross-compile
the dependency stack with the Xcode clang toolchain against the iOS SDK.

The files `<platform>.cross` (e.g. `device.cross`, `simulator.cross`) are
**generated** by
[`../scripts/gen-cross-files.sh`](../scripts/gen-cross-files.sh) because they
embed absolute, machine-specific paths (the resolved `xcrun` clang binaries, the
SDK `-isysroot` path, and the install-sysroot `pkg_config_libdir`). They are
therefore git-ignored.

To (re)generate them:

```bash
export NORDSTJERNEN_IOS_SYSROOT="$PWD/sysroot"
ios/scripts/gen-cross-files.sh            # both platforms
ios/scripts/gen-cross-files.sh device     # a single platform
```

`build-ios-deps.sh` regenerates the relevant cross-file automatically before
building, so you normally don't need to run this by hand.

Each generated cross-file pins:

- `[binaries]` — the Xcode clang driver (`clang`/`clang++`), `ar`, `strip`,
  `ranlib`, `nm` (all resolved via `xcrun --find`), and `pkg-config`.
- `[built-in options]` — `-arch arm64 -isysroot <SDK> <min-version>` plus
  `-fPIC -O2` on every compile, the matching flags on every link, and
  `default_library = 'static'`.
- `[properties]` — `pkg_config_libdir` pointing at the per-platform install
  prefix, and `needs_exe_wrapper = true`.
- `[host_machine]` — `system = 'darwin'`, the correct `subsystem` (`ios` or
  `ios-simulator`), and `cpu_family` / `cpu` / `endian` for arm64.

# Security review: nordstjernen-dependencies-build

**Date:** 2026-11-11
**Scope:** every tracked file at commit `fe7897d` (25 files): the three GitHub
Actions workflows, the Bash build / fetch / cross-file scripts under
`android/`, `ios/` and `linux/`, the three manifests, the pip requirements
file and the READMEs.
**Method:** full manual read by a single reviewer. Two findings were
reproduced locally (marked *verified*); the rest are from reading the code.

**Not covered in this pass:**

- The pinned dependency versions were **not** re-checked against CVE
  databases. The review of 2026-11-07 (commits `c8a5ba2`, `1efd2cf`) did that;
  its one open item, the zlib 1.3.2 `gzwrite` CVEs, still stands.
- The action commit SHAs were not checked against the tags named in their
  comments (other repositories are out of reach from this session).
- Repository settings (branch protection, tag rulesets, immutable releases,
  environments) are not visible from the source. Findings 2 and 3 depend on
  them and say so.

The repository has no application code. It downloads pinned tarballs, compiles
them and publishes the native libraries a browser engine links. The findings
are therefore about who can change what consumers download, and how the
published binaries behave on the consumer's machine.

## Summary

| # | Severity | Finding | Where |
|---|----------|---------|-------|
| 1 | Medium | Provenance check is fail-open: a tampered asset takes the "warn and install" path, never the "fatal" one | all three `fetch-prebuilt-deps.sh` |
| 2 | Medium | Attestation is checked against the repository only, not the workflow or branch; "publish only from `main`" is enforced only by YAML that any branch can edit | fetch scripts, `publish` jobs |
| 3 | Medium | Documented Linux setup puts the current directory on the library search path (*verified*) | `linux/scripts/fetch-prebuilt-deps.sh`, `linux/README.md` |
| 4 | Low | "Immutable" release tags are reused when a run is re-run, which is exactly what the workflow tells maintainers to do | all three workflows, tag step |
| 5 | Low | Published binaries embed the CI runner's absolute prefix as their module / config search path | Linux overlay, iOS simulator, OpenSSL |
| 6 | Low | Release tarballs carry the runner's uid/gid and are extracted without ownership or path restrictions | `publish` jobs, fetch scripts |
| 7 | Low | Android libraries built by Meson, Autotools, OpenSSL and libvpx get no `_FORTIFY_SOURCE`; CI does not assert it | `android/scripts/gen-cross-files.sh`, `android/scripts/lib/common.sh` |
| 8 | Low | The third-party release action runs in a job that can also mint attestations | `publish` jobs |
| 9 | Low | iOS build tools come unpinned from Homebrew, contradicting the README; NDK install errors are hidden | `build-ios-deps.yml`, `build-deps.yml` |
| 10 | Low | Published builds restore a compiler cache from earlier runs | all three workflows |
| 11 | Info | Smaller hardening notes (sqlite, curl FTP, masked strip errors, `AUTO` path) | various |

No critical or high-severity issue was found. Nothing here is exploitable by
an anonymous outsider against the pipeline itself: findings 1, 2 and 4 need
write access to the repository or a stolen token, and 3, 5 and 6 need a local
foothold on the consumer's machine.

## Findings

### 1. Provenance verification is fail-open (Medium)

`android/scripts/fetch-prebuilt-deps.sh:67-90` (same code in `ios/` and
`linux/`).

`SHA256SUMS` is downloaded from the same release as the tarball, so it only
detects a corrupted download. The attestation is the only check that ties an
asset to this repository's build, and it is skipped with a warning when:

- `gh` is not installed or not logged in, or
- the attestations API returns no entry for the file's digest.

The README says "an attestation that fails to verify is always fatal". That
branch cannot be reached by an attacker. Anyone who replaces a tarball (and
`SHA256SUMS` with it) produces a new digest, GitHub has no attestation for
that digest, `count` is `0`, and the script prints a warning and installs the
file. The default tag is the rolling `*-latest` release, which is overwritten
in place by design.

So with default settings, whoever can write to the release controls the native
code the engine links, and the only signal is a yellow line in a build log.

**Fix.**

- Make `NORDSTJERNEN_REQUIRE_ATTESTATION=1` the default and offer an explicit
  opt-out (`NORDSTJERNEN_ALLOW_UNATTESTED=1`) for the Sigstore-outage case.
- Add `--sha256 <hash>` (or read a lock file) so a consumer can pin the
  expected `SHA256SUMS` digest out of band. The README says the engine already
  keeps that hash in `sysroot.lock`; the fetch script has no way to take it.

### 2. Attestation and publishing are not bound to `main` (Medium)

`fetch-prebuilt-deps.sh:87` runs `gh attestation verify "$file" --repo "$REPO"`
with nothing else. That accepts an attestation signed by **any** workflow on
**any** branch of the repository.

The `publish` job's guard (`build-deps.yml:241-243`,
`github.ref == 'refs/heads/main'`) is a line in a workflow file. Each workflow
triggers on `push` to any branch when the workflow file itself changes. A
contributor who can push a branch, but cannot merge to `main`, can push an
edited workflow that drops the guard, requests `contents: write`,
`id-token: write` and `attestations: write`, and uploads a modified tarball to
`sysroot-latest` with a valid attestation. Even a consumer running with
`NORDSTJERNEN_REQUIRE_ATTESTATION=1` accepts it.

Whether this works today depends on settings I cannot see: a tag ruleset on
the release tags, or a protected environment on the publish job, would stop
it. Nothing in the source sets either up.

**Fix.**

- In the fetch scripts, pin the signer and the ref:

  ```bash
  gh attestation verify "$file" --repo "$REPO" \
    --signer-workflow "$REPO/.github/workflows/build-deps.yml" \
    --source-ref refs/heads/main \
    --deny-self-hosted-runners
  ```

  (use the matching workflow file for iOS and Linux).
- Put the `publish` jobs in a GitHub environment restricted to `main`, and add
  tag rulesets so only that path can create or move `sysroot-*`,
  `ios-sysroot-*` and `linux-gtk-*`.

### 3. Documented Linux setup adds the current directory to the library path (Medium, verified)

`linux/scripts/fetch-prebuilt-deps.sh:121-122` prints, and
`linux/README.md:81-82` documents:

```bash
export PKG_CONFIG_PATH="$NORDSTJERNEN_LINUX_SYSROOT/$ARCH/lib/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$NORDSTJERNEN_LINUX_SYSROOT/$ARCH/lib:$LD_LIBRARY_PATH"
```

`LD_LIBRARY_PATH` is unset on a stock Ubuntu session, so this yields a value
ending in `:`. glibc treats an empty entry as the current directory. Any
program started from that shell then loads shared libraries from whatever
directory it happens to be in, ahead of the system ones.

Reproduced here: with `LD_LIBRARY_PATH="/nonexistent/lib:"` and a planted
`libcurl.so.4` in the working directory, `curl` loaded the planted file;
without the trailing colon it did not.

A developer who follows the README and then runs the engine (or anything else)
from a cloned repository, an extracted download or `/tmp` executes code from a
library placed there.

`linux/scripts/lib/common.sh:210-212` already does this correctly. Use the same
form in the printed text and the README:

```bash
export LD_LIBRARY_PATH="$NORDSTJERNEN_LINUX_SYSROOT/$ARCH/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH="$NORDSTJERNEN_LINUX_SYSROOT/$ARCH/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
```

### 4. "Immutable" release tags are reused on a re-run (Low)

`build-deps.yml:330` (and the same step in the other two workflows) builds the
tag from the date, the commit and `GITHUB_RUN_NUMBER`. The comment and the
README say a re-run "creates a new release".

`GITHUB_RUN_NUMBER` does not change when a run is re-run; only
`GITHUB_RUN_ATTEMPT` does. On the same UTC day a re-run computes the same tag,
and `softprops/action-gh-release` updates the existing release and replaces
its assets. The workflow's own warning for an unattested release
(`build-deps.yml:326`) tells the maintainer to "re-run this job", which is
this case.

I checked that `tar -czf` gives identical bytes for identical input, so the
replaced tarball may well hash the same. That is luck, not a guarantee: it
depends on the artifact download preserving file times. And the release stays
writable by any token with `contents: write` regardless.

**Fix.** Append `-a${GITHUB_RUN_ATTEMPT}` to the tag, and turn on GitHub's
immutable releases for the repository so a published release cannot be
changed by anyone.

### 5. Published binaries embed the CI runner's paths (Low)

The Linux overlay is configured with
`--prefix /home/runner/work/nordstjernen-dependencies-build/nordstjernen-dependencies-build/sysroot/x86_64`
(`build-linux-deps.yml:118`, `linux/scripts/lib/common.sh:254-261`) and then
unpacked somewhere else on the consumer's machine. On Linux, GLib and GTK do
not relocate: the GIO module directory (`<prefix>/lib/gio/modules`), GTK's
module directories (`<prefix>/lib/gtk-4.0/...`), the schema and data
directories are compiled in as absolute paths. GIO and GTK `dlopen` what they
find there.

On the consumer's machine those paths point into `/home/runner/`. On a normal
desktop that directory does not exist and nothing happens. On a machine that
has a `runner` account (the usual name for a self-hosted Actions runner, which
runs other people's CI jobs) that account can create the directory and plant a
module that loads into any other user's engine process.

The same applies to the iOS **simulator** sysroot (simulator processes see the
Mac's file system; the baked prefix is under `/Users/runner/`) and to
OpenSSL's `OPENSSLDIR` in both mobile builds (`openssl.cnf` is read from
`<prefix>/ssl`). On real Android and iOS devices the paths are unreachable.

I did not build the overlay to inspect the strings; `strings libgio-2.0.so |
grep /home/runner` on a published asset will confirm it.

**Fix.** Build with a fixed prefix that only root can create, for example
`/opt/nordstjernen/gtk`, and install with `DESTDIR`. For OpenSSL pass
`--openssldir=` a path the app controls or one that can never exist. Have the
README tell Linux consumers to set `GIO_MODULE_DIR`, `GTK_PATH`,
`GSETTINGS_SCHEMA_DIR` and `XDG_DATA_DIRS` to the overlay.

### 6. Tarball ownership and extraction (Low)

The `publish` jobs create archives with plain `tar -czf`
(`build-deps.yml:271`), which records the runner's uid/gid (1001). The fetch
scripts extract with plain `tar -xzf` (`fetch-prebuilt-deps.sh:111`). Run as
root, which is normal in a Docker build, `tar` restores that ownership, so the
installed libraries belong to uid 1001. If that uid exists on the machine or
in the image, that user can rewrite the libraries the engine links.

Extraction also trusts the archive layout. GNU tar and bsdtar refuse absolute
paths and `..` by default, so this is defense in depth, but given finding 1
the archive is less trusted than the script assumes.

**Fix.** Create with `--owner=0 --group=0 --numeric-owner` (and `--sort=name
--mtime=@$SOURCE_DATE_EPOCH` to make the archive reproducible, which also
helps finding 4). Extract with `--no-same-owner --no-same-permissions`, and
reject archives whose member list contains anything not under `<abi>/`.

### 7. No `_FORTIFY_SOURCE` on most Android libraries (Low)

NDK clang does not define `_FORTIFY_SOURCE` by itself. The NDK's CMake
toolchain file adds it, so the CMake-built libraries have it. The Meson
cross-file (`android/scripts/gen-cross-files.sh:48-49`: `-fPIC -DANDROID`),
the Autotools wrapper (`android/scripts/lib/common.sh:348-349`), OpenSSL and
libvpx do not.

That leaves glib, freetype, harfbuzz, fontconfig, cairo, pango, pixman,
fribidi, dav1d, libvpx, OpenSSL, sqlite, libffi and libpsl without fortified
libc calls. Fonts and video are the parts of a browser that parse the most
hostile input. The 2026-11-07 review raised hardening flags as a note; RELRO
and BIND_NOW were then made explicit and asserted in CI, fortify was not.

**Fix.** Add `-D_FORTIFY_SOURCE=2` to `c_args` / `cpp_args` in the cross-file,
to `CFLAGS` / `CXXFLAGS` in `build_autotools`, and to the OpenSSL and libvpx
configure lines. Consider `-mbranch-protection=standard` for arm64. Add a CI
assertion (for example, that each `.so` imports at least one `__*_chk`
symbol).

### 8. Release action shares a job with attestation rights (Low)

The `publish` job grants `contents: write`, `id-token: write` and
`attestations: write` to every step (`build-deps.yml:244-247`), including
`softprops/action-gh-release`, the one action not maintained by GitHub. It is
pinned to a commit SHA, which is the right control. If that commit were ever
malicious, it could both replace assets and sign a valid attestation for them.

**Fix.** Split the job: one that packages and attests (`id-token`,
`attestations`), and one that uploads (`contents: write` only) from the first
job's artifact. Or replace the action with `gh release upload`.

### 9. Unpinned build tools on iOS; hidden NDK install errors (Low)

- `build-ios-deps.yml:53-66` installs meson, ninja, cmake, bash and others
  with `brew update && brew install`, so the iOS sysroot is built with
  whatever Homebrew serves that day. `.github/requirements-build.txt` and the
  README state that meson and ninja are hash-pinned from PyPI; that is true
  for Android and Linux only. The requirements file already lists macOS
  wheels. The earlier review left this open.
- `build-deps.yml:74-75` runs `sdkmanager` with all output discarded and
  `|| true`, and `require_ndk` only warns when the NDK version differs from
  the pin (`android/scripts/lib/common.sh:80-81`). The directory check catches
  a missing NDK, not a wrong one.

**Fix.** Use `pip install --require-hashes` in the iOS workflow as well. Make
the NDK version mismatch fatal when `CI` is set.

### 10. Compiler cache reused in published builds (Low)

All three workflows restore `ccache` with prefix `restore-keys`, and
`cancel-in-progress` plus nightly schedules keep that cache warm. A published
library can therefore contain objects compiled in an earlier run. Cache scope
limits this to runs on `main`, and the inputs are hash-pinned, so it needs an
earlier compromised run. It does let one bad run persist into later
releases, and it means the attestation describes a build that did not compile
everything it shipped.

**Fix.** Skip the ccache restore when the run will publish (`github.ref ==
'refs/heads/main'` and not a schedule).

### 11. Notes (Info)

- **sqlite.** Neither build disables extension loading or sets
  `SQLITE_DQS=0`; the iOS build enables FTS5 and RTREE
  (`ios/scripts/build-ios-deps.sh:232-235`). If web content can ever influence
  SQL, add `-DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DQS=0`.
- **curl.** Plain `ftp://` is compiled in on purpose. NTLM and other auth
  schemes are left at defaults; `-DCURL_DISABLE_NTLM=ON` and
  `-DCURL_DISABLE_KERBEROS_AUTH=ON` would trim more unused code.
- **`strip_install`** hides all errors (`|| true`), so a failed strip ships
  unstripped libraries without notice. Not a security problem by itself.
- **Linux `AUTO` checksums.** The script still accepts an unverified download
  (`linux/scripts/lib/common.sh:124-151`); only the workflow step rejects it,
  and that step is in the same editable YAML as finding 2. Consider refusing
  `AUTO` in the script whenever `CI` is set.
- **Partial uploads.** The rolling release is replaced asset by asset, so a
  fetch during a publish can see a new tarball with an old `SHA256SUMS`. It
  fails closed.

## What is already in good shape

- Workflow tokens are read-only by default; no `pull_request` or
  `pull_request_target` trigger; no untrusted `github.event.*` value reaches a
  `run:` block; checkout does not persist credentials.
- All actions are pinned to commit SHAs; meson and ninja are hash-pinned on
  Android and Linux.
- Every source tarball is fetched over HTTPS only (redirects included),
  verified against a pinned SHA-256 before extraction and re-verified from
  cache on every run. Meson wrap downloads are off.
- libcurl's protocol list is restricted and asserted in CI; Android libraries
  are checked for RELRO, BIND_NOW, no text relocations and 16 KB alignment.
- The fetch scripts validate the ABI / platform / arch before it reaches
  `rm -rf`, use `mktemp -d` with a cleanup trap, and check the hash before
  extracting.

## Suggested order

1. Finding 3: two-line documentation fix, removes a real local code-execution
   path.
2. Findings 1 and 2 together: they decide whether the attestation means
   anything to a consumer.
3. Finding 4 and the repository settings (immutable releases, tag rulesets,
   publish environment).
4. Findings 5 to 10 as hardening.

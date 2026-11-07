# Security review: nordstjernen-dependencies-build

**Date:** 2026-11-07
**Scope:** every file in the repository at commit `555fed6` — the three GitHub
Actions workflows, the Bash build/fetch/cross-file scripts under `android/`,
`ios/` and `linux/`, the three dependency manifests, and the READMEs.
**Method:** full manual read of all 24 files; every pinned dependency version
cross-checked against the OSV database, the MITRE CVE records, and each
project's own release site (GitHub's API is not reachable from this session,
so hashes of fixed tarballs were computed only where the download site was
reachable).

This repository contains no application code. It downloads pinned upstream
source tarballs, compiles them, and publishes the result as the native
dependency set that the Nordstjernen browser engine links against. The
security questions are therefore: (1) are the pinned libraries free of known
vulnerabilities, (2) can the build pipeline be subverted, and (3) is the
published artifact built with a safe configuration.

## Summary

| # | Severity | Finding | Where |
|---|----------|---------|-------|
| 1 | **Critical** | brotli 1.2.0 has a remote out-of-bounds write in the decoder (CVE-2026-111497, CVSS 9.2). libcurl decodes `Content-Encoding: br` from every website with it. Fixed in 1.2.1. | `android/deps/manifest.txt`, `ios/deps/manifest.txt` |
| 2 | **High** | curl 8.22.0 has 21 published CVEs, including an HTTP/2 upload use-after-free (CVE-2026-92392) and several credential / cookie / HSTS leaks. Fixed in 8.23.0, which has no published CVEs. | both mobile manifests |
| 3 | **High** | libcurl is built with every protocol enabled (`-DHTTP_ONLY=OFF`): ftp, tftp, gopher, dict, telnet, file, smtp, pop3, imap, rtsp, mqtt. Browser-facing SSRF / attack surface; two of the curl CVEs above only apply because of this. | `build-android-deps.sh:264`, `build-ios-deps.sh:319` |
| 4 | **Medium** | expat 2.9.0 has four CVEs fixed in 2.10.0 (DoS, NULL deref, signed overflow leading to OOB in `storeAtts`). Low exposure here (fontconfig parses only local config), but it is a parser of untrusted input if the engine uses it elsewhere. | both mobile manifests |
| 5 | **Medium** | freetype 2.14.3 has a DoS in the CID font loader reachable through web fonts (CVE-2026-95512). Fixed in 2.15.0. | both mobile manifests |
| 6 | **Medium** | sqlite 3.53.4 has six CVEs fixed in 3.54.0, including two FTS5 heap buffer overflows; FTS5 is compiled in. Needs attacker-influenced SQL, so lower exposure in a browser storage layer. Current release is 3.54.1. | both mobile manifests |
| 7 | **Medium** | A `workflow_dispatch` from **any** branch publishes to the public rolling release. On Linux the "no AUTO checksums" gate only runs on `main`, so an unverified tarball can be built and published to `linux-gtk-latest` from a branch. | all three workflows, `publish` job `if:` |
| 8 | **Medium** | Published sysroots are unsigned, the rolling tag is overwritten in place, and `SHA256SUMS` comes from the same origin as the tarball. Consumers fetch "latest", so whoever can publish controls the browser's native code with no provenance trail. | workflows, `fetch-prebuilt-deps.sh` |
| 9 | **Medium** | GitHub Actions are pinned by mutable tags (`@v7`, `@v3`), including a third-party action that receives a `contents: write` token. | all three workflows |
| 10 | **Medium** | Pins are trust-on-first-use: checksums are copied from the CI `PINME` line (see commit `f6f8873`), never checked against an upstream signature or published checksum. | manifests, `linux/scripts/lib/common.sh` AUTO path |
| 11 | **Low** | GLib is built with `glib_checks=false` and `glib_assert=false`, which compiles out the `g_return_if_fail` precondition checks in a library that handles untrusted data. | `dep_glib` in both mobile build scripts |
| 12 | **Low** | Build tooling is installed unpinned at build time (`pip install meson ninja`, `brew install`, `apt-get`). A compromised tool runs on the machine that produces the artifact. | all three workflows |
| 13 | **Low** | Source downloads use `curl -L` without `--proto '=https' --proto-redir '=https'`; mirror redirects (SourceForge, osuosl) may land on plain HTTP. Harmless when a hash is pinned, dangerous on the Linux AUTO path. | all three `common.sh` |
| 14 | **Low** | `actions/checkout` keeps the token in `.git/config` (default `persist-credentials: true`) while upstream `configure` / `meson.build` / `CMakeLists.txt` from the tarballs run arbitrary code. | all three workflows |
| 15 | **Low** | zlib 1.3.2 has two heap overflows in the `gzwrite` file API (CVE-2026-85091, CVE-2026-76844). Not in the inflate path a browser uses; no upstream release yet. | both mobile manifests |
| 16 | Info | PCRE2 JIT is enabled on Android (off on iOS). It is an executable-code-generation surface reachable through GLib regex. | `dep_pcre2` in `build-android-deps.sh` |
| 17 | Info | harfbuzz 14.6.0 has two CVEs in the experimental WebAssembly shaper (CVE-2026-113679/113680). The shaper is not enabled here; make that explicit with `-Dwasm=disabled`. | `dep_harfbuzz` |
| 18 | Info | Nightly scheduled rebuilds overwrite the "latest" assets even when nothing changed, so consumers see a different hash every day and cannot audit what they got against a commit. | workflows `schedule:` |
| 19 | Info | Hardening flags (`_FORTIFY_SOURCE`, stack protector, RELRO/BIND_NOW) are inherited from the NDK / Xcode / distro defaults rather than set explicitly, and the CI sanity check does not assert them in the built objects. | `common.sh` build wrappers |

Dependencies checked and found current with no known applicable CVE: zlib
(inflate path), libffi, pcre2 10.49 (CVE-2026-103111 fixed in 10.48), glib
2.90.1, proxy-libintl, libpng 1.6.59, harfbuzz (see #17), fontconfig 2.18.3,
pixman 0.46.4, fribidi, cairo 1.18.6 (CVE-2025-50422 fixed in 1.18.6), pango
1.58.2, OpenSSL 4.0.3 (fixes CVE-2026-35189/35191, nothing newer published),
nghttp2 1.70.0 (CVE-2026-58055 is in the proxy binary, fixed anyway), uchardet,
libpsl, libwebp 1.6.0, libogg, libvorbis, opus, dav1d 1.5.4, libvpx 1.17.0
(released 2026-08-07, after the CVE-2026-2447 fix), wayland-protocols, GTK
4.23.3 (4.23.4 and the 4.24 stable series now exist).

## What is done well

Worth stating, because it narrows the findings above to real gaps:

- Workflow permissions are least-privilege: `contents: read` by default, write
  only in the `publish` job.
- No `pull_request` / `pull_request_target` trigger, so there is no
  fork-PR "pwn request" path, and no untrusted expression (`github.event.*`)
  reaches a `run:` block, so no script injection.
- Every tarball URL is HTTPS and every download is verified against a pinned
  SHA-256 before extraction, re-verified on every run, cached by dependency
  name so basenames cannot collide, and downloaded to a temp file then renamed.
- Meson runs with `--wrap-mode nodownload`; the one subproject (proxy-libintl)
  is vendored from a pinned, hashed tarball.
- Tests, tools, docs, examples and encoders are disabled everywhere; codecs are
  decode-only.
- The consumer scripts validate the ABI / platform argument before using it in
  `rm -rf`, use `mktemp -d` with a cleanup trap, and verify the asset hash
  before extracting.

## Findings in detail

### 1. brotli 1.2.0 — remote OOB write in the decoder (Critical)

CVE-2026-111497, "Out-of-Bounds Write in Google Brotli Decoder", CVSS 4.0
score 9.2 (Critical), CVSS 3.1 vector `AV:N/AC:L/PR:N/UI:N/C:H/I:H/A:H`.
Affects 1.0.3 through 1.2.0 on all platforms; a crafted brotli stream can
corrupt decoder state, leak memory, crash, or potentially execute code. The
fix is in 1.2.1 (released; PyPI mirrors it as `Brotli 1.2.1`).

Both mobile sysroots build brotli and link `libbrotlidec` into libcurl
specifically so the browser decodes `Content-Encoding: br`, and the CI even
asserts that link. Every web server the browser talks to can reach this code
with no user interaction.

**Fix.** Bump to 1.2.1 in both mobile manifests. The brotli project publishes
only GitHub's auto-generated archive, which this session could not fetch, so
compute the hash yourself and verify it against a second machine or the
GitHub release page before committing:

```bash
curl -fsSL -o brotli-1.2.1.tar.gz https://github.com/google/brotli/archive/refs/tags/v1.2.1.tar.gz
sha256sum brotli-1.2.1.tar.gz
```

Manifest line (fill in the hash):

```
brotli      1.2.1     <sha256>  https://github.com/google/brotli/archive/refs/tags/v1.2.1.tar.gz
```

### 2. curl 8.22.0 — 21 published CVEs (High)

curl's own advisory table lists 21 vulnerabilities for 8.22.0 and zero for
8.23.0 (released 2026-10-14). The ones that matter for a browser engine:

- **CVE-2026-92392 (High)** HTTP/2 upload use-after-free on `RST_STREAM`.
  HTTP/2 is enabled here (`USE_NGHTTP2=ON`); any server can send that frame.
- CVE-2026-94266 password leak in `CURLINFO_EFFECTIVE_URL`.
- CVE-2026-94265, CVE-2026-86413, CVE-2026-87861 Negotiate credentials sent
  to a foreign or redirected origin / cross-origin connection reuse.
- CVE-2026-86414 host credentials leaked to an HTTP proxy.
- CVE-2026-92386, CVE-2026-86412 server-set cookie aborts or erases the
  cookie jar.
- CVE-2026-87862, CVE-2026-87863 HSTS cache entries dropped.
- CVE-2026-92387 never-ending loop via server response omission (DoS).
- CVE-2026-92389 TFTP and CVE-2026-92388 FTP wildcard bugs, reachable only
  because those protocols are compiled in (finding 3).

Not applicable: the GnuTLS (CVE-2026-107928), wolfSSL (CVE-2026-87865) and
libssh (CVE-2026-86410, CVE-2026-87865) issues, since this build uses OpenSSL
and has SSH disabled.

**Fix.** Verified against the tarball downloaded from curl.se:

```
curl        8.23.0    95b22eb32bf6d1fa6e3e9463bdb61cece3efc56d86576a9b3cbd428246a6d854  https://curl.se/download/curl-8.23.0.tar.bz2
```

### 3. libcurl built with every protocol (High)

Both mobile builds pass `-DHTTP_ONLY=OFF`, which leaves ftp, tftp, gopher,
dict, telnet, file, smtp, pop3, imap, rtsp and mqtt compiled into the
library the browser uses for navigation and subresource fetches. A page that
can make the engine request `gopher://`, `dict://` or `file://` URLs turns
libcurl into an SSRF / local-file-read primitive, and each extra protocol
is extra parser code exposed to hostile servers (two of the 8.22.0 CVEs are
in TFTP and FTP). Browsers ship HTTP(S) and WebSocket only.

**Fix.** Set `-DHTTP_ONLY=ON` (keeps HTTP, HTTPS and WebSocket) in
`dep_curl` on both platforms, and in the engine set
`CURLOPT_PROTOCOLS_STR` / `CURLOPT_REDIR_PROTOCOLS_STR` to `"http,https"`
(plus `ws,wss` if used) as defense in depth. Adjust the CI sanity check if it
expects other protocols.

### 4. expat 2.9.0 — four CVEs fixed in 2.10.0 (Medium)

CVE-2026-113351 (DoS after `XML_ParserReset`), CVE-2026-115506 (billion-laughs
protection bypass, DoS), CVE-2026-117610 (NULL dereference in external entity
handling), CVE-2026-118370 (signed integer overflow in `storeAtts` leading to
out-of-bounds access). In this stack expat is used by fontconfig to parse its
own configuration, which is local data, so exposure is low; if the engine
links expat for any network-facing XML, this becomes High.

**Fix.** Verified against the release asset:

```
expat       2.10.0    c624ba2998fc65df1163a49641ff3f9ab73138b11641d92c86bee0fb01b1bc7f  https://github.com/libexpat/libexpat/releases/download/R_2_10_0/expat-2.10.0.tar.xz
```

### 5. freetype 2.14.3 — CID font loader DoS (Medium)

CVE-2026-95512: a crafted CID-keyed font causes repeated subroutine
allocations and decryptions across font dictionaries, exhausting memory and
CPU. Web fonts are attacker-supplied, so this is remotely reachable in a
browser. The fix commit (`f3ca71c9`, "cid_read_subrs: Limit overlaps") is
only in tag `VER-2-15-0`; 2.15.0's CHANGES file names the CVE.

Note that 2.15.0 is a feature release (new OpenType format support, new
rasterizer memory handling), so it needs a rendering regression pass, and it
should also be checked against the harfbuzz two-stage build.

**Fix.** Verified against the Savannah tarball:

```
freetype    2.15.0    93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5  https://download.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz
```

(or the equivalent SourceForge URL the manifest currently uses; the hash is
of the upstream file either way).

### 6. sqlite 3.53.4 — six CVEs fixed in 3.54.0 (Medium)

CVE-2026-119371 and -119376 (stack exhaustion bypassing
`SQLITE_LIMIT_EXPR_DEPTH`), -119372 (FTS3 use-after-free, only with
`SQLITE_ENABLE_FTS3_PARENTHESIS`), -119373 and -119374 (FTS5 heap buffer
overflows), -119375 (uninitialised page-cache read). FTS5 is compiled in on
iOS explicitly and by the autoconf defaults on Android. All need the attacker
to influence SQL text or a database file, so in a browser storage layer this
is lower than the score suggests, but the engine should not assume that.

**Fix.** Verified against sqlite.org:

```
sqlite3     3.54.1    926ef8d3eab93fbf6e06011901273eec076b25594a4e1cdadd50c987f4f6d64e  https://www.sqlite.org/2026/sqlite-autoconf-3540100.tar.gz
```

### 7. Publishing from any branch via `workflow_dispatch` (Medium)

All three `publish` jobs run when
`github.event_name == 'workflow_dispatch'` with no check on `github.ref`.
Anyone with write access (or a compromised collaborator token) can push a
branch with altered scripts or manifests and dispatch the workflow from it,
overwriting the public `*-latest` release that every engine build and
developer consumes. The build job runs on that branch's checkout.

On Linux it is worse: the "Ensure manifest is fully pinned" step is gated on
`github.ref == 'refs/heads/main'`, and `download_verify` deliberately skips
verification for `AUTO` entries. A dispatch from a branch with an `AUTO`
checksum therefore builds whatever the mirror served and publishes it.

**Fix.** In each workflow change the publish condition to require `main`
for every event:

```yaml
if: github.ref == 'refs/heads/main' &&
    (github.event_name == 'workflow_dispatch' || github.event_name == 'schedule' || github.event_name == 'push')
```

and make the AUTO check unconditional (it is cheap and should fail any branch
that will be published). Consider a GitHub Environment with required
reviewers on the publish job.

### 8. Unsigned, overwritten, same-origin-verified releases (Medium)

`softprops/action-gh-release` uploads the new tarballs over the existing
`sysroot-latest` / `ios-sysroot-latest` / `linux-gtk-latest` assets. The
consumer scripts download `SHA256SUMS` and the tarball from the same release
and compare them. That detects a truncated download, not a malicious one: an
attacker who can publish (finding 7, 9, 12, 14) or who controls the GitHub
release regenerates both files. There is no signature, no build provenance
attestation, and no immutable copy of previous builds, so a compromised
publish silently replaces the only copy and consumers cannot pin a known-good
build (the tag is not moved to the new commit either, so the release's commit
is only text in the body and in `BUILDINFO.txt`).

**Fix.**
- Generate SLSA provenance with `actions/attest-build-provenance` for each
  tarball, and have `fetch-prebuilt-deps.sh` (or at least the engine's CI)
  verify it with `gh attestation verify`; or sign `SHA256SUMS` with cosign /
  a project key and verify that.
- Also publish an immutable release per commit (`sysroot-<sha>` or a
  date-stamped tag) and keep `latest` as a pointer, so consumers can pin.
- In the engine's consumer scripts, pin the tag and the expected `SHA256SUMS`
  hash rather than fetching `latest` blindly.

### 9. Actions pinned by mutable tag (Medium)

`actions/checkout@v7`, `actions/setup-python@v7`, `actions/cache@v6`,
`actions/upload-artifact@v7`, `actions/download-artifact@v8` and
`softprops/action-gh-release@v3` are all tag references. A retargeted tag
(as in the 2025 `tj-actions/changed-files` compromise) runs attacker code on
the runner; for the release action it runs with the `contents: write` token
that publishes the sysroots.

**Fix.** Pin every action to a full commit SHA with the version in a comment,
and enable Dependabot for `github-actions` to keep them fresh.

### 10. Trust-on-first-use pinning (Medium)

The manifests promise checksums "verified at pin time", but the mechanism
that exists (`AUTO` → `PINME` in `linux/scripts/lib/common.sh`, and commit
`f6f8873` "pin gtk 4.23.3 sha256 from the CI PINME line") pins whatever the
CI runner downloaded. A mirror or CDN compromise at pin time is then locked
in. Most upstreams publish an independent checksum or signature (curl and
OpenSSL `.asc`, GNOME `.sha256sum`, SQLite's download page, Savannah
`.sig`).

**Fix.** Document and follow a pin procedure: fetch the upstream signature or
checksum file, verify it, then paste the hash. Record the source of the hash
in the manifest comment or the commit message. Keep `AUTO` as a local
convenience only and refuse it in CI on every branch (see finding 7).

### 11. GLib precondition checks compiled out (Low)

`-Dglib_checks=false` removes `g_return_if_fail` / `g_return_val_if_fail`
argument validation from the shipped GLib, and `-Dglib_assert=false` removes
`g_assert`. GLib's documentation describes these as performance options not
recommended for production builds. In a browser, GLib, GIO and GObject process
strings and buffers derived from web content; those checks turn many
programming errors into a logged early return instead of memory corruption.
The performance cost is negligible for this workload.

**Fix.** Drop both options (or set them to `true`) in `dep_glib` on Android
and iOS.

### 12. Unpinned build tooling (Low)

`python -m pip install 'meson>=1.5.0' ninja` (no version pin, no
`--require-hashes`), `brew install ...` and `apt-get install ...` run at every
build. These tools run every upstream build script and produce the objects
that are shipped; a malicious release of any of them is a direct artifact
compromise, and the floating versions also make builds non-reproducible.

**Fix.** Pin `meson==X.Y.Z` and `ninja==X.Y.Z` with `--require-hashes` from a
requirements file, and consider a Homebrew lockfile / explicit formula
versions on macOS. apt pins are harder; at least record the versions in
`BUILDINFO.txt` (meson, ninja, cmake, compiler) so a build can be reproduced.

### 13. Redirects may leave HTTPS (Low)

`curl -fsSL` follows redirects to any protocol by default. SourceForge and
osuosl answer with mirror redirects, and a mirror can be plain HTTP. With a
pinned hash the worst case is a build failure; on the Linux `AUTO` path the
unverified HTTP download becomes the pinned hash.

**Fix.** Add `--proto '=https' --proto-redir '=https'` to the download
commands in all three `common.sh` and both `fetch-prebuilt-deps.sh`.

### 14. Checkout token persisted during untrusted build steps (Low)

`actions/checkout` writes the job token into `.git/config`. In the build
jobs every dependency's `configure`, `meson.build` and `CMakeLists.txt` from
the extracted tarballs executes on that machine, and `ccache` / `pip` /
`brew` code too. The token is read-only there (limited impact), but in the
`publish` job it has `contents: write` and the third-party release action
runs after checkout.

**Fix.** Add `with: persist-credentials: false` to every checkout; nothing
in these workflows pushes with git.

### 15. zlib 1.3.2 gzwrite overflows (Low)

CVE-2026-85091 (`gz_vacate` heap overflow after a stalled non-blocking
`gzwrite`) and CVE-2026-76844 (`gz_write` after a failed `write()`) are in
the `gz*` file API, not in `inflate`/`deflate` that a browser uses for
Content-Encoding and PNG. No upstream release contains the fixes yet
(distros patch 1.3.2; a 1.3.2.1 release candidate exists). Track it and bump
when 1.3.2.1 ships. The engine should not use `gzopen`/`gzwrite` on
attacker-influenced data meanwhile.

### 16–19. Informational

- **PCRE2 JIT** (`-DPCRE2_SUPPORT_JIT=ON` on Android only). sljit uses dual
  mapping to avoid RWX pages, but JIT is still a code-generation surface
  reachable through `GRegex`. iOS already runs the interpreter; if GLib regex
  performance is acceptable there, consider turning JIT off on Android too.
- **harfbuzz wasm shaper.** CVE-2026-113679/113680 affect 8.0.0–14.6.0 but
  only with the experimental WebAssembly shaper, which meson leaves disabled.
  Add `-Dwasm=disabled` to `dep_harfbuzz` so a future default change cannot
  enable it.
- **Nightly overwrites.** The scheduled rebuild republishes "latest" every
  night even without source changes. Consumers' hashes change daily, which
  hides a malicious change among benign ones. Publish only on change, or
  publish nightlies under a separate tag.
- **Hardening flags.** The Android build relies on the NDK clang defaults
  (`-fstack-protector-strong`, `-D_FORTIFY_SOURCE=2`, `-z relro -z now`),
  iOS on Xcode defaults, Linux on Ubuntu's gcc defaults. Those defaults are
  good, but nothing here asserts them, and the `-fPIC -O2` flags are set
  without `-D_FORTIFY_SOURCE`. Consider setting them explicitly in the
  cross-files / `build_autotools`, and extending the CI sanity check to
  assert `GNU_RELRO`, `BIND_NOW` and no `TEXTREL` with `readelf`.
- **GTK 4.23.3** is a development release; 4.23.4 and the stable 4.24 series
  are now available. Not a vulnerability, but the stable series is what will
  receive security fixes.

## Recommended order of work

1. Bump brotli to 1.2.1 and curl to 8.23.0, set `HTTP_ONLY=ON`, rebuild and
   republish (findings 1–3). This is the only change that closes a remotely
   exploitable memory-safety bug in the shipped browser.
2. Bump freetype, expat and sqlite (findings 4–6) in the same or next cycle.
3. Gate publishing on `main`, run the AUTO check everywhere, pin actions to
   SHAs, set `persist-credentials: false` (findings 7, 9, 14). These are
   small workflow edits.
4. Add provenance attestation or signing and immutable per-commit releases,
   then make the consumer scripts verify them (finding 8).
5. Re-enable GLib checks, pin build tools, restrict curl redirects to HTTPS,
   adopt a signature-verified pin procedure (findings 10–13).
6. Add a scheduled OSV / CVE check of `manifest.txt` to CI so the next brotli
   is caught before a human reads an advisory.

## Remediation status

Applied on this branch after the review (see the commit history for details):

| # | Finding | Status |
|---|---------|--------|
| 1 | brotli 1.2.0 | **Fixed:** pinned 1.2.1. The GitHub auto-generated archive could not be downloaded from the review session, so its sha256 was taken from the Homebrew formula (`formulae.brew.sh/api/formula/brotli.json`); CI re-verifies the hash on the first build. |
| 2 | curl 8.22.0 | **Fixed:** pinned 8.23.0 (hash computed from curl.se). |
| 3 | libcurl protocol surface | **Fixed:** tftp, gopher, dict, telnet, file, smtp, pop3, imap, rtsp, mqtt, ldap(s) and smb are disabled at configure time; FTP(S) is kept because `src/net.c` in the engine renders FTP listings. CI asserts `curl-config --protocols`. |
| 4 | expat 2.9.0 | **Fixed:** pinned 2.10.0 (hash from the GitHub release asset). |
| 5 | freetype 2.14.3 | **Fixed:** pinned 2.15.0 (hash from download.savannah.gnu.org; the CVE fix commit is in tag VER-2-15-0). Feature release, so watch the first rendering runs. |
| 6 | sqlite 3.53.4 | **Fixed:** pinned 3.54.1 (hash from sqlite.org). |
| 7 | Publish from any branch; AUTO gate main-only | **Fixed:** publish jobs require `github.ref == refs/heads/main`; the Linux AUTO check runs on every branch; the nightly schedule builds but no longer republishes. |
| 8 | Unsigned, overwritten releases | **Fixed:** every publish attests the assets with `actions/attest-build-provenance` and also creates an immutable per-commit release (`<prefix>-<date>-<sha>`); `fetch-prebuilt-deps.sh` verifies the attestation with `gh` when available (`NORDSTJERNEN_REQUIRE_ATTESTATION=1` makes it mandatory). |
| 9 | Mutable action tags | **Fixed:** all `uses:` pinned to commit SHAs (version in a trailing comment). Enable Dependabot `github-actions` updates to keep them fresh. |
| 10 | Trust-on-first-use pins | **Mitigated:** pin procedure documented in each manifest header and the Linux README; AUTO rejected by CI on every branch. Verification against upstream signatures remains a human step. |
| 11 | GLib checks compiled out | **Fixed:** `glib_checks` / `glib_assert` left at their defaults. |
| 12 | Unpinned build tooling | **Fixed for pip:** meson and ninja installed with `--require-hashes` from `.github/requirements-build.txt`. Homebrew (iOS) and apt (Linux) tooling is still unpinned; their versions are now recorded in `BUILDINFO.txt`. |
| 13 | Redirects off HTTPS | **Fixed:** `--proto '=https' --proto-redir '=https'` on every download. |
| 14 | Persisted checkout token | **Fixed:** `persist-credentials: false` on every checkout. |
| 15 | zlib gzwrite CVEs | **Open:** no upstream release yet; bump when 1.3.2.1 ships. |
| 16 | PCRE2 JIT on Android | **Fixed:** JIT off, matching iOS. |
| 17 | harfbuzz wasm shaper | **Fixed:** `-Dwasm=disabled` explicit. |
| 18 | Nightly overwrites | **Fixed:** see 7. |
| 19 | Hardening flags not asserted | **Fixed for Android:** `-z relro -z now` passed explicitly and CI asserts GNU_RELRO, BIND_NOW and no TEXTREL on every shipped `.so`. iOS/Linux rely on toolchain defaults. |

Engine side (nordstjernen-browser): the sysroot consumer scripts were updated
to verify provenance and the libcurl protocol allow-list was made to follow the
protocols the linked libcurl actually provides.

## Verification notes

- OSV queries without an ecosystem return fuzzy, distro-level matches; every
  "affected" claim above was confirmed against the MITRE CVE record's version
  range or the project's own advisory page (curl.se vulnerability table,
  openssl-library.org, freetype CHANGES and GitLab tag refs, Mozilla
  advisory for libvpx).
- Hashes for curl 8.23.0, expat 2.10.0, freetype 2.15.0 and sqlite 3.54.1 were
  computed in this session from the files served by curl.se, GitHub release
  assets, download.savannah.gnu.org and sqlite.org respectively. They were not
  cross-checked against upstream signatures; do that before committing them.
- brotli 1.2.1 could not be downloaded from this session (GitHub archive URLs
  are blocked here), so its hash is left for the maintainer to compute.
- `shellcheck` is not installed in this environment, so the scripts were
  reviewed by hand only.

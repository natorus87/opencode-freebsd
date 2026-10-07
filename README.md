# opencode on FreeBSD

[opencode](https://github.com/anomalyco/opencode) ships no FreeBSD build. The
`opencode-ai` npm package declares `"os": ["darwin", "linux", "win32"]` and
there is no `opencode-freebsd-*` binary in any channel.

Building it from source works. This repo contains the scripts and patches
that do it, plus prebuilt binaries as
[releases](https://github.com/natorus87/opencode-freebsd/releases).

```sh
sh build.sh            # full pipeline: natives -> binary -> validate -> package
sh install.sh          # install the newest packaged release to /usr/local/bin/opencode
```

Verified on FreeBSD 15.x amd64: `opencode --help`, a headless server, and
the full TUI rendering under a real tty. arm64 builds are supported by the
scripts; end-to-end arm64 validation on real hardware is still pending
(see [aarch64](#aarch64)).

## Fast path: use a prebuilt release

1. Download `opencode-<VERSION>-freebsd-x64.tar.gz` and its `SHA256SUMS`
   from the [releases page](https://github.com/natorus87/opencode-freebsd/releases).
2. Verify and install:

```sh
sha256 -c SHA256SUMS          # must say OK
tar -xzf opencode-<VERSION>-freebsd-x64.tar.gz
sh install.sh opencode-<VERSION>-freebsd-x64.tar.gz
opencode --version
```

## Building from source

Prerequisites (one-time, via pkg):

```sh
pkg install git python3 rust node npm-node24 llvm ca_root_nss
```

On amd64, `build.sh` installs bun itself from the official
`@oven/bun-freebsd-x64` npm package if missing. That package has no arm64
variant, so on arm64 install a FreeBSD/aarch64 bun first (e.g. via pkg)
before running the script.

Then:

```sh
git clone https://github.com/natorus87/opencode-freebsd
cd opencode-freebsd
sh build.sh
```

What `build.sh` does:

1. **Toolchain** — checks for `git python3 cargo node npm cc bun`; installs
   the official `@oven/bun-freebsd-x64` bun if missing; fetches zig 0.15.2
   (see "Two version traps" below).
2. **Checkout** — clones `sst/opencode` to `$OC_SRC` (`$HOME/opencode-src`)
   and runs `bun install`.
3. **fff** — builds the `fff-c` Rust cdylib and stages it as
   `@ff-labs/fff-bin-freebsd-x64` (`patches/fff-bun-freebsd.patch`).
4. **node-pty** — builds the matching N-API addon
   (`patches/node-pty-freebsd.patch`).
5. **opentui native** — builds `libopentui.so` with zig
   (`patches/opentui-0.4.5-freebsd-zig.patch`) and teaches the installed
   JS bundle to resolve it on freebsd (source equivalent:
   `patches/opentui-js-freebsd.patch`).
6. **Binary** — adds `{ os: "freebsd", arch: "x64" }` and
   `{ os: "freebsd", arch: "arm64" }` to `allTargets` in
   `packages/opencode/script/build.ts` (idempotent) and runs
   `bun run packages/opencode/script/build.ts --single --skip-install`
   (`--single` selects the entry matching the build host).
7. **Validate** — asserts a native FreeBSD ELF (`file`), sane linkage
   (`ldd`), `--version`, `--help`, and a short TUI smoke run.
8. **Package** — writes `opencode-<VERSION>-freebsd-x64/` with the binary,
   `BUILD-INFO.txt`, and `SHA256SUMS`, plus a `.tar.gz`.

Useful options and environment (see `build.sh --help`):

```sh
sh build.sh --skip-natives        # reuse node_modules natives from a previous run
sh build.sh --natives-only        # stop after the source smoke test
sh build.sh --skip-embed-web-ui   # fallback if the web-UI embed step ever fails
OC_SRC=$HOME/my-src OC_WORK=$HOME/my-work OC_RELEASES=$HOME/my-releases sh build.sh
```

Re-running is safe: patch applications are idempotent, and `node_modules`
is never deleted (it holds the built FreeBSD natives, which `bun install`
alone cannot reproduce).

## What actually blocks upstream

Three native dependencies, and nothing else. Bun, `@parcel/watcher`,
tree-sitter, photon and the other ~2300 JS packages install and work untouched.

| Dependency | Why it fails | Fixed by |
|---|---|---|
| `@ff-labs/fff-bun` | `"os"` omits freebsd, so it is never installed. And `getTriple()` throws `Unsupported platform: freebsd` from inside `getNpmPackageName()`, which `resolveFromNpmPackage()` calls *outside* its own try/catch — so the throw escapes instead of degrading to "no prebuilt, use the source build". The Rust cdylib needs no patch at all. | [`patches/fff-bun-freebsd.patch`](patches/fff-bun-freebsd.patch) |
| `@lydell/node-pty` | A genuine upstream bug, not a missing platform: `pty_close_inherited_fds()` is defined under `#if defined(__linux__)` but called from the `#else` branch of `#if defined(__APPLE__)` — that is, on *every* non-Apple platform. macOS and Linux are fine; the BSDs do not compile. | [`patches/node-pty-freebsd.patch`](patches/node-pty-freebsd.patch) |
| `@opentui/core` | The Zig build refuses to build for a host that is not in `SUPPORTED_TARGETS`, and the JS resolver throws before `OTUI_ASSET_ROOT` is ever consulted, so there is no escape hatch for a locally built library either. | [`patches/opentui-0.4.5-freebsd-zig.patch`](patches/opentui-0.4.5-freebsd-zig.patch) + installed-bundle resolver fix |

Reference patches (not applied by the script, kept for the upstream PRs):
`patches/opentui-freebsd.patch` (native side against opentui main) and
`patches/opentui-js-freebsd.patch` (source-side resolver change).

**Bun is not a blocker**, despite first appearances.
[`@oven/bun-freebsd-x64`](https://www.npmjs.com/package/@oven/bun-freebsd-x64)
is an official build and it works. A bun linked against FreeBSD 14.3 needs
`libutil.so.9` on 15.x (`pkg install compat14x-amd64`); upstream already
links libutil statically
([oven-sh/bun#40532](https://github.com/oven-sh/bun/pull/40532)), so this
fades away.

## Two version traps

**opencode pins `@opentui/core` 0.4.5.** In that tree the Zig sources live at
`packages/core/src/zig` (not `packages/native`), and its `build.zig.zon`
declares `minimum_zig_version = "0.15.2"`. FreeBSD's packaged zig is 0.16.0,
which fails on that tree with `std.Build` API errors from a vendored uucode
`build.zig`. The script fetches a 0.15.2 toolchain for this one build. Do not
"fix" it by swapping in opentui main — the JS↔FFI contract is version-coupled.

**`npm` is a separate port on FreeBSD.** `pkg install node` does not bring it;
you need `npm-node24` (or whichever matches your node). And a stock image has
no CA bundle, so `zig fetch` fails with `CertificateBundleLoadFailure` until
`pkg install ca_root_nss`.

## Upstream

All three native patches are open as upstream PRs, plus the build-target
change from this repo. Once they all land, most of this repo becomes
unnecessary — what remains is a normal `bun install` plus the `freebsd`
entry in the opencode build targets.

- [anomalyco/opencode#53689](https://github.com/anomalyco/opencode/pull/53689)
  — FreeBSD x64 build target (the `build.ts` change `build.sh` applies;
  `build.sh` additionally adds the arm64 entry, which will be proposed
  upstream once verified on real arm64 hardware)
- [microsoft/node-pty#961](https://github.com/microsoft/node-pty/pull/961)
- [anomalyco/opentui#1445](https://github.com/anomalyco/opentui/pull/1445)
- [dmtrKovalenko/fff#824](https://github.com/dmtrKovalenko/fff/pull/824)
- [oven-sh/bun#40530](https://github.com/oven-sh/bun/issues/40530) /
  [#40532](https://github.com/oven-sh/bun/pull/40532) — bun's libutil linkage
  (affects bun itself only, not the opencode binary)

Note on fff specifically: the patch makes the package installable and lets a
source build be found from a git checkout, but with no published
`@ff-labs/fff-bin-freebsd-*` an npm-installed consumer still ends at
`findBinary() === null` rather than a working library — see the discussion in
that PR. This script sidesteps it by placing the built library where the
resolver looks.

## aarch64

The scripts are arch-aware (`uname -m` selects bun arch names, zig target
triples, platform-package names and release names), and the fff patch already
maps both FreeBSD triples. Proven from an amd64 host so far:

- `bun build --compile --target=bun-freebsd-arm64` emits a genuine
  FreeBSD/aarch64 ELF, so the final link step needs no arm64 host.
- `zig build -Dtarget=aarch64-freebsd` (zig 0.15.2) cross-builds
  `libopentui.so` for aarch64 cleanly; zig publishes an
  `aarch64-freebsd` 0.15.2 tarball, so `build.sh` fetches the toolchain
  per-arch automatically.

What still needs a real arm64 FreeBSD machine: building `libfff_c.so`
(via cargo, expected to just work), building `pty.node` (via node-gyp),
and — most importantly — validating the assembled binary (`--version`,
TUI smoke). Until that happens, treat arm64 output as unvalidated:
build it natively on arm64 with `sh build.sh`, verify per the checklist
above, and only then cut a `freebsd-arm64-*` release.

Caveats carried over from the earlier arm64 spot-checks: the fff
FFI-level exercise and end-to-end TUI rendering were verified on amd64
only; on arm64 the libraries were loaded and symbols resolved, nothing more.

## What this does not claim

- Not tested on any other BSD.
- The fff FFI-level exercise (`FileFinder.create()` + `fileSearch()` returning
  real results) was run on amd64 only; on arm64 the library was loaded and
  symbols resolved, nothing more.
- End-to-end TUI rendering was verified on amd64 only.
- `ghosttyVtAvailable()` returns false for FreeBSD, so ghostty-vt is compiled
  out of opentui. The TUI renders correctly without it; what else it might cost
  has not been investigated.
- The file watcher logs `watcher backend not supported, platform=freebsd`
  and uses a fallback — non-fatal, sessions run normally.

## Releasing

See [RELEASING.md](RELEASING.md) for how maintainers cut a GitHub release
from a validated FreeBSD build.

## License

The patches are trivial platform-plumbing changes against MIT-licensed
upstreams and are offered under the same terms. The scripts are MIT —
see [LICENSE](LICENSE).

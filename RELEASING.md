# Cutting a release (maintainers)

GitHub Actions has no FreeBSD runners, so releases are built on a FreeBSD
host and uploaded with `gh`. The first release was built on
FreeBSD 15.0-RELEASE-p14 amd64 with bun 1.4.2.

## 1. Build and validate

```sh
sh build.sh
```

`build.sh` already validates (`file` = FreeBSD ELF, `ldd` = base system
libs only, `--version`, `--help`, TUI smoke) and writes the package to
`$OC_RELEASES/opencode-<VERSION>-freebsd-x64/` plus
`opencode-<VERSION>-freebsd-x64.tar.gz`.

`<VERSION>` is the binary's own `--version` output. On the `dev` branch
upstream generates `0.0.0-dev-YYYYMMDDHHMM`; that is expected, not an error.

## 2. Sanity-check the package

```sh
ls -lh ~/opencode-releases/opencode-*-freebsd-x64.tar.gz
tar -tzf ~/opencode-releases/opencode-*-freebsd-x64.tar.gz
cat ~/opencode-releases/opencode-*-freebsd-x64/SHA256SUMS
```

## 3. Publish to GitHub

```sh
cd "$HOME/opencode-releases"
VER=<VERSION>   # e.g. 0.0.0-dev-202610061344
ARCH=<arch>     # x64 or arm64, matching the built binary
gh release create "freebsd-${ARCH}-${VER}" \
  --repo natorus87/opencode-freebsd \
  --title "FreeBSD ${ARCH} ${VER}" \
  --notes "Native FreeBSD-${ARCH} build of opencode ${VER}. See BUILD-INFO.txt in the tarball for toolchain details. Install without building: sh install.sh --from-github ${VER}" \
  "opencode-${VER}-freebsd-${ARCH}.tar.gz#opencode-${VER}-freebsd-${ARCH}.tar.gz"
```

Tag convention (consumers rely on it — `install.sh --from-github` builds
these URLs mechanically): `freebsd-<arch>-<version>` with asset
`opencode-<version>-freebsd-<arch>.tar.gz`. Upload `SHA256SUMS` and
`BUILD-INFO.txt` as extra assets alongside the tarball.

Keep every release immutable: never overwrite an older tarball,.publish a
new version instead. `install.sh` treats older versions as valid rollback
targets.

## 4. Verify from the consumer side

On a second machine, as root:

```sh
fetch -q -o - https://raw.githubusercontent.com/natorus87/opencode-freebsd/main/install.sh | sh -s -- --from-github <VERSION>
opencode --version
```

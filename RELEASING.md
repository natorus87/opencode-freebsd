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
gh release create "freebsd-x64-${VER}" \
  --repo natorus87/opencode-freebsd \
  --title "FreeBSD x86_64 ${VER}" \
  --notes "Native FreeBSD-amd64 build of opencode ${VER}. See BUILD-INFO.txt in the tarball for toolchain details. Verify with: sha256 -c SHA256SUMS" \
  "opencode-${VER}-freebsd-x64.tar.gz#opencode-${VER}-freebsd-x64.tar.gz"
```

Keep every release immutable: never overwrite an older tarball,.publish a
new version instead. `install.sh` treats older versions as valid rollback
targets.

## 4. Verify from the consumer side

On a second machine (or after moving the tarball aside):

```sh
sha256 -c SHA256SUMS
sh install.sh opencode-<VERSION>-freebsd-x64.tar.gz
opencode --version
```

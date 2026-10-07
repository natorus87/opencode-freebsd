#!/bin/sh
# Package a validated opencode FreeBSD binary into a release directory:
#   <OC_RELEASES>/opencode-<VERSION>-freebsd-<arch>/
#     opencode  BUILD-INFO.txt  SHA256SUMS
# plus a sibling tarball opencode-<VERSION>-freebsd-<arch>.tar.gz.
#
# Usage: sh package-release.sh <path-to-built-opencode-binary>
# Env:   OC_RELEASES (default: $HOME/opencode-releases)
set -u

OC_RELEASES="${OC_RELEASES:-$HOME/opencode-releases}"
BIN="${1:-}"

[ -n "${BIN}" ] || { echo "package-release.sh: usage: sh package-release.sh <binary>" >&2; exit 2; }
[ -x "${BIN}" ] || { echo "package-release.sh: not executable: ${BIN}" >&2; exit 1; }

VER="$("${BIN}" --version 2>/dev/null)" || { echo "package-release.sh: --version smoke test failed" >&2; exit 1; }
[ -n "${VER}" ] || { echo "package-release.sh: empty --version output" >&2; exit 1; }

case "${VER}" in
	*/*|*' '*|*..*) echo "package-release.sh: unable to use version string: ${VER}" >&2; exit 1 ;;
esac

# Architecture comes from the build output path (.../dist/opencode-freebsd-<arch>/bin/...).
case "${BIN}" in
	*-freebsd-arm64/*) REL_ARCH=arm64 ;;
	*) REL_ARCH=x64 ;;
esac

R="${OC_RELEASES}/opencode-${VER}-freebsd-${REL_ARCH}"
mkdir -p "${R}"
cp "${BIN}" "${R}/opencode"
chmod 755 "${R}/opencode"

# Re-verify the copy reports the same version (catches stale copies).
GOT="$("${R}/opencode" --version 2>/dev/null)"
[ "${GOT}" = "${VER}" ] || { echo "package-release.sh: copy reports ${GOT}, want ${VER}" >&2; exit 1; }

FILE_OUT="$(file "${R}/opencode")"
BUN_VER="$(bun --version 2>/dev/null || echo unknown)"
BUILD_HOST="$(freebsd-version 2>/dev/null || uname -r)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "${R}/BUILD-INFO.txt" <<INFO
OpenCode FreeBSD-${REL_ARCH} Build Info
===============================
OpenCode version (binary --version): ${VER}
Git commit (opencode checkout): $(git -C "$(dirname "${BIN}")/../../../.." log --oneline -1 2>/dev/null || echo unknown)
Build date (UTC): ${BUILD_DATE}
Build host: ${BUILD_HOST} ($(uname -m))
Bun version: ${BUN_VER}
Build command: bun run packages/opencode/script/build.ts --single --skip-install
FreeBSD target: appended to allTargets in packages/opencode/script/build.ts ({ os: "freebsd", arch: "x64" })
file: ${FILE_OUT}
Note: the file watcher logs "watcher backend not supported, platform=freebsd" (non-fatal fallback).
INFO

(cd "${R}" && sha256 opencode > SHA256SUMS)
(cd "${OC_RELEASES}" && tar -czf "opencode-${VER}-freebsd-${REL_ARCH}.tar.gz" "opencode-${VER}-freebsd-${REL_ARCH}"/opencode "opencode-${VER}-freebsd-${REL_ARCH}"/BUILD-INFO.txt "opencode-${VER}-freebsd-${REL_ARCH}"/SHA256SUMS)

echo "release: ${R}"
echo "tarball: ${OC_RELEASES}/opencode-${VER}-freebsd-${REL_ARCH}.tar.gz"
cat "${R}/SHA256SUMS"

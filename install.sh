#!/bin/sh
# Install (or update) the native opencode FreeBSD binary from a local
# release directory or tarball to DEST (default: /usr/local/bin/opencode).
#
# Safety per candidate: SHA256 check -> smoke test (--version) ->
# version comparison -> install -> verification. On any failure nothing
# is replaced; the installed binary keeps working.
#
# Usage:
#   sh install.sh [options] [version | tarball]
#     (no argument: newest release in the releases directory;
#      version e.g. 0.0.0-dev-202610061344 -- older versions work as rollback;
#      or a path to an opencode-*-freebsd-x64.tar.gz tarball)
#
# Options:
#   --releases DIR   where releases live (default: $HOME/opencode-releases)
#   --dest PATH      install destination (default: /usr/local/bin/opencode)
#   --check          only report whether an update is needed (exit 1 if so)
#   --force          reinstall even if the same version is installed
#   --quiet          print only errors
#   -h, --help       show this help
set -u

RELEASES="${OC_RELEASES:-$HOME/opencode-releases}"
DEST=/usr/local/bin/opencode
QUIET=0; CHECK=0; FORCE=0
WANT=""

say() { [ "$QUIET" -eq 0 ] && echo "install: $*"; return 0; }
err() { echo "install: ERROR: $*" >&2; }

while [ $# -gt 0 ]; do
	case $1 in
		--releases) RELEASES=$2; shift 2 ;;
		--releases=*) RELEASES=${1#--releases=}; shift ;;
		--dest) DEST=$2; shift 2 ;;
		--dest=*) DEST=${1#--dest=}; shift ;;
		--check) CHECK=1; shift ;;
		--force) FORCE=1; shift ;;
		--quiet) QUIET=1; shift ;;
		-h|--help) sed -n '2,24p' "$0"; exit 0 ;;
		-*) err "unknown option: $1"; exit 2 ;;
		*) WANT=$1; shift ;;
	esac
done

# Newest release: the version part is a fixed-width timestamp
# (0.0.0-dev-YYYYMMDDHHMM), so lexicographic sort is enough.
latest() {
	ls -d "$RELEASES"/opencode-*-freebsd-x64 2>/dev/null | LC_ALL=C sort | tail -1
}

TMPDIR=""
BARE_TARBALL=0
cleanup() { [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ] && rm -rf "$TMPDIR"; }
trap cleanup EXIT INT TERM

if [ -n "$WANT" ]; then
	case "$WANT" in
		*.tar.gz)
			[ -f "$WANT" ] || { err "tarball not found: $WANT"; exit 1; }
			TMPDIR="$(mktemp -d)" || { err "mktemp failed"; exit 1; }
			tar -xzf "$WANT" -C "$TMPDIR" || { err "unpacking $WANT failed"; exit 1; }
			DIR="$(ls -d "$TMPDIR"/opencode-*-freebsd-x64 2>/dev/null | head -1)"
			if [ -z "$DIR" ] && [ -x "$TMPDIR/opencode" ] && [ -f "$TMPDIR/SHA256SUMS" ]; then
				# Legacy/foreign layout: bare opencode + SHA256SUMS at top level.
				DIR="$TMPDIR"
				BARE_TARBALL=1
			fi
			[ -n "$DIR" ] || { err "no release content inside $WANT"; exit 1; }
			;;
		*)
			DIR=$RELEASES/opencode-$WANT-freebsd-x64
			[ -d "$DIR" ] || { err "release not found: $DIR"; exit 1; }
			;;
	esac
else
	DIR=$(latest)
	[ -n "$DIR" ] || { err "no release in $RELEASES (see --releases)"; exit 1; }
fi
VER=${DIR##*/opencode-}; VER=${VER%-freebsd-x64}
BIN=$DIR/opencode

[ -x "$BIN" ] || { err "$BIN missing or not executable"; exit 1; }
[ -f "$DIR/SHA256SUMS" ] || { err "$DIR/SHA256SUMS missing"; exit 1; }

# 1. Checksum (SHA256SUMS uses the BSD format "SHA256 (opencode) = <hash>").
EXPECTED=$(awk -F' = ' '/^SHA256 \(opencode\) = /{print $2}' "$DIR/SHA256SUMS")
[ -n "$EXPECTED" ] || { err "no hash for opencode in $DIR/SHA256SUMS"; exit 1; }
ACTUAL=$(sha256 -q "$BIN") || { err "sha256 failed"; exit 1; }
[ "$EXPECTED" = "$ACTUAL" ] || { err "checksum mismatch for $BIN"; exit 1; }

# 2. Smoke test: the candidate must start and report its version.
GOT=$("$BIN" --version 2>/dev/null) || { err "smoke test failed: $BIN --version"; exit 1; }
[ -n "$GOT" ] || { err "smoke test: empty version output"; exit 1; }
if [ "$BARE_TARBALL" -eq 1 ]; then
	VER="$GOT"   # bare tarball carries no version in its path; trust the smoke-tested binary
else
	[ "$GOT" = "$VER" ] || { err "version mismatch: binary=$GOT directory=$VER"; exit 1; }
fi

# 3. Compare with the installed version.
INSTALLED="none"
[ -x "$DEST" ] && INSTALLED=$("$DEST" --version 2>/dev/null || echo "broken")

if [ "$INSTALLED" = "$VER" ] && [ "$FORCE" -eq 0 ]; then
	say "$VER already installed, nothing to do."
	exit 0
fi

if [ "$CHECK" -eq 1 ]; then
	say "update available: installed=${INSTALLED} release=${VER}."
	exit 1
fi

# 4. Install + verify.
say "installing $VER (previous: $INSTALLED) to $DEST ..."
install -m 755 "$BIN" "$DEST" || { err "install to $DEST failed"; exit 1; }
AFTER=$("$DEST" --version 2>/dev/null) || { err "$DEST does not start after install"; exit 1; }
[ "$AFTER" = "$VER" ] || { err "installed version $AFTER != $VER"; exit 1; }
say "done: $DEST reports $AFTER."
exit 0

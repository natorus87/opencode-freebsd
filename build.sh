#!/bin/sh
# Build opencode for FreeBSD from source: native dependencies, binary, package.
#
# Upstream ships no FreeBSD build: the opencode-ai npm package declares
# "os": ["darwin","linux","win32"] and there is no opencode-freebsd-* binary.
# Building from source works, and needs exactly three native dependencies
# ported -- everything else (bun itself, @parcel/watcher, tree-sitter, photon,
# ~2300 JS packages) already works on FreeBSD untouched.
#
#   @lydell/node-pty  -> patches/node-pty-freebsd.patch
#   @opentui/core     -> patches/opentui-0.4.5-freebsd-zig.patch (native, zig)
#                        plus an in-place edit of the installed bundle (JS)
#   @ff-labs/fff-bun  -> patches/fff-bun-freebsd.patch
#
# Pipeline: toolchain -> checkout -> native libs -> binary (build.ts) ->
# validate -> release package (tarball + SHA256SUMS + BUILD-INFO.txt).
#
# Usage:
#   sh build.sh [options]
#     --skip-natives       reuse the native libs already in node_modules
#                          (previous run finished stage 1; implies --skip-install
#                          for the opencode build, so bun won't reinstall)
#     --skip-embed-web-ui  fallback only: build without the embedded web UI
#                          if the primary build fails on it
#     --natives-only       stop after the native libraries + source smoke test
#     -h, --help           show this help
#
# Environment:
#   OC_SRC      opencode checkout            (default: $HOME/opencode-src)
#   OC_WORK     native build workspace       (default: $HOME/native)
#   OC_REF      opencode git ref to clone    (default: upstream default branch tip)
#   OC_RELEASES release output directory     (default: $HOME/opencode-releases)
#   ZIG015      path to a zig 0.15.2 binary  (default: $OC_WORK/zig015/zig;
#               fetched automatically on amd64 if missing)
#   ZIG015_URL  override the zig 0.15.2 tarball URL (e.g. for other arches)
#
# Requirements (install once with pkg):
#   pkg install git python3 rust node npm-node24 llvm ca_root_nss
# Bun comes from the official @oven/bun-freebsd-x64 npm package (see below).
# On FreeBSD 15.x a bun linked against 14.3 may also want compat14x-amd64.
set -e

OC_SRC="${OC_SRC:-$HOME/opencode-src}"
OC_WORK="${OC_WORK:-$HOME/native}"
OC_RELEASES="${OC_RELEASES:-$HOME/opencode-releases}"
PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/sbin:/usr/sbin
export PATH

SKIP_NATIVES=0
SKIP_EMBED_WEB_UI=0
NATIVES_ONLY=0

for arg in "$@"; do
	case "$arg" in
		--skip-natives) SKIP_NATIVES=1 ;;
		--skip-embed-web-ui) SKIP_EMBED_WEB_UI=1 ;;
		--natives-only) NATIVES_ONLY=1 ;;
		-h|--help) sed -n '2,44p' "$0"; exit 0 ;;
		*) echo "build.sh: unknown option: $arg (see --help)" >&2; exit 2 ;;
	esac
done

PATCHES="$(cd "$(dirname "$0")/patches" && pwd)"
ARCH="$(uname -m)"

say() { echo "=== $*"; }
die() { echo "build.sh: FATAL: $*" >&2; exit 1; }

# --- 0. Toolchain ------------------------------------------------------------
# zig 0.16.0 (pkg) builds opentui main but NOT the 0.4.5 tree opencode pins --
# 0.4.5 needs 0.15.2 exactly (see patches/opentui-0.4.5-freebsd-zig.patch).
ZIG015="${ZIG015:-${OC_WORK}/zig015/zig}"

say "toolchain (arch=${ARCH})"
for t in git python3 cargo node npm cc; do
	command -v "$t" >/dev/null 2>&1 || die "$t missing (pkg install git python3 rust node npm-node24 llvm ca_root_nss)"
done

if ! command -v bun >/dev/null 2>&1; then
	say "installing bun (official FreeBSD build from npm)"
	if [ "$(id -u)" -ne 0 ]; then
		die "bun not found and not running as root -- either install bun first or re-run as root so it can be installed to /usr/local/bin"
	fi
	# If bun dies at startup with 'Shared object "libutil.so.9" not found',
	# it targets FreeBSD 14.3: pkg install compat14x-amd64. (Upstream already
	# links libutil statically -- oven-sh/bun#40532 -- so this fades away.)
	pkg install -y compat14x-amd64 2>/dev/null || true
	mkdir -p "${OC_WORK}/bunpkg"
	(cd "${OC_WORK}/bunpkg" && npm pack @oven/bun-freebsd-x64 >/dev/null && tar xzf ./*.tgz)
	install -m 755 "${OC_WORK}"/bunpkg/package/bin/bun /usr/local/bin/bun
fi
bun --version

if [ ! -x "${ZIG015}" ]; then
	[ "${ARCH}" = "amd64" ] || die "no zig 0.15.2 at ${ZIG015} and no prebuilt URL for arch ${ARCH} -- set ZIG015 or ZIG015_URL"
	say "fetching zig 0.15.2 (opencode's pinned opentui 0.4.5 will not build with zig 0.16)"
	ZIG015_URL="${ZIG015_URL:-https://ziglang.org/download/0.15.2/zig-x86_64-freebsd-0.15.2.tar.xz}"
	mkdir -p "${OC_WORK}/zig015"
	fetch -q -o /tmp/zig015.tar.xz "${ZIG015_URL}"
	tar xJf /tmp/zig015.tar.xz -C "${OC_WORK}/zig015" --strip-components=1
fi
"${ZIG015}" version

# --- 1. opencode checkout + install -------------------------------------------
say "opencode checkout (${OC_SRC})"
mkdir -p "${OC_WORK}"
if [ ! -d "${OC_SRC}" ]; then
	git clone --depth 1 ${OC_REF:+--branch "${OC_REF}"} https://github.com/anomalyco/opencode "${OC_SRC}"
fi
if [ "${SKIP_NATIVES}" -eq 1 ]; then
	say "skipping bun install (reusing node_modules with native libs)"
else
	(cd "${OC_SRC}" && bun install)
fi

if [ "${SKIP_NATIVES}" -eq 0 ]; then

# --- 2. fff (Rust cdylib; the first thing opencode fails on) -----------------
say "fff"
[ -d "${OC_WORK}/fff" ] || git clone --depth 1 https://github.com/dmtrKovalenko/fff "${OC_WORK}/fff"
cd "${OC_WORK}/fff"
git apply --check "${PATCHES}/fff-bun-freebsd.patch" 2>/dev/null &&
	git apply "${PATCHES}/fff-bun-freebsd.patch"
cargo build --release -p fff-c
(cd packages/fff-bun && bun install --silent && bun run build)

FFF_BIN="${OC_SRC}/node_modules/@ff-labs/fff-bin-freebsd-x64"
rm -rf "${OC_SRC}/node_modules/@ff-labs/fff-bun" "${FFF_BIN}"
mkdir -p "${FFF_BIN}"
cp target/release/libfff_c.so "${FFF_BIN}/"
cat > "${FFF_BIN}/package.json" <<'JSON'
{
  "name": "@ff-labs/fff-bin-freebsd-x64",
  "version": "0.0.0",
  "os": ["freebsd"],
  "cpu": ["x64"],
  "main": "libfff_c.so",
  "files": ["libfff_c.so"],
  "license": "MIT"
}
JSON
cp -R packages/fff-bun "${OC_SRC}/node_modules/@ff-labs/fff-bun"
rm -rf "${OC_SRC}/node_modules/@ff-labs/fff-bun/node_modules"
mkdir -p "${OC_SRC}/node_modules/@ff-labs/fff-bun/bin"
cp target/release/libfff_c.so "${OC_SRC}/node_modules/@ff-labs/fff-bun/bin/"

# --- 3. node-pty (C++ N-API addon) -------------------------------------------
say "node-pty"
PTY="${OC_WORK}/ptysrc"
PTY_VER="$(python3 - "${OC_SRC}" <<'PY'
import json,sys,glob,os
# the version bun installed, so the addon matches the JS it will be paired with
root=sys.argv[1]
for p in glob.glob(os.path.join(root,"node_modules/.bun/node_modules/@lydell/node-pty/package.json")):
    print(json.load(open(p))["version"]); break
else:
    print("1.2.0-beta.15")
PY
)"
rm -rf "${PTY}"; mkdir -p "${PTY}"
(cd "${PTY}" && npm pack "node-pty@${PTY_VER}" >/dev/null && tar xzf ./*.tgz)
cd "${PTY}/package"
patch -p1 < "${PATCHES}/node-pty-freebsd.patch"
npm i --ignore-scripts --no-audit --no-fund >/dev/null
npx node-gyp rebuild

PTY_PLAT="${OC_SRC}/node_modules/@lydell/node-pty-freebsd-x64"
rm -rf "${PTY_PLAT}"; mkdir -p "${PTY_PLAT}/prebuilds/freebsd-x64"
cp -R lib "${PTY_PLAT}/lib"
cp build/Release/pty.node "${PTY_PLAT}/prebuilds/freebsd-x64/pty.node"
cat > "${PTY_PLAT}/package.json" <<JSON
{
  "name": "@lydell/node-pty-freebsd-x64",
  "version": "${PTY_VER}",
  "license": "MIT",
  "type": "commonjs",
  "exports": "./lib/index.js",
  "os": ["freebsd"],
  "cpu": ["x64"]
}
JSON

# The top @lydell/node-pty package resolves @lydell/node-pty-$platform-$arch,
# so it needs the freebsd entry in optionalDependencies to stop erroring out.
PTY_TOP="${OC_SRC}/node_modules/@lydell/node-pty"
rm -rf "${PTY_TOP}"; mkdir -p "${PTY_TOP}"
(cd "${OC_WORK}" && rm -rf lydtop && mkdir lydtop && cd lydtop &&
	npm pack @lydell/node-pty >/dev/null && tar xzf ./*.tgz &&
	cp -R package/. "${PTY_TOP}/")
python3 - "${PTY_TOP}/package.json" "${PTY_VER}" <<'PY'
import json,sys
p,ver=sys.argv[1],sys.argv[2]
d=json.load(open(p))
d.setdefault("optionalDependencies",{})["@lydell/node-pty-freebsd-x64"]=ver
json.dump(d,open(p,"w"),indent=2)
PY

# --- 4. opentui native (Zig) -------------------------------------------------
say "opentui native"
OT_VER="$(python3 - "${OC_SRC}" <<'PY'
import json,sys,os
p=os.path.join(sys.argv[1],"node_modules/.bun/node_modules/@opentui/core/package.json")
print(json.load(open(p))["version"])
PY
)"
say "opencode pins @opentui/core ${OT_VER}"
OT="${OC_WORK}/opentui-${OT_VER}"
[ -d "${OT}" ] || git clone --depth 1 --branch "v${OT_VER}" https://github.com/anomalyco/opentui "${OT}"
cd "${OT}"
git apply --check "${PATCHES}/opentui-0.4.5-freebsd-zig.patch" 2>/dev/null &&
	git apply "${PATCHES}/opentui-0.4.5-freebsd-zig.patch"
cd "${OT}/packages/core/src/zig"
"${ZIG015}" build -Doptimize=ReleaseFast

OT_PLAT="${OC_SRC}/node_modules/@opentui/core-freebsd-x64"
rm -rf "${OT_PLAT}"; mkdir -p "${OT_PLAT}"
cp lib/x86_64-freebsd/libopentui.so "${OT_PLAT}/"
cat > "${OT_PLAT}/package.json" <<JSON
{
  "name": "@opentui/core-freebsd-x64",
  "version": "${OT_VER}",
  "type": "module",
  "main": "index.js",
  "module": "index.js",
  "license": "MIT",
  "exports": { ".": { "bun": "./index.bun.js", "import": "./index.js" } },
  "os": ["freebsd"],
  "cpu": ["x64"]
}
JSON
cat > "${OT_PLAT}/index.js" <<'JS'
import { fileURLToPath } from "node:url"

export default fileURLToPath(new URL("./libopentui.so", import.meta.url))
JS
cat > "${OT_PLAT}/index.bun.js" <<'JS'
const module = await import("./libopentui.so", { with: { type: "file" } })

export default module.default
JS

# --- 5. opentui JS resolver --------------------------------------------------
# Patched in the INSTALLED bundle rather than by rebuilding @opentui/core from
# source: opencode pins 0.4.5 and its shipped chunk-*.js are what actually run.
# The equivalent source change is patches/opentui-js-freebsd.patch.
say "opentui JS resolver"
cd "${OC_SRC}/node_modules/.bun/node_modules/@opentui/core"
python3 - <<'PY'
import glob, sys

names_old = '  win32: "opentui.dll"\n};'
names_new = '  win32: "opentui.dll",\n  freebsd: "libopentui.so"\n};'
win_old = '  if (process.platform === "win32") {\n    if (process.arch === "x64") {'
win_new = ('  if (process.platform === "freebsd") {\n'
           '    if (process.arch === "x64") {\n'
           '      return (await import("@opentui/core-freebsd-x64")).default;\n'
           '    }\n  }\n' + win_old)

changed = []
for f in sorted(glob.glob("chunk-bun-*.js") + glob.glob("chunk-node-*.js")):
    s = o = open(f).read()
    if "freebsd" in s:
        continue                      # already patched; keep this idempotent
    s = s.replace(names_old, names_new).replace(win_old, win_new, 1)
    if s != o:
        open(f, "w").write(s)
        changed.append(f)
print("patched:", ", ".join(changed) if changed else "(already patched)")
PY

# --- 6. Verify natives -------------------------------------------------------
say "verify natives"
cd "${OC_SRC}"
bun run --cwd packages/opencode --conditions=browser src/index.ts --version

else
say "natives skipped on request -- expecting them in node_modules already"
fi

if [ "${NATIVES_ONLY}" -eq 1 ]; then
say "done (natives only)"
echo "Run the TUI from source with:"
echo "  cd ${OC_SRC} && bun run --cwd packages/opencode --conditions=browser src/index.ts"
echo "Headless server:  ... src/index.ts serve --port 4096"
exit 0
fi

# --- 7. FreeBSD target for the opencode build --------------------------------
# Upstream packages/opencode/script/build.ts has no freebsd entry in allTargets.
# Add it (idempotent) so `build.ts --single` emits opencode-freebsd-x64.
say "freebsd build target"
python3 - "${OC_SRC}/packages/opencode/script/build.ts" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if '"freebsd"' not in s and "'freebsd'" not in s and 'freebsd' not in s:
    old = '    avx2: false,\n  },\n]'
    new = '    avx2: false,\n  },\n  {\n    os: "freebsd",\n    arch: "x64",\n  },\n]'
    assert old in s, "allTargets anchor not found -- upstream build.ts changed shape"
    open(p, "w").write(s.replace(old, new))
    print("added freebsd/x64 target to allTargets")
else:
    print("freebsd target already present")
PY

# --- 8. Build the binary -----------------------------------------------------
say "build binary"
cd "${OC_SRC}"
BUILD_ARGS="--single --skip-install"
[ "${SKIP_EMBED_WEB_UI}" -eq 1 ] && BUILD_ARGS="${BUILD_ARGS} --skip-embed-web-ui"
# shellcheck disable=SC2086
bun run packages/opencode/script/build.ts ${BUILD_ARGS}

BIN="packages/opencode/dist/opencode-freebsd-x64/bin/opencode"
[ -x "${BIN}" ] || die "expected binary missing: ${BIN}"

# --- 9. Validate ---------------------------------------------------------------
# The result must be a native FreeBSD ELF -- never the bin/opencode Node launcher.
say "validate ${BIN}"
file "${BIN}" | tee /tmp/opencode-file-check.txt
grep -q "ELF 64-bit LSB executable.*FreeBSD" /tmp/opencode-file-check.txt ||
	die "not a FreeBSD ELF binary (got: $(cat /tmp/opencode-file-check.txt))"
ldd "${BIN}"
"${BIN}" --version
"${BIN}" --help >/dev/null
if command -v timeout >/dev/null 2>&1; then
	printf 'q' | timeout 15 "${BIN}" --print-logs | head -n 20 || true
	say "(TUI smoke above: logo/session/prompt expected; timeout exit is normal)"
else
	say "(timeout(1) missing -- skipping TUI smoke test)"
fi

# Known non-fatal warning, not a failure:
#   "watcher backend not supported, platform=freebsd" -- the file watcher
#   falls back; sessions and the TUI run normally.

# --- 10. Package ---------------------------------------------------------------
say "package release"
sh "$(cd "$(dirname "$0")" && pwd)/package-release.sh" "${OC_SRC}/${BIN}"

say "done"
echo "Install it with:"
echo "  sh install.sh --releases ${OC_RELEASES}   # newest release"

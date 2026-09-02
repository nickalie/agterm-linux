#!/usr/bin/env bash
# Build the pinned zmx multiplexer — what Live sessions keeps each pane's process inside — into
# agterm-linux/vendor/zmx.
#
# zmx pins `minimum_zig_version` 0.16.0 while the pinned libghostty still builds with 0.15.2, so this
# resolves its OWN compiler instead of sharing setup-linux.sh's. The two are independent builds; nothing
# is gained by forcing them onto one toolchain, and moving the libghostty pin to reach 0.16 would mean
# rebasing three local patches.
#
# The STAMP decides a rebuild, not the binary: a zmx built from another revision is indistinguishable
# from a current one, so a ZMX_REV change costs exactly one rebuild and nobody keeps a stale one.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/agterm-linux/vendor/zmx"
STAMP="$VENDOR/.zmx-build-stamp"
# shellcheck source=../linux/zmx.env
source "$ROOT/linux/zmx.env"

if [[ -x "$VENDOR/zmx" && -f "$VENDOR/LICENSE" && -f "$STAMP" && "$(cat "$STAMP")" == "$ZMX_REV" ]]; then
  echo "pinned zmx already vendored at $VENDOR"
  exit 0
fi

for command in git tar; do
  command -v "$command" >/dev/null || { echo "$command is required to vendor zmx" >&2; exit 1; }
done

zig_matches() {
  [[ -x "$1" ]] && [[ "$("$1" version 2>/dev/null)" == "$ZMX_ZIG_VERSION" ]]
}

ZIG="${ZMX_ZIG:-}"
if ! zig_matches "$ZIG"; then
  ZIG="$(command -v "zig-$ZMX_ZIG_VERSION" || true)"
fi
if ! zig_matches "$ZIG"; then
  ZIG="$(command -v zig || true)"
fi
if ! zig_matches "$ZIG" && command -v mise >/dev/null; then
  ZIG="$(mise where "zig@$ZMX_ZIG_VERSION" 2>/dev/null || true)/bin/zig"
fi
if ! zig_matches "$ZIG"; then
  cat >&2 <<MSG
zig $ZMX_ZIG_VERSION is required to build zmx and was not found.

Point ZMX_ZIG at it, put a zig-$ZMX_ZIG_VERSION on PATH, or install it with
  mise install zig@$ZMX_ZIG_VERSION
The libghostty build keeps its own zig 0.15.2; the two do not share one.
MSG
  exit 1
fi

BUILD_DIR="$(mktemp -d)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR" "$STAGE"' EXIT

echo "fetching zmx $ZMX_REV..."
git init -q "$BUILD_DIR"
git -C "$BUILD_DIR" remote add origin "$ZMX_REPO"
git -C "$BUILD_DIR" fetch -q --depth 1 origin "$ZMX_REV"
git -C "$BUILD_DIR" -c advice.detachedHead=false checkout -q FETCH_HEAD
[[ "$(git -C "$BUILD_DIR" rev-parse HEAD)" == "$ZMX_REV" ]]

echo "building zmx..."
# The same glibc floor the libghostty build targets, so one payload runs on every supported distribution.
(cd "$BUILD_DIR" && "$ZIG" build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu.2.39)

install -Dm755 "$BUILD_DIR/zig-out/bin/zmx" "$STAGE/zmx"
install -Dm644 "$BUILD_DIR/LICENSE" "$STAGE/LICENSE"
printf '%s\n' "$ZMX_REV" > "$STAGE/.zmx-build-stamp"

rm -rf "$VENDOR"
mkdir -p "$(dirname "$VENDOR")"
mv "$STAGE" "$VENDOR"
echo "→ vendored zmx $ZMX_REV into $VENDOR"

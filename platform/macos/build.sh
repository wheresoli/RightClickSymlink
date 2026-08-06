#!/usr/bin/env bash
#
# Assemble RightClickSymlink.app without Xcode.
#
# Produces:
#   build/RightClickSymlink.app
#     Contents/MacOS/RightClickSymlink        host app (Swift)
#     Contents/Resources/rcsym                helper (Rust, universal)
#     Contents/PlugIns/FinderSyncExt.appex    Finder extension (Swift)
#
# Requires the Xcode *command line tools* (swiftc, codesign, lipo) but not the
# Xcode IDE. Run from anywhere:  ./platform/macos/build.sh
#
# Signing: ad-hoc by default, which is enough to run it on the machine that
# built it. For anything else set IDENTITY to a Developer ID:
#
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$HERE/build"
APP="$BUILD/RightClickSymlink.app"
APPEX="$APP/Contents/PlugIns/FinderSyncExt.appex"

IDENTITY="${IDENTITY:--}"          # "-" means ad-hoc
DEPLOY_TARGET="11.0"
ARCHS=("arm64" "x86_64")

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. The Rust helper, universal
# ---------------------------------------------------------------------------

say "Building the rcsym helper"
RUST_BINS=()
for arch in "${ARCHS[@]}"; do
    case "$arch" in
        arm64)  triple="aarch64-apple-darwin" ;;
        x86_64) triple="x86_64-apple-darwin"  ;;
    esac
    rustup target add "$triple" >/dev/null 2>&1 || true
    ( cd "$ROOT" && cargo build --release --target "$triple" --bin rcsym )
    RUST_BINS+=("$ROOT/target/$triple/release/rcsym")
done

# ---------------------------------------------------------------------------
# 2. Bundle skeleton
# ---------------------------------------------------------------------------

say "Assembling the bundle"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"

cp "$HERE/RightClickSymlink/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/FinderSyncExt/Info.plist"     "$APPEX/Contents/Info.plist"

# Menu icons go in the EXTENSION's Resources, not the host app's -- the
# extension is what builds the menu, and Bundle.main inside it is the appex.
# 32px so a Retina display has full resolution for a 16pt menu item.
mkdir -p "$APPEX/Contents/Resources"
if [ -d "$ROOT/assets/icons/png/32" ]; then
    cp "$ROOT/assets/icons/png/32"/*.png "$APPEX/Contents/Resources/"
    say "Bundled $(ls -1 "$APPEX/Contents/Resources"/*.png | wc -l | tr -d ' ') menu icons"
else
    say "No icons found at assets/icons/png/32 -- menu items will have no image"
fi

lipo -create -output "$APP/Contents/Resources/rcsym" "${RUST_BINS[@]}"
chmod +x "$APP/Contents/Resources/rcsym"

# ---------------------------------------------------------------------------
# 3. Swift
# ---------------------------------------------------------------------------

# Compile one Swift target per architecture and lipo the results. swiftc has no
# single-invocation universal mode.
compile_swift() {
    local out="$1" module="$2" src="$3"
    shift 3
    local extra=("$@")
    local slices=()
    local slice

    for arch in "${ARCHS[@]}"; do
        slice="$BUILD/.$module.$arch"
        swiftc \
            -target "${arch}-apple-macos${DEPLOY_TARGET}" \
            -module-name "$module" \
            -O \
            -o "$slice" \
            "$src" \
            "${extra[@]}"
        slices+=("$slice")
    done

    lipo -create -output "$out" "${slices[@]}"
    rm -f "${slices[@]}"
}

say "Compiling the Finder extension"
# -e _NSExtensionMain is the part that is easy to miss: an app extension has no
# main() of its own, and without an explicit entry point the linker fails or
# produces a binary macOS will not load.
compile_swift \
    "$APPEX/Contents/MacOS/FinderSyncExt" \
    "FinderSyncExt" \
    "$HERE/FinderSyncExt/FinderSync.swift" \
    -framework Cocoa -framework FinderSync \
    -Xlinker -e -Xlinker _NSExtensionMain

say "Compiling the host app"
compile_swift \
    "$APP/Contents/MacOS/RightClickSymlink" \
    "RightClickSymlink" \
    "$HERE/RightClickSymlink/main.swift" \
    -framework Cocoa

# ---------------------------------------------------------------------------
# 4. Sign
# ---------------------------------------------------------------------------

# Inside out: nested code must be signed before whatever contains it, or the
# outer signature is invalidated the moment the inner one is written.
say "Signing (identity: $IDENTITY)"

codesign --force --sign "$IDENTITY" \
    --options runtime \
    "$APP/Contents/Resources/rcsym"

codesign --force --sign "$IDENTITY" \
    --entitlements "$HERE/FinderSyncExt/FinderSyncExt.entitlements" \
    --options runtime \
    "$APPEX"

codesign --force --sign "$IDENTITY" \
    --entitlements "$HERE/RightClickSymlink/RightClickSymlink.entitlements" \
    --options runtime \
    "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

# ---------------------------------------------------------------------------

cat <<EOF

Built: $APP

Install and enable:

  1. cp -R "$APP" /Applications/
  2. open /Applications/RightClickSymlink.app     (registers the extension)
  3. System Settings > General > Login Items & Extensions > Finder Extensions
     and switch on "Right Click Symlink"

If the menu items do not appear, kick the extension host:

  pluginkit -m -i com.rightclicksymlink.app.FinderSyncExt   # is it registered?
  killall Finder

EOF

#!/usr/bin/env bash
#
# Install Right Click Symlink for the current user, on macOS or Linux.
#
#   ./install.sh                 install
#   ./install.sh --relative      links store relative paths
#   ./install.sh --uninstall     remove it
#
# Or without cloning anything:
#
#   curl -fsSL https://raw.githubusercontent.com/wheresoli/RightClickSymlink/main/install.sh | bash
#
# Everything lands under $HOME. No sudo, nothing outside your profile.
#
#   Linux   binary   ~/.local/bin/rcsym
#           adapters ~/.local/share/{nautilus-python,kio,nemo}, ~/.config/Thunar
#   macOS   app      ~/Applications/RightClickSymlink.app
#
# Works three ways, picked automatically: from a repo checkout, from an
# unpacked release, or by downloading the latest release.
#
set -euo pipefail

REPO="wheresoli/RightClickSymlink"
PREFIX="${PREFIX:-$HOME/.local}"
MACOS_APPDIR="${MACOS_APPDIR:-$HOME/Applications}"

RELATIVE=0
UNINSTALL=0
KIND="symlink"

step() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m    %s\033[0m\n' "$*"; }
info() { printf '\033[2m    %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --relative)  RELATIVE=1; shift ;;
        --kind)      KIND="$2"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        --prefix)    PREFIX="$2"; shift 2 ;;
        -h|--help)   sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

case "$(uname -s)" in
    Darwin) OS=macos ;;
    Linux)  OS=linux ;;
    *)      die "unsupported platform: $(uname -s). Windows users want install.ps1." ;;
esac

# Baked into every menu entry. A context menu cannot carry per-click options,
# so preferences are fixed at install time -- the same arrangement as the
# Windows registry verbs.
FLAGS="--kind $KIND"
if [ "$RELATIVE" -eq 1 ]; then
    FLAGS="$FLAGS --relative"
fi

# Where this script lives, or empty when piped from curl -- which is precisely
# the case where there is nothing local and we should download.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    HERE=""
fi

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if [ "$UNINSTALL" -eq 1 ]; then
    step "Uninstalling"

    if [ "$OS" = macos ]; then
        for dir in "$MACOS_APPDIR" /Applications; do
            if [ -d "$dir/RightClickSymlink.app" ]; then
                rm -rf "$dir/RightClickSymlink.app"
                ok "removed $dir/RightClickSymlink.app"
            fi
        done
        # Otherwise the extension lingers in System Settings until next login.
        pkill -x "RightClickSymlink" 2>/dev/null || true
        killall Finder 2>/dev/null || true
        info "the Finder Extensions entry disappears once Finder restarts"
    else
        ADAPTERS=""
        for candidate in "$HERE/platform/linux/install-adapters.sh" \
                         "$HERE/integration/install-adapters.sh" \
                         "$PREFIX/share/rcsym/install-adapters.sh"; do
            [ -f "$candidate" ] && { ADAPTERS="$candidate"; break; }
        done
        if [ -n "$ADAPTERS" ]; then
            "$ADAPTERS" --uninstall
        else
            warn "adapter uninstaller not found; removing files directly"
            DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
            rm -f "$DATA/nautilus-python/extensions/rcsym-nautilus.py" \
                  "$DATA"/kio/servicemenus/rcsym-symlink-*.desktop \
                  "$DATA"/nemo/actions/rcsym-symlink-*.nemo_action
        fi
        rm -rf "$PREFIX/share/rcsym"
        rm -f "$PREFIX/bin/rcsym" && ok "removed $PREFIX/bin/rcsym"
    fi

    echo
    ok "Uninstalled."
    info "Symlinks you already created are untouched. They are ordinary"
    info "filesystem objects with no connection to the tool that made them."
    exit 0
fi

# ---------------------------------------------------------------------------
# Find the payload
# ---------------------------------------------------------------------------

step "Locating build"

SOURCE=""
DOWNLOADED=""

if [ -n "$HERE" ]; then
    if [ "$OS" = macos ]; then
        for c in "$HERE/platform/macos/build" "$HERE"; do
            [ -d "$c/RightClickSymlink.app" ] && { SOURCE="$c"; break; }
        done
    else
        for c in "$HERE/target/release" "$HERE"; do
            [ -x "$c/rcsym" ] && { SOURCE="$c"; break; }
        done
    fi
fi

# On macOS, a checkout with no bundle but with the build script can just build.
if [ -z "$SOURCE" ] && [ "$OS" = macos ] && [ -n "$HERE" ] && [ -x "$HERE/platform/macos/build.sh" ]; then
    info "no bundle found, building it"
    "$HERE/platform/macos/build.sh"
    SOURCE="$HERE/platform/macos/build"
fi

if [ -z "$SOURCE" ]; then
    info "no local build found, fetching the latest release"
    command -v curl >/dev/null 2>&1 || die "curl is required to download a release"

    case "$OS" in
        macos) PATTERN="macos" ;;
        linux) PATTERN="linux" ;;
    esac

    API="https://api.github.com/repos/$REPO/releases/latest"
    URL="$(curl -fsSL "$API" 2>/dev/null \
        | grep '"browser_download_url"' \
        | grep "$PATTERN" \
        | head -1 \
        | sed 's/.*"\(https[^"]*\)".*/\1/')" || true

    if [ -z "$URL" ]; then
        die "no published release for $OS yet.

Build from source instead:

    git clone https://github.com/$REPO
    cd RightClickSymlink
    cargo build --release
    ./install.sh"
    fi

    DOWNLOADED="$(mktemp -d)"
    trap 'rm -rf "$DOWNLOADED"' EXIT
    info "downloading $(basename "$URL")"
    curl -fsSL "$URL" -o "$DOWNLOADED/payload"

    case "$URL" in
        *.tar.gz) tar -xzf "$DOWNLOADED/payload" -C "$DOWNLOADED" ;;
        *.zip)    unzip -q "$DOWNLOADED/payload" -d "$DOWNLOADED" ;;
        *)        die "unrecognised archive: $URL" ;;
    esac

    # Release archives have one top-level directory.
    # Not piped through xargs: a path with a space in it would be split into
    # two arguments and dirname would report the wrong directory.
    FOUND="$(find "$DOWNLOADED" -maxdepth 2 \( -name 'RightClickSymlink.app' -o -name 'rcsym' \) -print -quit)"
    [ -n "$FOUND" ] || die "could not find the payload inside the archive"
    SOURCE="$(dirname "$FOUND")"
fi

ok "using $SOURCE"

# ---------------------------------------------------------------------------
# macOS
# ---------------------------------------------------------------------------

if [ "$OS" = macos ]; then
    # The Finder front end runs its own dialog and calls `rcsym link` itself,
    # so it never sees these. Warn rather than fail: the install is still
    # worth doing, the user just should not think the option took effect.
    if [ "$RELATIVE" -eq 1 ] || [ "$KIND" != "symlink" ]; then
        warn "--relative and --kind are not plumbed through the Finder extension yet."
        warn "Installing with defaults. Track it at:"
        warn "  https://github.com/$REPO/issues"
    fi

    step "Installing the app"

    mkdir -p "$MACOS_APPDIR"
    rm -rf "$MACOS_APPDIR/RightClickSymlink.app"
    # ditto, not cp: it preserves the bundle's symlinks, extended attributes and
    # code signature. A plain cp -R can invalidate the signature.
    ditto "$SOURCE/RightClickSymlink.app" "$MACOS_APPDIR/RightClickSymlink.app"
    ok "installed to $MACOS_APPDIR/RightClickSymlink.app"

    # A downloaded bundle carries com.apple.quarantine, which makes Gatekeeper
    # refuse an unnotarized app outright. Only strip it for something the user
    # explicitly asked to install.
    if [ -n "$DOWNLOADED" ]; then
        xattr -dr com.apple.quarantine "$MACOS_APPDIR/RightClickSymlink.app" 2>/dev/null || true
        info "cleared the download quarantine flag"
    fi

    step "Registering the Finder extension"
    # Opening it once is what tells the system the extension exists.
    open "$MACOS_APPDIR/RightClickSymlink.app"
    sleep 2
    pluginkit -e use -i com.rightclicksymlink.app.FinderSyncExt 2>/dev/null \
        && ok "extension enabled" \
        || info "could not auto-enable; do it by hand (below)"
    killall Finder 2>/dev/null || true

    echo
    ok "Installed."
    echo
    echo "  Right-click a file or folder   -> Symlink To…"
    echo "  Right-click empty space        -> Symlink From…"
    echo
    info "If the entries do not appear, enable the extension here:"
    info "  System Settings > General > Login Items & Extensions"
    info "  > Finder Extensions > Right Click Symlink"
    echo
    info "Uninstall:  ./install.sh --uninstall"
    exit 0
fi

# ---------------------------------------------------------------------------
# Linux
# ---------------------------------------------------------------------------

step "Installing the binary"

mkdir -p "$PREFIX/bin"
install -m 755 "$SOURCE/rcsym" "$PREFIX/bin/rcsym"
ok "installed $PREFIX/bin/rcsym"

case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) warn "$PREFIX/bin is not on your PATH; add it to run rcsym from a terminal" ;;
esac

step "Installing file-manager adapters"

ADAPTERS=""
for candidate in "$HERE/platform/linux/install-adapters.sh" \
                 "$SOURCE/../integration/install-adapters.sh" \
                 "$SOURCE/integration/install-adapters.sh"; do
    [ -n "$candidate" ] && [ -f "$candidate" ] && { ADAPTERS="$candidate"; break; }
done
[ -n "$ADAPTERS" ] || die "could not find install-adapters.sh"

# Keep a copy so --uninstall works later from anywhere.
mkdir -p "$PREFIX/share/rcsym"
cp -r "$(dirname "$ADAPTERS")"/* "$PREFIX/share/rcsym/" 2>/dev/null || true
chmod +x "$PREFIX/share/rcsym/install-adapters.sh" 2>/dev/null || true

"$ADAPTERS" --bin "$PREFIX/bin/rcsym" --flags "$FLAGS"

echo
ok "Installed."
echo
echo "  Right-click a file or folder   -> Symlink To…"
echo "  Right-click empty space        -> Symlink From…"
echo
info "Dolphin and Thunar attach 'Symlink From' to folders rather than to empty"
info "space -- see platform/linux/README.md for why. Behaviour is identical."
echo
info "Uninstall:  ./install.sh --uninstall"

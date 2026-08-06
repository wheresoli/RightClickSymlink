#!/usr/bin/env bash
#
# Install Right Click Symlink into whichever file managers are present.
#
#   ./install-adapters.sh                        auto-detect, use ./target/release/rcsym
#   ./install-adapters.sh --bin /usr/bin/rcsym   use a specific binary
#   ./install-adapters.sh --only nautilus        just one file manager
#   ./install-adapters.sh --uninstall            remove everything
#
# Everything is written under $HOME. No root, no system directories.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

RCSYM=""
ONLY=""
UNINSTALL=0

# Extra rcsym flags baked into every menu entry. A context menu cannot carry
# per-click options, so preferences are fixed at install time -- same as the
# Windows registry verbs.
FLAGS="${FLAGS:-}"

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"

NAUTILUS_DIR="$DATA/nautilus-python/extensions"
KDE_DIR="$DATA/kio/servicemenus"
NEMO_DIR="$DATA/nemo/actions"
THUNAR_UCA="$CONFIG/Thunar/uca.xml"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }
warn()  { printf '\033[33mwarning:\033[0m %s\n' "$*"; }
say()   { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --bin)       RCSYM="$2"; shift 2 ;;
        --only)      ONLY="$2";  shift 2 ;;
        --flags)     FLAGS="$2"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

wanted() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

# ---------------------------------------------------------------------------
# Locate the binary
# ---------------------------------------------------------------------------

if [ "$UNINSTALL" -eq 0 ]; then
    if [ -z "$RCSYM" ]; then
        if [ -x "$ROOT/target/release/rcsym" ]; then
            RCSYM="$ROOT/target/release/rcsym"
        elif command -v rcsym >/dev/null 2>&1; then
            RCSYM="$(command -v rcsym)"
        else
            cat >&2 <<EOF
error: cannot find the rcsym binary.

Build it:
    cargo build --release

Or point at one:
    ./install-adapters.sh --bin /path/to/rcsym
EOF
            exit 1
        fi
    fi
    RCSYM="$(cd "$(dirname "$RCSYM")" && pwd)/$(basename "$RCSYM")"
    [ -x "$RCSYM" ] || { echo "error: $RCSYM is not executable" >&2; exit 1; }
    say "Using $RCSYM"
fi

# Substitute the binary path and the baked-in flags into a template.
#
# The trailing-whitespace strip matters when FLAGS is empty: templates end with
# " @FLAGS@", which would otherwise leave "Exec=rcsym to %F " with a dangling
# space.
render() {
    sed -e "s|@RCSYM@|$RCSYM|g" -e "s|@FLAGS@|$FLAGS|g" -e 's/[[:space:]]*$//' "$1" > "$2"
}

# ---------------------------------------------------------------------------
# Nautilus  (GNOME Files)
# ---------------------------------------------------------------------------

do_nautilus() {
    wanted nautilus || return 0
    command -v nautilus >/dev/null 2>&1 || return 0
    say "Nautilus"

    local dest="$NAUTILUS_DIR/rcsym-nautilus.py"
    if [ "$UNINSTALL" -eq 1 ]; then
        rm -f "$dest" && dim "  removed $dest"
        return 0
    fi

    # nautilus-python is a separate package and the extension is inert without
    # it, so say so rather than installing something that silently does nothing.
    if ! python3 -c "
import gi
try:
    gi.require_version('Nautilus', '4.0')
except ValueError:
    gi.require_version('Nautilus', '3.0')
" 2>/dev/null; then
        warn "nautilus-python not found -- the extension will not load."
        warn "  Debian/Ubuntu: sudo apt install python3-nautilus"
        warn "  Fedora:        sudo dnf install nautilus-python"
        warn "  Arch:          sudo pacman -S python-nautilus"
    fi

    mkdir -p "$NAUTILUS_DIR"
    render "$HERE/nautilus/rcsym-nautilus.py" "$dest"
    green "  installed $dest"
}

# ---------------------------------------------------------------------------
# Dolphin  (KDE)
# ---------------------------------------------------------------------------

do_dolphin() {
    wanted dolphin || return 0
    command -v dolphin >/dev/null 2>&1 || return 0
    say "Dolphin"

    if [ "$UNINSTALL" -eq 1 ]; then
        rm -f "$KDE_DIR"/rcsym-symlink-*.desktop && dim "  removed $KDE_DIR/rcsym-symlink-*.desktop"
        # Clean up the pre-5.85 location too, in case an old install is there.
        rm -f "$DATA/kservices5/ServiceMenus"/rcsym-symlink-*.desktop 2>/dev/null || true
        return 0
    fi

    mkdir -p "$KDE_DIR"
    local dest
    for f in "$HERE"/dolphin/*.desktop; do
        dest="$KDE_DIR/$(basename "$f")"
        render "$f" "$dest"
        # Plasma 5.85 and later refuse to load service menus that are not
        # marked executable.
        chmod +x "$dest"
        green "  installed $dest"
    done
}

# ---------------------------------------------------------------------------
# Nemo  (Cinnamon)
# ---------------------------------------------------------------------------

do_nemo() {
    wanted nemo || return 0
    command -v nemo >/dev/null 2>&1 || return 0
    say "Nemo"

    if [ "$UNINSTALL" -eq 1 ]; then
        rm -f "$NEMO_DIR"/rcsym-symlink-*.nemo_action && dim "  removed $NEMO_DIR/rcsym-symlink-*.nemo_action"
        return 0
    fi

    mkdir -p "$NEMO_DIR"
    local dest
    for f in "$HERE"/nemo/*.nemo_action; do
        dest="$NEMO_DIR/$(basename "$f")"
        render "$f" "$dest"
        green "  installed $dest"
    done
}

# ---------------------------------------------------------------------------
# Thunar  (XFCE)
# ---------------------------------------------------------------------------

do_thunar() {
    wanted thunar || return 0
    command -v thunar >/dev/null 2>&1 || return 0
    say "Thunar"

    # Thunar keeps every custom action in one shared file, so this is a merge
    # rather than a file copy. Actions are matched by <unique-id> so that
    # re-running is idempotent and anything the user added by hand survives.
    mkdir -p "$(dirname "$THUNAR_UCA")"
    UCA="$THUNAR_UCA" SNIPPET="$HERE/thunar/uca-snippet.xml" \
    BIN="${RCSYM:-}" RCFLAGS="$FLAGS" REMOVE="$UNINSTALL" python3 <<'PY'
import os
import xml.etree.ElementTree as ET

uca     = os.environ["UCA"]
snippet = os.environ["SNIPPET"]
binary  = os.environ["BIN"]
flags   = os.environ.get("RCFLAGS", "")
remove  = os.environ["REMOVE"] == "1"

if os.path.exists(uca):
    tree = ET.parse(uca)
    root = tree.getroot()
else:
    root = ET.Element("actions")
    tree = ET.ElementTree(root)

def uid(action):
    node = action.find("unique-id")
    return node.text if node is not None else ""

# Drop any previous rcsym actions first; this is what makes re-running safe.
for action in list(root.findall("action")):
    if uid(action).startswith("rcsym-"):
        root.remove(action)

if not remove:
    for action in ET.parse(snippet).getroot().findall("action"):
        cmd = action.find("command")
        # Both placeholders. This path does its own substitution rather than
        # going through render(), so a new placeholder has to be added here too.
        cmd.text = cmd.text.replace("@RCSYM@", binary).replace("@FLAGS@", flags)
        cmd.text = " ".join(cmd.text.split())
        root.append(action)

ET.indent(tree, space="  ")
tree.write(uca, encoding="UTF-8", xml_declaration=True)
print(("  removed rcsym actions from " if remove else "  merged into ") + uca)
PY
}

# ---------------------------------------------------------------------------

do_nautilus
do_dolphin
do_nemo
do_thunar

# ---------------------------------------------------------------------------
# Reload
# ---------------------------------------------------------------------------

say "Reloading file managers"
# Nautilus and Nemo load extensions once at startup; Dolphin and Thunar pick up
# their declarative files on the next menu open, so they need no restart.
if pkill -x nautilus 2>/dev/null; then dim "  restarted nautilus"; fi
if pkill -x nemo     2>/dev/null; then dim "  restarted nemo";     fi

echo
if [ "$UNINSTALL" -eq 1 ]; then
    green "Uninstalled."
    dim "Links you already created are untouched -- they are ordinary filesystem"
    dim "objects with no connection to the tool that made them."
else
    green "Done."
    echo
    echo "  Right-click a file or folder   -> Symlink To…"
    echo "  Right-click empty space        -> Symlink From…"
    echo
    dim "Dolphin and Thunar attach 'Symlink From' to folders rather than to empty"
    dim "space -- see README.md for why. The behaviour is identical."
    echo
    "$RCSYM" probe
fi

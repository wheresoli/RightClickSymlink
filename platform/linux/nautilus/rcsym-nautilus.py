"""
Nautilus (GNOME Files) menu provider for Right Click Symlink.

Install to ~/.local/share/nautilus-python/extensions/ and restart Nautilus.
Requires the nautilus-python bindings:

    Debian/Ubuntu   sudo apt install python3-nautilus
    Fedora          sudo dnf install nautilus-python
    Arch            sudo pacman -S python-nautilus

The @RCSYM@ placeholder is replaced with an absolute path by install.sh.
"""

import os
import subprocess
from urllib.parse import unquote, urlparse

import gi

# Nautilus 4.x (GNOME 43+) and 3.x expose different typelib versions, and
# require_version raises if the requested one is absent. Try new first.
try:
    gi.require_version("Nautilus", "4.0")
except ValueError:
    gi.require_version("Nautilus", "3.0")

from gi.repository import GObject, Nautilus  # noqa: E402

RCSYM = "@RCSYM@"

# Baked in at install time. A context menu has no way to carry per-click
# options, so the defaults are fixed when the adapter is written. Empty string
# splits to [], so an install with no flags adds no arguments.
FLAGS = "@FLAGS@".split()


def local_path(file_info):
    """Absolute path for a Nautilus file, or None if it is not local.

    Trash, recent, network shares and MTP devices all appear in Nautilus but
    have no real path, and a symlink to them would be meaningless. Returning
    None here is what keeps the menu entry from appearing in those places.
    """
    uri = file_info.get_uri()
    parts = urlparse(uri)
    if parts.scheme != "file":
        return None
    return unquote(parts.path)


def launch(*args):
    """Fire off rcsym and return immediately.

    Nautilus is blocked while a menu callback runs, so waiting for the dialog
    would freeze the whole file manager until the user finished. Popen without
    a wait is deliberate.
    """
    try:
        subprocess.Popen([RCSYM, *args], start_new_session=True)
    except OSError as exc:
        print(f"rcsym: could not launch {RCSYM}: {exc}")


class RcsymMenuProvider(GObject.GObject, Nautilus.MenuProvider):
    """Adds 'Symlink To...' to items and a 'Symlink From' submenu to folder
    backgrounds."""

    # Nautilus 3.x called these with (window, files); Nautilus 4.x dropped the
    # window argument. Taking *args and reading the last element works on both
    # without version sniffing.

    def get_file_items(self, *args):
        files = args[-1]
        paths = [p for p in (local_path(f) for f in files) if p]
        if not paths:
            return []

        item = Nautilus.MenuItem(
            name="Rcsym::SymlinkTo",
            label="Symlink To…",
            tip="Create a symlink to this somewhere else",
            icon="rcsym-folder-to",
        )
        item.connect("activate", lambda _menu: launch("to", *paths, *FLAGS))
        return [item]

    def get_background_items(self, *args):
        folder = args[-1]
        path = local_path(folder)
        if not path or not os.path.isdir(path):
            return []

        # A submenu rather than two top-level entries: the background menu is
        # short and shared with Nautilus's own actions, so two extra items at
        # the top level is noticeably intrusive.
        root = Nautilus.MenuItem(
            name="Rcsym::SymlinkFrom",
            label="Symlink From",
            tip="Create a link here, pointing at something else",
            icon="rcsym-folder-from",
        )
        submenu = Nautilus.Menu()
        root.set_submenu(submenu)

        for label, pick in (("Folder…", "folder"), ("File…", "file")):
            entry = Nautilus.MenuItem(
                name=f"Rcsym::SymlinkFrom::{pick}",
                label=label,
                icon=f"rcsym-{pick}-from",
            )
            entry.connect(
                "activate",
                lambda _menu, pick=pick: launch(
                    "from", "--dir", path, "--pick", pick, *FLAGS
                ),
            )
            submenu.append_item(entry)

        return [root]

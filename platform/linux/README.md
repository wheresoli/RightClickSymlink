# Linux

Not stupid — but the most fragmented. There is no such thing as "the Linux
context menu"; each file manager has its own mechanism, so this is one small
adapter per file manager over the same binary.

> **Not tested on this machine.** Written on Windows. The Rust core underneath
> is tested and working; the four adapters are unexercised.

## Set expectations first

Nautilus's "Make Link" and Dolphin's paste-as-link already create **genuine
symlinks**. Unlike macOS — where Finder only gives you aliases, which the POSIX
layer cannot follow — Linux is not missing this capability.

So the value here is narrower: a dialog that lets you choose the destination,
the name, and absolute-vs-relative in one step, instead of make-link-then-
move-then-rename. Worth having, but this is a convenience, not a gap-filler.

```bash
./platform/linux/install.sh
```

Detects what you have installed, writes everything under `$HOME`, needs no root.

```bash
./platform/linux/install.sh --uninstall
```

## What gets installed where

| File manager | Location | Mechanism |
|---|---|---|
| **Nautilus** (GNOME) | `~/.local/share/nautilus-python/extensions/` | Python `Nautilus.MenuProvider` |
| **Dolphin** (KDE) | `~/.local/share/kio/servicemenus/` | Declarative `.desktop` |
| **Nemo** (Cinnamon) | `~/.local/share/nemo/actions/` | Declarative `.nemo_action` |
| **Thunar** (XFCE) | `~/.config/Thunar/uca.xml` | Merged into a shared XML file |

## The background-click problem

The design puts "Symlink From…" on the *background* menu — right-click empty
space inside the destination folder. Only two of the four can express that.

**Nautilus** has `get_background_items()`, a separate callback from
`get_file_items()`. Clean.

**Nemo** has `Selection=none`, which means "show when nothing is selected".
`%P` then gives the folder being viewed. Also clean.

**Dolphin and Thunar** cannot. Thunar custom actions require a selection, full
stop. Dolphin's handling of service menus on the empty-area click has shifted
between Plasma releases and is not something to rely on.

So on those two, "Symlink From…" attaches to **folders** instead: you
right-click the destination folder rather than empty space inside it. The path
becomes `--dir` either way, the link is still created as a child of that folder,
and the folder itself is still never touched. Only the gesture differs.

## Folder or file?

Windows and Linux native pickers cannot offer files and folders in the same
dialog, so "Symlink From" is two entries — `Folder…` and `File…` — grouped in a
submenu. macOS gets a single entry because `NSOpenPanel` can do both at once.

## Per-file-manager notes

### Nautilus

Needs the `nautilus-python` bindings, which are a separate package. Without them
the extension file sits there doing nothing, so `install.sh` checks and warns.

```bash
sudo apt install python3-nautilus     # Debian/Ubuntu
```

```bash
sudo dnf install nautilus-python      # Fedora
```

```bash
sudo pacman -S python-nautilus        # Arch
```

The provider takes `*args` and reads the last element because Nautilus 3.x
passed `(window, files)` and 4.x passes just `(files)`. That absorbs both
without version detection.

Extensions load once at startup — `install.sh` runs `pkill -x nautilus` for you.

### Dolphin

Plasma 5.85 moved service menus from `~/.local/share/kservices5/ServiceMenus/`
to `~/.local/share/kio/servicemenus/`, and started requiring that the `.desktop`
files be **executable**. `install.sh` writes to the new path, chmods them, and
cleans up the old location on uninstall.

No restart needed; Dolphin reads them on the next menu open.

### Nemo

The only one of the four with a first-class background-menu concept. No
gotchas.

### Thunar

Every custom action lives in the single file `~/.config/Thunar/uca.xml`, so
installing is a merge rather than a copy. The script matches on `<unique-id>`
prefixed `rcsym-`, removes those, then re-appends — idempotent, and anything you
added via **Edit › Configure custom actions…** survives.

## Non-local paths

The Nautilus provider returns `None` for anything whose URI scheme is not
`file:`. Trash, `recent:`, network shares and MTP devices all show up in a file
manager but have no real path, and the menu entry is suppressed there rather
than offering a link that cannot be made.

## Adding another file manager

The whole contract is three command lines:

```bash
rcsym to /path/to/target                            # item menu
```

```bash
rcsym from --dir /path/to/folder --pick folder      # background menu
```

```bash
rcsym link --target X --into Y --name Z --no-confirm  # headless, no dialogs
```

PCManFM, Caja and Krusader all have their own action formats and would each be a
handful of lines. Nothing above the CLI boundary is platform-specific.

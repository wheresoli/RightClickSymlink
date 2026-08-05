# Windows

The awkward platform, mostly for reasons that have nothing to do with links
themselves.

## Install

```powershell
cargo build --release
```

```powershell
.\platform\windows\register.ps1
```

No administrator rights needed — everything is written under
`HKCU:\Software\Classes`. To remove:

```powershell
.\platform\windows\unregister.ps1
```

Options:

```powershell
.\platform\windows\register.ps1 -Relative -Kind symlink -ExePath C:\Tools\rcsymw.exe
```

The context menu cannot carry per-click preferences, so `-Relative` and `-Kind`
are baked into the registered command lines at install time.

## Where the entries appear

| | Registry key | Menu |
|---|---|---|
| Symlink To… | `*\shell` and `Directory\shell` | Right-click a file or folder |
| Symlink From Folder/File… | `Directory\Background\shell` | Right-click empty space in a folder |

**On Windows 11 these live under "Show more options"** (or <kbd>Shift</kbd>+<kbd>F10</kbd>).
Registry verbs are legacy verbs, and the short Windows 11 menu only accepts
packaged apps implementing `IExplorerCommand`. See [msix/README.md](msix/README.md)
— that path is scaffolded but the COM DLL is unwritten, and it is genuinely the
biggest remaining chunk of work in the project.

## Three traps this code already handles

**`%1` is empty for a Background verb.** You must use `%V` to receive the
current directory. Get it wrong and the menu entry appears, fires, and receives
nothing — with no error. `register.ps1` uses `%V` for the two background verbs
and `%1` for the item verbs.

**Multi-select spawns one process per file.** Selecting twelve files and
clicking a plain registry verb launches twelve processes. `MultiSelectModel`
set to `Player` hands the whole selection to a single invocation instead.
Explorer stops honouring the verb above roughly fifteen selected items; that is
a shell limit and cannot be raised.

**A console subsystem binary flashes a window.** That is why there are two
binaries. `rcsymw.exe` is built with `windows_subsystem = "windows"` and is what
the registry points at; `rcsym.exe` is the console build for scripting and
`probe`. Same code, one `run()`.

## Symlink privilege

`CreateSymbolicLinkW` needs `SeCreateSymbolicLinkPrivilege`. There are three
ways to have it:

1. **Developer Mode on** (Settings › System › For developers) plus the
   `SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE` flag. This is the good path
   and the one the code always tries first.
2. **Run elevated.**
3. **Neither** — and then symlinks are simply unavailable.

Check which situation you are in:

```powershell
.\target\release\rcsym.exe probe
```

```json
{
  "platform": "windows",
  "symlink_unprivileged": true,
  "junction": true,
  "hardlink": true,
  "developer_mode": true,
  "elevated": false
}
```

`symlink_unprivileged` is measured, not inferred: the code creates a throwaway
link in `%TEMP%` and reports what actually happened. Group policy, container
images and mapped drives all break inference from Developer Mode alone.

### When you cannot make a symlink

For **folders**, a junction works and needs no privilege whatsoever. `plan()`
detects this case and returns a `JunctionSubstituteAvailable` warning rather
than just failing. To force one:

```powershell
.\target\release\rcsym.exe link --target C:\real\folder --into D:\somewhere --kind junction
```

For **files**, a hard link works within the same volume. It is not a pointer,
though — it is a second name for the same bytes, with no "original", and the
tool warns accordingly.

Junctions are implemented directly rather than by shelling out: `mklink` is a
`cmd.exe` builtin, not an executable, and there is no Win32 API for junction
creation. The code creates an empty directory, opens it with
`FILE_FLAG_OPEN_REPARSE_POINT`, and writes an `IO_REPARSE_TAG_MOUNT_POINT`
reparse buffer via `FSCTL_SET_REPARSE_POINT`. If the reparse write fails, the
empty directory is removed rather than left behind looking like a broken link.

## Nothing is ever overwritten

Worth stating plainly because it is a common fear: **creating a link cannot
destroy the folder you are creating it in.**

`CreateSymbolicLinkW` fails if anything already exists at the link path. So does
`mklink`. So does this tool, at the plan stage, before touching anything. There
is no force flag at any layer.

"Symlink From…" in particular cannot damage the folder it was invoked from — the
folder is the link's *parent*, not the link path. The only possible collision is
naming the link the same as something already inside, which errors out.

The genuinely destructive operation nearby is "replace this existing folder
*with* a link" — the move-AppData-to-another-drive manoeuvre. That requires
deleting or moving the original first. This tool does not offer it.

## Deleting links safely

Explorer's Delete key and modern `rmdir /s` both remove the link and leave the
target alone. Not every tool is careful: **`robocopy /MIR` into a symlink or
junction will mirror-delete the real target's contents.** Creating links is
safe; the hazard is what other tools do with them afterwards.

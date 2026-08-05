# Right Click Symlink

[![CI](https://github.com/wheresoli/RightClickSymlink/actions/workflows/ci.yml/badge.svg)](https://github.com/wheresoli/RightClickSymlink/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Real symlinks from your file manager's right-click menu, on Windows, macOS and
Linux.

Two verbs, on two different menus:

| Verb | Where you click | What it asks |
|---|---|---|
| **Symlink To…** | On a file or folder | Where to put the link |
| **Symlink From…** | On empty space inside a folder | What to point at |

They live on separate menus, so they never both appear at once and there is no
mode to be in. Whichever end you happen to be standing on, one of them is the
right answer.

## Status

| | Link engine | Context menu | Verified |
|---|---|---|---|
| **Windows 10 / 11** | working | working (registry verbs) | CI + by hand |
| **Windows 11 short menu** | working | scaffold only — needs a COM DLL | no |
| **macOS** | working | compiles, bundles, signs | CI |
| **Linux** (Nautilus / Dolphin / Nemo / Thunar) | working | installs and uninstalls cleanly | CI |

On Windows 11 the registry verbs land under "Show more options". Getting into
the short menu needs a packaged `IExplorerCommand` handler, which is the one
genuinely unfinished piece — see
[platform/windows/msix/README.md](platform/windows/msix/README.md).

### What CI actually proves

Every push runs on all three platforms, which matters here because the project
is developed on Windows and CI is the only place the Unix paths execute at all.

- The core builds and passes on Linux, macOS and Windows, and `scripts/smoke.sh`
  drives the shipped binary against a real filesystem on each — including the
  refuses-to-overwrite guarantees.
- The Swift compiles, the `.app` assembles universal (arm64 + x86_64), and
  `codesign --verify --deep --strict` passes.
- `install.sh` runs against a throwaway `HOME` with stub file managers on
  `PATH`, asserting all four adapters install, that no `@RCSYM@` placeholder
  survives, that re-running does not duplicate the Thunar action, and that
  uninstall leaves nothing behind.
- `register.ps1` writes real registry verbs on the Windows runner and they are
  read back — including asserting that Background verbs use `%V` and not `%1`,
  and that `rcsymw.exe` really is a GUI-subsystem binary.

**What it does not prove:** that the menu entries appear in a real Finder or a
real Nautilus. Both need a logged-in desktop session, and macOS additionally
requires a human to enable the extension in System Settings. Those two remain
untested by anyone.

## Layout

```
crates/
  symlink-core/     link creation, validation, platform quirks. No UI.
  rcsym/            CLI + native dialogs. Two binaries over one run().
platform/
  windows/          registry verbs (works) + sparse MSIX (scaffold)
  macos/            Finder Sync extension + host app
  linux/            Nautilus, Dolphin, Nemo, Thunar adapters
```

Everything above the core talks to it through one CLI, so the link logic exists
once and gets fixed once:

```bash
rcsym to /path/to/target                              # item menu
```

```bash
rcsym from --dir /path/to/folder --pick folder        # background menu
```

```bash
rcsym link --target X --into Y --name Z --no-confirm  # headless, no dialogs
```

```bash
rcsym probe                                           # what can this machine do?
```

## Build

```bash
cargo build --release
```

Then the per-platform step:

```powershell
.\platform\windows\register.ps1
```

```bash
./platform/macos/build.sh          # then enable it in System Settings
```

```bash
./platform/linux/install.sh        # auto-detects your file manager
```

Each `platform/*/README.md` covers installation, the traps specific to that OS,
and how to debug a menu entry that does not appear.

## It cannot overwrite anything

Worth saying plainly, because it is the thing people worry about: **creating a
link cannot destroy the folder you are creating it in.**

`symlink(2)` returns `EEXIST` if the path is taken. `CreateSymbolicLinkW` fails
the same way. So does `mklink`. This tool refuses at the planning stage, before
touching the disk, and there is no force flag at any layer. Verified against a
real filesystem in the test suite and by hand.

"Symlink From…" in particular cannot damage the folder you invoked it from — the
folder is the new link's *parent*, not the link path itself.

The genuinely destructive operation nearby is "replace this existing folder
**with** a link", which is what you do to move `AppData` to another drive. That
requires deleting or moving the original first. This tool does not offer it, and
that is deliberate.

Note that `ln -sf` *is* destructive, and `ln -sf` onto an existing symlink-to-a-
directory writes *inside* the target unless you also pass `-n`. Those are
properties of the `ln` binary, not of the syscall. Nothing here shells out to
`ln`, or to `mklink` — which is a `cmd.exe` builtin and not an executable at all.

## Plan, then execute

The core is built around a split that keeps the UI honest:

```rust
let p = plan(&request)?;   // validates everything, touches nothing
for w in &p.warnings {
    eprintln!("{}", w.message());
}
execute(&p)?;              // the only mutating call
```

`plan()` resolves the literal string that will be stored inside the link, works
out file-vs-directory, checks privilege, and collects warnings. That is exactly
what the confirmation dialog renders, so what you approve is what happens.

Warnings cover the ways a link behaves surprisingly *later*: a dangling target,
a junction silently storing an absolute path, a hard link having no "original",
a link created inside the tree it points at.

## The platform differences that actually matter

**Windows symlinks are typed.** File-vs-directory is baked into the reparse
point at creation and cannot be changed. `symlink(2)` has no such flag. So
`TargetType::Auto` infers it from the target and fails on Windows when the
target does not exist — there is nothing to infer from. Unix just shrugs and
creates a dangling link.

**Windows symlinks need privilege.** Elevation, or Developer Mode plus
`SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE`. When neither applies and the
target is a folder, a **junction** works with no privilege at all, and `plan()`
surfaces that as a warning rather than just failing. `rcsym probe` measures this
empirically — it creates a throwaway link in `%TEMP%` rather than inferring from
settings, because group policy and container images routinely break inference.

**Finder's "Make Alias" is not a symlink.** A macOS alias is a Finder bookmark
that resolves by inode; the POSIX layer cannot follow it, so `cd`, shell scripts
and build tools all fail on one. There is no built-in way to get a real symlink
out of Finder, which is the strongest argument for the macOS build existing.

**Linux already has this.** Nautilus's "Make Link" and Dolphin's paste-as-link
create genuine symlinks. The value on Linux is the dialog — destination, name,
and relative-vs-absolute in one step — not the capability.

## Deleting links

Creating is safe. Deleting is where the footguns live, and they belong to other
tools:

- `robocopy /MIR` into a symlink or junction mirror-deletes the **real target's**
  contents.
- `rsync --delete` through a symlinked source does the same.
- `find -L` and `tar -h` follow links into the target.
- `rm -rf symlink` is fine and removes only the link, but trailing-slash
  behaviour (`rm -rf symlink/`) has differed between GNU and BSD/macOS.

Explorer's Delete key and modern `rmdir /s` both correctly remove the link only.

## Tests

```bash
cargo test --workspace
```

The suite asserts the non-destructive guarantee directly, including the case
where a **dangling symlink** occupies the link path — `exists()` returns false
for one, so any check built on it would happily clobber it.

Tests that need a capability the machine lacks skip themselves rather than
failing, so the same suite is meaningful on a locked-down Windows box and on a
Linux CI runner.

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
- `install-adapters.sh` runs against a throwaway `HOME` with stub file managers on
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

## Install

Grab a [release](https://github.com/wheresoli/RightClickSymlink/releases), or
let the installer fetch it for you.

**Windows** — PowerShell, no admin:

```powershell
irm https://raw.githubusercontent.com/wheresoli/RightClickSymlink/main/install.ps1 | iex
```

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/wheresoli/RightClickSymlink/main/install.sh | bash
```

To pass options through a piped install:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/wheresoli/RightClickSymlink/main/install.ps1))) -Relative
```

```bash
curl -fsSL https://raw.githubusercontent.com/wheresoli/RightClickSymlink/main/install.sh | bash -s -- --relative
```

### What that actually does

Everything is per-user. No `sudo`, no admin prompt, no services, nothing written
outside your profile.

| | Windows | macOS | Linux |
|---|---|---|---|
| Binary | `%LOCALAPPDATA%\Programs\RightClickSymlink` | `~/Applications/RightClickSymlink.app` | `~/.local/bin/rcsym` |
| Integration | 4 verbs under `HKCU:\Software\Classes` | Finder Sync extension | adapter files under `~/.local/share`, `~/.config` |
| Uninstaller | Settings › Apps | `./install.sh --uninstall` | `./install.sh --uninstall` |

The installer copies the binary somewhere permanent **before** registering
anything. That matters: the context menu stores an absolute path, so
registering straight out of an unzipped Downloads folder gives you menu entries
that break silently the day you clean up Downloads.

macOS needs one manual step the installer cannot do for you — enable the
extension in **System Settings › General › Login Items & Extensions › Finder
Extensions**. Apple requires a human for that.

### Uninstall

```powershell
.\install.ps1 -Uninstall
```

```bash
./install.sh --uninstall
```

Windows also lists it in **Settings › Apps › Installed apps** like any other
program. Symlinks you already made are left alone either way — they are ordinary
filesystem objects with no connection to the tool that created them.

### Why a script and not an `.msi` / `.pkg`

An unsigned `.exe` or `.msi` installer triggers a harsher SmartScreen warning
than a PowerShell script does, and fixing that means buying a code-signing
certificate. Same story on macOS: the `.app` is ad-hoc signed, not notarized,
because notarization needs a paid Apple Developer account. Until either of those
is worth paying for, a script that you can read before running it is the more
honest option.

## Build from source

Needs [Rust](https://rustup.rs) (1.74+). Nothing else on Windows or Linux; macOS
also needs the Xcode command line tools (`xcode-select --install`).

```bash
git clone https://github.com/wheresoli/RightClickSymlink
cd RightClickSymlink
cargo build --release
```

Then run the same installer — it detects the local build and uses it instead of
downloading:

```powershell
.\install.ps1
```

```bash
./install.sh
```

### Running the pieces directly

The installer is a wrapper. If you want to drive the parts yourself — say, to
test a change without installing:

```powershell
.\platform\windows\register.ps1 -ExePath .\target\release\rcsymw.exe
```

```bash
./platform/macos/build.sh                    # assembles the .app, ad-hoc signed
```

```bash
./platform/linux/install-adapters.sh         # just the file-manager adapters
```

Or skip the shell integration entirely and use the CLI, which is the same code
path the menus invoke:

```bash
./target/release/rcsym link --target /some/dir --into /elsewhere --dry-run
```

### Tests

```bash
cargo test --workspace
```

```bash
./scripts/smoke.sh
```

`smoke.sh` drives the built binary against a real filesystem, including the
refuses-to-overwrite guarantees. Assertions that need a capability the machine
lacks skip themselves, so it is meaningful on a locked-down Windows box and on a
Linux CI runner alike.

### Releases publish themselves

Merge to `main`; once CI goes green, a version is tagged, built for all three
platforms, and published. There is no manual release step.

The trigger is CI *completing successfully*, not the push itself — a push
trigger would race CI and could publish binaries that never passed a test.

Version comes from the commit message on `main`:

| In the commit message | Result |
|---|---|
| *(nothing special)* | patch bump — `0.1.3` → `0.1.4` |
| `[minor]` | `0.1.3` → `0.2.0` |
| `[major]` | `0.1.3` → `1.0.0` |
| `[skip release]` | no release |

Commits touching only `*.md`, `.github/`, or `LICENSE` are skipped
automatically — documentation does not need new binaries.

The tag job stamps the version into `Cargo.toml` and `Cargo.lock` and pushes
that back to `main`. It cannot loop: pushes made with `GITHUB_TOKEN` do not
trigger workflows, and the commit carries `[skip release]` anyway.

To publish a specific version by hand, run the **Release** workflow from the
Actions tab with a `version` input. It also takes a `dry_run` flag that builds
all three platforms and uploads the artifacts without tagging or publishing —
useful for checking a packaging change before it becomes a real release.

Each `platform/*/README.md` covers that OS's specific traps and how to debug a
menu entry that does not appear.

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

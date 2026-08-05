# macOS

Easiest of the three platforms for the part that matters — `symlink(2)` needs no
privilege, takes no file-vs-directory flag, and dangling links are legal. The
work here is all in the packaging.

> **Compiled in CI, never run in a real Finder.** Every push builds this bundle
> on a macOS runner: the Swift compiles, the `.app` assembles universal, and
> `codesign --verify --deep --strict` passes. What CI cannot do is log into a
> desktop session and enable a Finder extension, so whether the menu items
> actually appear is still unverified.

## Why it is worth having

Finder's built-in "Make Alias" does **not** create a symlink. A macOS alias is a
Finder-level bookmark that resolves by inode and survives the target moving —
and it is completely opaque to the POSIX layer, so `cd`, shell scripts, build
tools and anything non-GUI cannot follow it. There is no built-in way to get a
real symlink from Finder.

That is the opposite of Linux, where Nautilus and Dolphin already make genuine
symlinks and this tool is mostly a convenience.

## How it fits together

```
Finder right-click
       │
       ▼
FinderSyncExt.appex        sandboxed, does almost nothing
   builds  rcsym://to?p=/some/path
       │
       ▼  NSWorkspace.open
RightClickSymlink.app      not sandboxed, has no Dock icon
   NSOpenPanel / NSSavePanel
       │
       ▼  Process
Contents/Resources/rcsym   the Rust core, headless
```

Three deliberate decisions:

**The extension does nothing.** A Finder Sync extension is required to be
sandboxed, and a sandboxed process cannot usefully spawn a helper or reach
arbitrary paths. So it only reads the selection and opens a URL.

**The host app is not sandboxed.** This is the important one. If it were, the
powerbox grant the user creates by choosing a path in the save panel would
**not** be inherited by the `rcsym` child process, and the write would be denied
after the user had already approved it. Developer ID distribution does not
require sandboxing, so the container stays unsandboxed and the nested extension
stays sandboxed — which is exactly what macOS asks for.

**The link logic stays in Rust.** Swift shells out to `rcsym link` rather than
calling `FileManager.createSymbolicLink`. One implementation of "what is a legal
link and when do we refuse" across all three platforms.

## One menu entry, not two

Windows and Linux need separate "Symlink From **Folder**…" and "Symlink From
**File**…" entries because `IFileDialog` with `FOS_PICKFOLDERS` and GTK's folder
chooser can only offer one or the other.

`NSOpenPanel` sets `canChooseFiles` and `canChooseDirectories` independently, so
macOS gets a single "Symlink From…" that accepts either. Nicer, and worth the
platform divergence.

## Building

```bash
./platform/macos/build.sh
```

Needs the Xcode command line tools (`xcode-select --install`) but not the IDE.
Signs ad-hoc by default, which is enough to run on the machine that built it.

For distribution to anyone else:

```bash
IDENTITY="Developer ID Application: Your Name (TEAMID)" ./platform/macos/build.sh
```

Then notarize — Gatekeeper will block it otherwise. That needs a paid Apple
Developer account ($99/yr), which is the real cost of shipping this to other
people:

```bash
xcrun notarytool submit RightClickSymlink.zip --keychain-profile "AC_PASSWORD" --wait
```

```bash
xcrun stapler staple platform/macos/build/RightClickSymlink.app
```

## Installing

1. `cp -R platform/macos/build/RightClickSymlink.app /Applications/`
2. Open it once — that is what registers the extension with the system. It has
   no window; you will get a one-off dialog explaining where the switch is.
3. **System Settings › General › Login Items & Extensions › Finder Extensions**,
   and turn on "Right Click Symlink".

Step 3 is not optional and not automatable. macOS requires the user to enable
Finder extensions by hand.

## When the menu items do not appear

Nearly always one of three things.

**The extension is not registered.**

```bash
pluginkit -m -i com.rightclicksymlink.app.FinderSyncExt
```

Empty output means macOS never saw it — the app has not been opened from
`/Applications`, or the signature is broken.

**Finder is holding a stale copy.**

```bash
killall Finder
```

**The directory is not registered with the controller.** `FIFinderSync` only
offers menu items inside directories passed to
`FIFinderSyncController.directoryURLs`. `FinderSync.swift` registers `/` plus
every mounted volume for exactly this reason. This is the usual cause of an
extension that loads cleanly and then does nothing at all.

## Xcode instead

`build.sh` exists so the repo has no `.xcodeproj` to keep in sync. If you would
rather use Xcode: new macOS App target, add a Finder Sync Extension target, drop
in the two Swift files, copy the Info.plist keys and entitlements, and add the
universal `rcsym` binary as a Copy Files build phase into Resources.

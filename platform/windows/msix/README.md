# Windows 11 short context menu (sparse MSIX)

**Status: scaffold only. This does not work yet, and the missing piece is real
work, not a config tweak.**

Everything else in this repo runs today. This directory is the one part that is
a skeleton, and this file explains exactly where the boundary is so nobody
wastes an afternoon discovering it.

## Why this exists

Windows 11 has two context menus:

| | How you get it | What shows up |
|---|---|---|
| **Short menu** | Normal right-click | Packaged apps implementing `IExplorerCommand`, only |
| **Legacy menu** | "Show more options", or <kbd>Shift</kbd>+<kbd>F10</kbd> | Everything, including registry verbs |

`register.ps1` writes registry verbs. Those work perfectly — on Windows 10 they
are in the normal menu, and on Windows 11 they are one extra click away under
"Show more options". For many people that is genuinely good enough, and it costs
nothing to install.

Getting into the *short* menu has a hard requirement: the handler must be an
`IExplorerCommand` COM object declared by an **MSIX package**. There is no
registry-only path. Microsoft closed it deliberately.

## What is still missing

`AppxManifest.xml` declares a COM class with CLSID
`{9F4C2A18-6E3B-4D57-9C21-1B7A0E5D8F30}` living in `RcsymContextMenu.dll`.

**That DLL has not been written.** It needs to be a real in-process COM server
exporting `DllGetClassObject`, with a class implementing:

- `IExplorerCommand` — `GetTitle`, `GetIcon`, `GetState`, `Invoke`,
  `GetFlags`, `EnumSubCommands`
- `IClassFactory` — to hand out instances

`Invoke` receives an `IShellItemArray`. For the `SymlinkTo` verb that array
holds the selected items; for `SymlinkFrom` on `Directory\Background` it holds
the folder being viewed. Either way the handler converts them to paths and
shells out to `rcsym.exe link` (or `rcsymw.exe to` / `from` if you want the
existing dialogs) — the link logic itself is already done and shared.

`GetState` is worth getting right: return `ECS_HIDDEN` for the `SymlinkTo` verb
when the selection is empty, so the entry does not appear where it cannot work.

Realistic estimate: a few hundred lines of C++/WinRT, or Rust with the
`windows` crate. This is the largest single remaining chunk in the project.

## Build and deploy, once the DLL exists

You need the Windows SDK on `PATH` (`makeappx`, `signtool`).

**1. Assets.** Create `Images\` with `StoreLogo.png` (50×50),
`Square150x150Logo.png`, and `Square44x44Logo.png`. Deployment fails if these
are missing.

**2. A signing certificate.** The `Publisher` in the manifest must match the
certificate subject *exactly*, or you get `0x800B0100`.

```powershell
New-SelfSignedCertificate -Type Custom -Subject "CN=RightClickSymlink Development" -KeyUsage DigitalSignature -FriendlyName "RightClickSymlink Dev" -CertStoreLocation "Cert:\CurrentUser\My" -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
```

Then export it and install into `Cert:\LocalMachine\Root` so the machine trusts
it. That step needs admin.

**3. Point the package at your binaries.** Sparse packages need an external
location — the folder holding `rcsymw.exe` and `RcsymContextMenu.dll`:

```powershell
Add-AppxPackage -Path .\RightClickSymlink.msix -ExternalLocation "C:\Users\olive\Projects\RightClickSymlink\target\release"
```

**4. Package and sign.**

```powershell
makeappx pack /d . /p RightClickSymlink.msix /nv
```

```powershell
signtool sign /fd SHA256 /a /f dev.pfx /p <password> RightClickSymlink.msix
```

**5. Iterate.** Explorer caches context-menu handlers aggressively. After each
reinstall:

```powershell
Remove-AppxPackage RightClickSymlink_0.1.0.0_x64__<hash>; Stop-Process -Name explorer -Force
```

## If you would rather not

Skipping this entirely is a legitimate choice. The cost is one extra click on
Windows 11 and nothing at all on Windows 10, versus a COM DLL, a certificate, a
packaging step, and a signing story for anyone else who installs it.

Recommendation: ship the registry verbs, use the tool for a while, and only come
back here if "Show more options" actually annoys you in practice.

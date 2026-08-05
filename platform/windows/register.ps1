<#
.SYNOPSIS
    Registers the Right Click Symlink context-menu entries for the current user.

.DESCRIPTION
    Writes four verbs under HKCU:\Software\Classes. Everything goes in HKCU, so
    no administrator rights are needed and nothing is changed for other users.

        *\shell                        "Symlink To..."        on any file
        Directory\shell                "Symlink To..."        on any folder
        Directory\Background\shell     "Symlink From ..."     on empty space
                                                              inside a folder

    On Windows 11 these are *legacy* verbs, which means they appear under
    "Show more options" (or Shift+F10) rather than in the short modern menu.
    Getting into the short menu requires a packaged IExplorerCommand handler --
    see ..\msix\README.md.

.PARAMETER ExePath
    Path to rcsymw.exe. Defaults to the release build in this repo.

.PARAMETER Kind
    Default link type: symlink (default), junction, or hardlink.

.PARAMETER Relative
    Bake --relative into the registered commands, so links store a path
    relative to their own folder.

.PARAMETER Uninstall
    Remove the entries instead of adding them.

.EXAMPLE
    .\register.ps1
    .\register.ps1 -ExePath "C:\Tools\rcsymw.exe" -Relative
    .\register.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$ExePath,
    [ValidateSet('symlink', 'junction', 'hardlink')]
    [string]$Kind = 'symlink',
    [switch]$Relative,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

# Verb key names. Prefixed so they are trivially findable in regedit and
# unambiguous to remove.
$Verbs = @(
    @{ Key = 'Software\Classes\*\shell\RightClickSymlink.To';                        Label = 'Symlink To...' }
    @{ Key = 'Software\Classes\Directory\shell\RightClickSymlink.To';                Label = 'Symlink To...' }
    @{ Key = 'Software\Classes\Directory\Background\shell\RightClickSymlink.FromFolder'; Label = 'Symlink From Folder...' }
    @{ Key = 'Software\Classes\Directory\Background\shell\RightClickSymlink.FromFile';   Label = 'Symlink From File...' }
)

function Remove-Registration {
    foreach ($v in $Verbs) {
        $path = "HKCU:\$($v.Key)"
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force -Confirm:$false
            Write-Host "removed  $($v.Key)"
        }
    }
}

if ($Uninstall) {
    Remove-Registration
    Write-Host ""
    Write-Host "Uninstalled. Explorer picks this up immediately; no restart needed."
    return
}

# ---------------------------------------------------------------------------
# Resolve the executable
# ---------------------------------------------------------------------------

if (-not $ExePath) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $ExePath = Join-Path $repoRoot 'target\release\rcsymw.exe'
}

if (-not (Test-Path $ExePath)) {
    Write-Error @"
rcsymw.exe not found at:
  $ExePath

Build it first:
  cargo build --release

Or pass an explicit path:
  .\register.ps1 -ExePath C:\Tools\rcsymw.exe
"@
    return
}

$ExePath = (Resolve-Path $ExePath).Path

# Flags baked into every registered command. The context menu has no way to
# carry per-invocation preferences, so defaults are fixed at install time.
$flags = "--kind $Kind"
if ($Relative) { $flags = "$flags --relative" }

# ---------------------------------------------------------------------------
# Write the verbs
# ---------------------------------------------------------------------------

# Start clean so re-running never leaves a half-updated command line behind.
Remove-Registration

foreach ($v in $Verbs) {
    $path = "HKCU:\$($v.Key)"
    New-Item -Path $path -Force | Out-Null

    New-ItemProperty -Path $path -Name 'MUIVerb' -Value $v.Label -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $path -Name 'Icon'    -Value $ExePath -PropertyType String -Force | Out-Null

    if ($v.Key -like '*Background*') {
        # %V, NOT %1. For a Background verb %1 is empty -- the verb fires and
        # receives nothing. This is the single most common way to get this
        # wrong, and it fails silently.
        $pick = 'folder'
        if ($v.Key -like '*FromFile') { $pick = 'file' }
        $cmd = "`"$ExePath`" from --dir `"%V`" --pick $pick $flags"
    }
    else {
        $cmd = "`"$ExePath`" to `"%1`" $flags"

        # Without this, selecting 12 files and clicking the verb launches 12
        # separate processes. "Player" hands the whole selection to one
        # invocation instead. Explorer stops honouring the verb entirely above
        # ~15 selected items, which is a shell limit we cannot raise.
        New-ItemProperty -Path $path -Name 'MultiSelectModel' -Value 'Player' -PropertyType String -Force | Out-Null
    }

    New-Item -Path "$path\command" -Force | Out-Null
    Set-ItemProperty -Path "$path\command" -Name '(Default)' -Value $cmd
    Write-Host "added    $($v.Key)"
}

Write-Host ""
Write-Host "Installed against: $ExePath"
Write-Host "Defaults:          $flags"
Write-Host ""
Write-Host "Right-click a file or folder  -> 'Symlink To...'"
Write-Host "Right-click empty space       -> 'Symlink From Folder/File...'"
Write-Host ""
Write-Host "On Windows 11 look under 'Show more options' (or press Shift+F10)."

# Report what the machine can actually do, so a later "it says I need
# permission" has an answer already on screen.
$consoleExe = Join-Path (Split-Path -Parent $ExePath) 'rcsym.exe'
if (Test-Path $consoleExe) {
    Write-Host ""
    Write-Host "This machine:"
    & $consoleExe probe
}

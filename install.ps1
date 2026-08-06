<#
.SYNOPSIS
    Installs Right Click Symlink for the current user.

.DESCRIPTION
    Copies the binaries somewhere permanent, registers the context-menu entries
    against that permanent location, and adds an entry to Settings > Apps so it
    uninstalls like anything else.

    That middle step is the reason this exists rather than just running
    register.ps1. register.ps1 registers whatever path you point it at -- so if
    you run it against an unzipped folder in Downloads and later delete that
    folder, the menu entries survive and silently do nothing.

    Everything is per-user. No administrator rights, nothing written outside
    your profile, no services, no drivers.

        binaries      %LOCALAPPDATA%\Programs\RightClickSymlink
        menu entries  HKCU:\Software\Classes\...
        uninstaller   HKCU:\...\CurrentVersion\Uninstall\RightClickSymlink

    Works three ways, picked automatically:

      * run inside a repo checkout   -> installs target\release
      * run inside an unzipped release -> installs the binaries beside it
      * run standalone (piped from the web) -> downloads the latest release

.PARAMETER InstallDir
    Where the binaries go. Defaults to %LOCALAPPDATA%\Programs\RightClickSymlink.

.PARAMETER Kind
    Default link type for the menu entries: symlink (default), junction, or
    hardlink. The context menu cannot carry per-click options, so this is fixed
    at install time.

.PARAMETER Relative
    Make links store a path relative to their own folder rather than an
    absolute one. Relative links survive the whole tree being moved.

.PARAMETER NoPath
    Skip adding the install directory to your user PATH. Without PATH the
    context menu still works; you just cannot run `rcsym probe` in a terminal.

.PARAMETER Uninstall
    Remove all of it: menu entries, PATH entry, uninstaller entry, and files.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -Relative -Kind junction

.EXAMPLE
    .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\RightClickSymlink",
    [ValidateSet('symlink', 'junction', 'hardlink')]
    [string]$Kind = 'symlink',
    [switch]$Relative,
    [switch]$NoPath,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$Repo       = 'wheresoli/RightClickSymlink'
$AppName    = 'Right Click Symlink'
$ArpKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\RightClickSymlink'
$Binaries   = @('rcsym.exe', 'rcsymw.exe')

function Write-Step { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "    $Text" -ForegroundColor Green }
function Write-Info { param([string]$Text) Write-Host "    $Text" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# PATH
# ---------------------------------------------------------------------------

function Add-ToUserPath {
    param([string]$Directory)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if ($current) { $parts = $current -split ';' | Where-Object { $_ } }

    if ($parts -contains $Directory) { return $false }

    [Environment]::SetEnvironmentVariable('Path', (($parts + $Directory) -join ';'), 'User')
    # So the current session sees it too, not just new ones.
    $env:Path = "$env:Path;$Directory"
    return $true
}

function Remove-FromUserPath {
    param([string]$Directory)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $current) { return $false }

    $parts = $current -split ';' | Where-Object { $_ -and $_ -ne $Directory }
    if (($parts -join ';') -eq $current) { return $false }

    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    return $true
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if ($Uninstall) {
    Write-Step "Uninstalling $AppName"

    $register = Join-Path $InstallDir 'register.ps1'
    if (Test-Path $register) {
        & $register -Uninstall 6> $null | Out-Null
        Write-Ok "removed the context-menu entries"
    }
    else {
        # Installed elsewhere, or a partial install. Clear the verbs directly so
        # uninstalling never leaves menu entries pointing at deleted files.
        #
        # .NET API, not the HKCU: PSDrive: the first key is literally named `*`,
        # which PowerShell's provider cmdlets would treat as a wildcard and glob
        # across every file association on the machine.
        $verbs = @(
            'Software\Classes\*\shell\RightClickSymlink.To'
            'Software\Classes\Directory\shell\RightClickSymlink.To'
            'Software\Classes\Directory\Background\shell\RightClickSymlink.FromFolder'
            'Software\Classes\Directory\Background\shell\RightClickSymlink.FromFile'
        )
        foreach ($v in $verbs) {
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($v, $false)
        }
        Write-Ok "removed the context-menu entries"
    }

    if (Remove-FromUserPath $InstallDir) { Write-Ok "removed $InstallDir from PATH" }

    if (Test-Path $ArpKey) {
        Remove-Item $ArpKey -Recurse -Force -Confirm:$false
        Write-Ok "removed the Settings > Apps entry"
    }

    if (Test-Path $InstallDir) {
        # The running script may itself live in here. Deleting the directory
        # out from under PowerShell is fine -- the file is already parsed.
        try {
            Remove-Item $InstallDir -Recurse -Force -Confirm:$false
            Write-Ok "removed $InstallDir"
        }
        catch {
            Write-Warning "could not remove $InstallDir -- delete it by hand"
        }
    }

    Write-Host ""
    Write-Host "Uninstalled." -ForegroundColor Green
    Write-Info "Symlinks you already created are untouched. They are ordinary"
    Write-Info "filesystem objects with no connection to the tool that made them."
    return
}

# ---------------------------------------------------------------------------
# Find the binaries
# ---------------------------------------------------------------------------

Write-Step "Locating binaries"

# Empty when piped from the web (irm ... | iex), which is exactly the case
# where we should download.
$scriptDir = $PSScriptRoot
$source = $null
$version = 'dev'

if ($scriptDir) {
    $candidates = @(
        (Join-Path $scriptDir 'target\release'),   # repo checkout
        $scriptDir                                  # unzipped release
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'rcsymw.exe')) { $source = $c; break }
    }
}

if ($source) {
    Write-Ok "using $source"
}
else {
    Write-Info "no local build found, fetching the latest release"

    # PowerShell 5.1 defaults to TLS 1.0, which github.com refuses.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
            -Headers @{ 'User-Agent' = 'RightClickSymlink-Installer' }
    }
    catch {
        Write-Error @"
Could not reach the GitHub releases API, or there is no published release yet.

Build from source instead:

    git clone https://github.com/$Repo
    cd RightClickSymlink
    cargo build --release
    .\install.ps1
"@
        return
    }

    $asset = $release.assets | Where-Object { $_.name -like '*windows*.zip' } | Select-Object -First 1
    if (-not $asset) {
        Write-Error "Release $($release.tag_name) has no Windows asset. Build from source instead."
        return
    }

    $version = $release.tag_name -replace '^v', ''
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) "rcsym-install-$PID"
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $zip = Join-Path $temp $asset.name

    Write-Info "downloading $($asset.name) ($([math]::Round($asset.size / 1KB)) KB)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $temp -Force

    $source = $temp
    Write-Ok "downloaded $($release.tag_name)"
}

foreach ($b in $Binaries) {
    if (-not (Test-Path (Join-Path $source $b))) {
        Write-Error "$b is missing from $source. Run 'cargo build --release' first."
        return
    }
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

Write-Step "Installing to $InstallDir"

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

foreach ($b in $Binaries) {
    Copy-Item (Join-Path $source $b) $InstallDir -Force
}

# Find a file that may live beside the binaries, in the repo, or nowhere.
#
# Join-Path throws on an empty path, and $scriptDir IS empty when this script
# was piped from the web -- so the candidates have to be built conditionally
# rather than filtered afterwards.
function Find-Support {
    param([string]$Name, [string]$RepoRelative)

    $candidates = @(Join-Path $source $Name)
    if ($scriptDir) {
        if ($RepoRelative) { $candidates += (Join-Path $scriptDir $RepoRelative) }
        $candidates += (Join-Path $scriptDir $Name)
    }
    $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

# register.ps1 does the actual menu work and the uninstaller calls it later, so
# it has to live alongside the binaries rather than only in the repo.
$registerSource = Find-Support 'register.ps1' 'platform\windows\register.ps1'
if (-not $registerSource) {
    Write-Error "register.ps1 not found next to the binaries or in platform\windows."
    return
}
Copy-Item $registerSource $InstallDir -Force

# The menu icons. register.ps1 looks for an "icons" directory beside the
# executable, so they have to travel with the install -- a registry Icon value
# is an absolute path, and pointing it into an unzipped Downloads folder breaks
# the moment that folder is cleaned up.
$iconSource = @(
    (Join-Path $source 'icons'),
    (Join-Path $source 'assets\icons\win')
) + $(if ($scriptDir) { (Join-Path $scriptDir 'assets\icons\win') } else { @() }) |
    Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if ($iconSource) {
    $iconDest = Join-Path $InstallDir 'icons'
    New-Item -ItemType Directory -Force -Path $iconDest | Out-Null
    Copy-Item (Join-Path $iconSource '*.ico') $iconDest -Force
    Write-Ok "copied $((Get-ChildItem $iconDest -Filter *.ico).Count) menu icons"
}
else {
    Write-Info "no icons found; menu entries will use the executable's icon"
}

# The uninstaller invoked from Settings > Apps is this script. $PSCommandPath
# is empty when piped from the web, so fall back to the copy in the release
# archive -- without one of these the Settings > Apps entry would point at a
# file that does not exist.
$selfSource = $null
if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
    $selfSource = $PSCommandPath
}
else {
    $selfSource = Find-Support 'install.ps1' $null
}

if ($selfSource) {
    Copy-Item $selfSource (Join-Path $InstallDir 'install.ps1') -Force
}
else {
    # Last resort: reconstruct it from the running script's own text so that
    # uninstalling still works.
    $MyInvocation.MyCommand.ScriptBlock.ToString() |
        Set-Content (Join-Path $InstallDir 'install.ps1') -Encoding UTF8
}

Write-Ok "copied $($Binaries.Count + 2) files"

# ---------------------------------------------------------------------------

Write-Step "Registering the context menu"

# 6>$null suppresses the Information stream, which is where Write-Host goes in
# PowerShell 5+. Out-Null alone would leave register.ps1's own chatter on
# screen, interleaved with this script's, saying the same things twice.
& (Join-Path $InstallDir 'register.ps1') `
    -ExePath (Join-Path $InstallDir 'rcsymw.exe') `
    -Kind $Kind `
    -Relative:$Relative 6> $null | Out-Null

Write-Ok "Symlink To...    on files and folders"
Write-Ok "Symlink From...  on empty space inside a folder"

# ---------------------------------------------------------------------------

if (-not $NoPath) {
    Write-Step "Adding to PATH"
    if (Add-ToUserPath $InstallDir) {
        Write-Ok "added $InstallDir to your user PATH"
        Write-Info "open a new terminal for this to take effect"
    }
    else {
        Write-Ok "already on PATH"
    }
}

# ---------------------------------------------------------------------------

Write-Step "Registering the uninstaller"

$size = (Get-ChildItem $InstallDir -File | Measure-Object -Property Length -Sum).Sum
$uninstallCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\install.ps1`" -Uninstall"

New-Item -Path $ArpKey -Force | Out-Null
$props = @{
    DisplayName     = $AppName
    DisplayVersion  = $version
    Publisher       = 'wheresoli'
    InstallLocation = $InstallDir
    DisplayIcon     = (Join-Path $InstallDir 'rcsymw.exe')
    URLInfoAbout    = "https://github.com/$Repo"
    UninstallString = $uninstallCmd
    QuietUninstallString = "$uninstallCmd"
}
foreach ($k in $props.Keys) {
    New-ItemProperty -Path $ArpKey -Name $k -Value $props[$k] -PropertyType String -Force | Out-Null
}
New-ItemProperty -Path $ArpKey -Name 'EstimatedSize' -Value ([int]($size / 1KB)) -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $ArpKey -Name 'NoModify' -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $ArpKey -Name 'NoRepair' -Value 1 -PropertyType DWord -Force | Out-Null

Write-Ok "listed in Settings > Apps > Installed apps"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Installed." -ForegroundColor Green
Write-Host ""
Write-Host "  Right-click a file or folder   -> Symlink To..."
Write-Host "  Right-click empty space        -> Symlink From Folder/File..."
Write-Host ""

if ([Environment]::OSVersion.Version.Build -ge 22000) {
    Write-Host "  On Windows 11 these are under " -NoNewline
    Write-Host "Show more options" -ForegroundColor Yellow -NoNewline
    Write-Host " (or Shift+F10)."
    Write-Host ""
}

# What this machine can actually do, printed now so that a later "it says I
# need permission" already has its answer on screen.
$probe = & (Join-Path $InstallDir 'rcsym.exe') probe | ConvertFrom-Json
if ($probe.symlink_unprivileged) {
    Write-Host "  Symlinks: " -NoNewline
    Write-Host "available" -ForegroundColor Green
}
else {
    Write-Host "  Symlinks: " -NoNewline
    Write-Host "blocked for standard users on this machine" -ForegroundColor Yellow
    Write-Host ""
    Write-Info "Turn on Developer Mode (Settings > System > For developers) and"
    Write-Info "symlinks start working with no elevation. Until then, folders can"
    Write-Info "still be linked with a junction, which needs no permission:"
    Write-Info ""
    Write-Info "    .\install.ps1 -Kind junction"
}

Write-Host ""
Write-Info "Uninstall from Settings > Apps, or:  .\install.ps1 -Uninstall"

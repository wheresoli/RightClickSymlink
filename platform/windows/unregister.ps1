<#
.SYNOPSIS
    Removes the Right Click Symlink context-menu entries.

.DESCRIPTION
    Convenience wrapper for `register.ps1 -Uninstall`. Removes only the four
    HKCU verbs this project creates; any symlinks already made are left alone,
    because they are ordinary filesystem objects with no connection to the
    tool that created them.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'register.ps1') -Uninstall

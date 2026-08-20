<#
.SYNOPSIS
    Builds VolantVisaSlotsMonitor.exe from monitor.ps1 (via the ps2exe module)
    so the monitor can run on any PC as a single executable, no PowerShell
    knowledge needed.

    The .exe reads config.json / writes log.txt / state.json from its own folder,
    so ship all files together.

    Requires internet on first run (downloads the ps2exe module from PSGallery).
#>
# WARNING: ps2exe builds an UNSIGNED .exe. Windows Defender / SmartScreen and
# many antivirus products flag unsigned PowerShell-compiled executables as
# potentially unwanted software and BLOCK them from running. The monitor itself
# does not need an .exe - install.ps1 + monitor.ps1 work on any PC with no
# warnings. Only use this if you accept the AV trade-off (or sign the exe).
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$src = Join-Path $PSScriptRoot "monitor.ps1"
$out = Join-Path $PSScriptRoot "VolantVisaSlotsMonitor.exe"

if (-not (Test-Path -LiteralPath $src)) { throw "monitor.ps1 not found" }

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing ps2exe module from PSGallery..."
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    } catch {
        Write-Warning "NuGet provider install failed: $($_.Exception.Message)"
    }
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}

Import-Module ps2exe -Force
$icon = Join-Path $PSScriptRoot "iconlogo.ico"
$iconArg = @{}
if (Test-Path -LiteralPath $icon) { $iconArg["IconFile"] = $icon }
Invoke-PS2EXE -InputFile $src -OutputFile $out -NoOutput -NoConsole @iconArg
Write-Host "Built: $out"
Write-Host "Note: unsigned exe - Windows SmartScreen may warn on other PCs (More info > Run anyway)."
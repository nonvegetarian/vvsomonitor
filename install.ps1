<#
.SYNOPSIS
    One-click installer for Volant Visa Slots Monitor.

    What it does:
      1. Cleans up any previous install (old task / startup entry / toast identity)
      2. Registers the toast AppUserModelID (needed for Windows toasts)
      3. Creates a watchdog scheduled task (every 5 min, restarts the monitor if it ever dies)
      4. Adds a Startup-folder launcher (starts the monitor at every logon)
      5. Creates a "Volant Visa Slots Monitor" shortcut on the desktop

    Run: right-click install.ps1 > "Run with PowerShell" (no admin needed).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$AumId     = "VolantVisaSlotsMonitor"
$TaskName  = "VolantVisaSlotsMonitor"
$MonitorPs = Join-Path $PSScriptRoot "monitor.ps1"

if (-not (Test-Path -LiteralPath $MonitorPs)) {
    throw "monitor.ps1 not found next to this script."
}

$Icon = Join-Path $PSScriptRoot "iconlogo.ico"
$IconValue = if (Test-Path -LiteralPath $Icon) { $Icon } else { "$env:WINDIR\System32\shell32.dll,15" }

# --- 1) clean up previous installs ---
try { schtasks /Delete /TN "VisaSlotMonitor" /F 2>&1 | Out-Null } catch { }
try { schtasks /Delete /TN $TaskName /F 2>&1 | Out-Null } catch { }
$oldStartup = Join-Path ([Environment]::GetFolderPath("Startup")) "visa-slot-monitor.cmd"
if (Test-Path -LiteralPath $oldStartup) { Remove-Item -LiteralPath $oldStartup -Force }
Remove-Item -LiteralPath "HKCU:\Software\Classes\AppUserModelId\VisaSlotMonitor" -Recurse -Force -ErrorAction SilentlyContinue
$newStartup = Join-Path ([Environment]::GetFolderPath("Startup")) "volant-visa-slots-monitor.cmd"
if (Test-Path -LiteralPath $newStartup) { Remove-Item -LiteralPath $newStartup -Force }

# --- 2) toast app identity ---
$regPath = "HKCU:\Software\Classes\AppUserModelId\$AumId"
New-Item -Path $regPath -Force | Out-Null
New-ItemProperty -Path $regPath -Name "DisplayName" -Value "Volant Visa Slots Monitor" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $regPath -Name "IconUri" -Value $IconValue -PropertyType String -Force | Out-Null
Write-Host "Toast identity registered."

# --- 3) watchdog scheduled task (every 5 min; exits instantly if a loop is already running) ---
$target = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$MonitorPs`""
schtasks /Create /TN $TaskName /TR $target /SC DAILY /ST 00:00 /RI 5 /DU 24:00 /F | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Watchdog task '$TaskName' created (every 5 min)."
} else {
    Write-Host "WARNING: could not create watchdog task (exit $LASTEXITCODE)."
}

# --- 4) startup launcher (runs at every logon) ---
$cmdContent = "@echo off`r`nstart `"`" /b $target`r`n"
Set-Content -LiteralPath $newStartup -Value $cmdContent -Encoding ASCII
Write-Host "Startup launcher created."

# --- 5) desktop shortcut ---
$desktop = [Environment]::GetFolderPath("Desktop")
$lnkPath = Join-Path $desktop "Volant Visa Slots Monitor.lnk"
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$MonitorPs`""
$lnk.WorkingDirectory = $PSScriptRoot
$lnk.IconLocation = $IconValue
$lnk.Description = "Volant Visa Slots Monitor - 24/7 visa slot change alerts"
$lnk.Save()
Write-Host "Desktop shortcut created: $lnkPath"

Write-Host ""
Write-Host "Installation complete. The monitor starts automatically from now on."
Write-Host "Test a notification: right-click the desktop shortcut or run:"
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$MonitorPs`" -TestToast"
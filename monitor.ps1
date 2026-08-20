<#
.SYNOPSIS
    Volant Visa Slots Monitor - polls the public API behind the "Fetch Latest
    Data" button on https://visaslotsguru.com/slots and shows a Windows toast
    notification whenever slot availability changes. Runs 24/7.

.PARAMETER ConfigPath
    Path to config.json (default: alongside this script).

.PARAMETER Once
    Run a single poll cycle and exit (useful for testing).

.PARAMETER NoToast
    Suppress toast/balloon notifications (still logs).

.PARAMETER TestToast
    Show a test notification and exit.

.PARAMETER TestLogin
    Verify login against the API and exit.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Once,
    [switch]$NoToast,
    [switch]$TestToast,
    [switch]$TestLogin,
    [switch]$TestTelegram,
    [switch]$TestAlert
)

$ErrorActionPreference = "Stop"

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "config.json" }

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$Script:Config   = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$Script:AumId    = "VolantVisaSlotsMonitor"
$Script:Token    = $null
$Script:User     = $null
$Script:GateWarned  = $false
$Script:PublicWarned = $false
$Script:ToastAttempted = $false
$Script:ToastOk   = $false

$Script:StatePath = if ([IO.Path]::IsPathRooted($Script:Config.stateFile)) {
    $Script:Config.stateFile
} else {
    Join-Path $PSScriptRoot $Script:Config.stateFile
}

# ---------- logging ----------
function Write-Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    try {
        $log = $Script:Config.logFile
        if (-not [IO.Path]::IsPathRooted($log)) { $log = Join-Path $PSScriptRoot $log }
        Add-Content -LiteralPath $log -Value $line -Encoding UTF8
        $fi = Get-Item -LiteralPath $log -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 5MB) {
            Remove-Item -LiteralPath $log -Force
            Add-Content -LiteralPath $log -Value ("{0}  (log rolled)" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -Encoding UTF8
        }
    } catch { }
}

# ---------- notifications ----------
function Escape-Xml {
    param([string]$Text)
    $Text = [string]$Text
    $Text = $Text -replace "&", "&amp;"
    $Text = $Text -replace "<", "&lt;"
    $Text = $Text -replace ">", "&gt;"
    $Text = $Text -replace '"', "&quot;"
    return $Text
}

function Show-Notification {
    param([string]$Title, [string]$Message)
    if ($NoToast) { return }
    $xmlTitle = Escape-Xml $Title
    $xmlMsg   = Escape-Xml $Message

    if (-not $Script:ToastAttempted) {
        $Script:ToastAttempted = $true
        try {
            Add-Type -AssemblyName System.Runtime.WindowsRuntime
            [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
            $Script:ToastOk = $true
        } catch {
            $Script:ToastOk = $false
        }
    }

    if ($Script:ToastOk) {
        try {
            $xml = "<toast><visual><binding template='ToastGeneric'><text>$xmlTitle</text><text>$xmlMsg</text></binding></visual></toast>"
            $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
            $doc.LoadXml($xml)
            $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($Script:AumId)
            $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
            $notifier.Show($toast)
            return
        } catch {
            $Script:ToastOk = $false
        }
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon = [System.Drawing.SystemIcons]::Information
        $n.Visible = $true
        $n.BalloonTipTitle = $Title
        $n.BalloonTipText = $Message
        $n.ShowBalloonTip(10000)
        Start-Sleep -Seconds 6
        $n.Dispose()
    } catch { }
}

# ---------- telegram ----------
function Escape-Html {
    param([string]$Text)
    $Text = [string]$Text
    return ($Text -replace "&", "&amp;" -replace "<", "&lt;" -replace ">", "&gt;")
}

function Send-Telegram {
    param([string]$Text)
    if (-not $Script:Config.telegramToken -or -not $Script:Config.telegramChatId) { return $false }
    try {
        $url = "https://api.telegram.org/bot{0}/sendMessage" -f $Script:Config.telegramToken
        $body = @{
            chat_id = [string]$Script:Config.telegramChatId
            text = $Text
            parse_mode = "HTML"
            disable_web_page_preview = $true
        }
        $json = $body | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $null = Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec 20
        return $true
    } catch {
        Write-Log ("Telegram send failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Build-StatusMessage {
    param($snap)
    $lines = @()
    $lines += ("🕐 <b>Volant Visa Slots - {0}</b>" -f (Get-Date -Format "MMM d, h:mm tt"))
    foreach ($city in ($snap.live.Keys | Sort-Object)) {
        $c = $snap.live[$city]
        $lines += ""
        $lines += ("🏙 City: {0} (total {1})" -f (Escape-Html $city), $c.slots)
        foreach ($vt in ($c.visaTypes.Keys | Sort-Object)) {
            $v = $c.visaTypes[$vt]
            $line = ("   {0} slots: {1}" -f (Escape-Html $vt), $v.slots)
            if ([int]$v.slots -gt 0 -and $v.earliestSlotDate) {
                $line += "  🎯 {0} {1}" -f (Format-Date $v.earliestSlotDate), $v.earliestSlotTime
            }
            $lines += $line
        }
    }
    return $lines -join "`n"
}

function Build-AlertMessage {
    param($snap, $openKeys)
    $lines = @()
    $lines += "🚨🚨🔴 <b>SLOTS OPEN FOUND! SLOTS OPEN FOUND! SLOTS OPEN FOUND!</b> 🔴🚨🚨"
    $lines += ""
    foreach ($key in $openKeys) {
        $parts = $key -split "\|", 2
        $city = $parts[0]; $vt = $parts[1]
        $c = $snap.live[$city]
        if (-not $c) { continue }
        $v = $c.visaTypes[$vt]
        if (-not $v) { continue }
        $line = ("🔴 <b>{0} | {1} SLOTS: {2}</b> ⚠️" -f $city.ToUpper(), $vt.ToUpper(), $v.slots)
        if ($v.earliestSlotDate) {
            $line += " | 🎯 {0} {1}" -f (Format-Date $v.earliestSlotDate), $v.earliestSlotTime
        }
        $lines += $line
    }
    $lines += ""
    $lines += "⚡ CHECK NOW: https://visaslotsguru.com/slots"
    return $lines -join "`n"
}

# ---------- API ----------
function Login {
    try {
        $body = @{ email = $Script:Config.email; password = $Script:Config.password } | ConvertTo-Json -Compress
        $resp = Invoke-RestMethod -Method Post -Uri ($Script:Config.apiBase.TrimEnd("/") + "/auth/login") `
            -ContentType "application/json" -Body $body -TimeoutSec 30
        $Script:Token = $resp.token
        $Script:User  = $resp.user
        if (-not $Script:Token) { throw "Login response contained no token" }
        Write-Log ("Logged in as {0}" -f $Script:Config.email)
        return $true
    } catch {
        Write-Log ("Login failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Invoke-Api {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body,
        [hashtable]$Params,
        [int]$Retries = 1
    )
    $url = $Script:Config.apiBase.TrimEnd("/") + $Path
    $arg = @{ Method = $Method; Uri = $url; TimeoutSec = 30 }
    $headers = @{}
    if ($Script:Token) { $headers["Authorization"] = "Bearer $($Script:Token)" }
    $arg["Headers"] = $headers
    if ($Params) { $arg["Body"] = $Params }
    if ($null -ne $Body) { $arg["ContentType"] = "application/json"; $arg["Body"] = ($Body | ConvertTo-Json -Compress) }
    try {
        return Invoke-RestMethod @arg
    } catch {
        $status = $null
        try { $status = $_.Exception.Response.StatusCode.value__ } catch { }
        if ($status -eq 401 -and $Retries -gt 0) {
            Write-Log "Token expired, re-logging in..."
            $Script:Token = $null
            if (Login) { return Invoke-Api -Method $Method -Path $Path -Body $Body -Params $Params -Retries 0 }
        }
        throw
    }
}

# ---------- data ----------
function ConvertTo-Hashtable {
    param($Obj)
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
        return $h
    }
    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
        $arr = @()
        foreach ($i in $Obj) { $arr += ConvertTo-Hashtable $i }
        return , $arr
    }
    return $Obj
}

function Format-Date {
    param($d)
    if (-not $d) { return "n/a" }
    try {
        $dt = [DateTime]::Parse([string]$d)
        $s = $dt.ToString("MMM d, yyyy")
        if ($dt.Hour -or $dt.Minute) { $s += " " + $dt.ToString("h:mm tt") }
        return $s
    } catch {
        return [string]$d
    }
}

function Get-Snapshot {
    $snap = @{ live = @{}; community = @{}; canViewSlots = $null; lastPolled = $null }

    if ($Script:Token) {
        try {
            $cs = Invoke-Api -Method GET -Path "/contributions/status"
            $snap.canViewSlots = [bool]$cs.canViewSlots
        } catch {
            Write-Log ("Contributions status failed: {0}" -f $_.Exception.Message)
        }
    }

    try {
        $live = Invoke-Api -Method GET -Path "/slots/live"
        $snap.lastPolled = $live.lastPolled
        foreach ($c in $live.slots) {
            $earliest = $null; $earliestTime = $null
            $vt = @{}
            foreach ($v in $c.visaTypes) {
                $vt[$v.visaType] = @{
                    slots           = [int]$v.slots
                    earliestSlotDate = $v.earliestSlotDate
                    earliestSlotTime = $v.earliestSlotTime
                }
                if ([int]$v.slots -gt 0) {
                    if (-not $earliest -or ([string]$v.earliestSlotDate) -lt ([string]$earliest)) {
                        $earliest = $v.earliestSlotDate; $earliestTime = $v.earliestSlotTime
                    }
                }
            }
            $snap.live[$c.city] = @{
                slots        = [int]$c.slots
                earliestDate = $earliest
                earliestTime = $earliestTime
                visaTypes    = $vt
            }
        }
    } catch {
        Write-Log ("Live slots fetch failed: {0}" -f $_.Exception.Message)
        return $null
    }

    if ($Script:Token) {
        try {
            $params = @{ page = 1; limit = $Script:Config.communityLimit }
            if ($Script:Config.country) { $params.country = $Script:Config.country }
            if ($Script:Config.city)    { $params.city    = $Script:Config.city }
            if ($Script:Config.visaType){ $params.visaType = $Script:Config.visaType }
            $list = Invoke-Api -Method GET -Path "/slots" -Params $params
            foreach ($s in $list.slots) {
                $key = "{0}|{1}" -f $s.city, $s.visaType
                $snap.community[$key] = @{
                    totalSlots    = [int]$s.totalSlots
                    status        = $s.status
                    earliestDate  = $s.earliestDate
                    lastCheckedAt = $s.lastCheckedAt
                }
            }
        } catch {
            Write-Log ("Community slots fetch failed: {0}" -f $_.Exception.Message)
        }
    }

    return $snap
}

function Get-Diff {
    param($Old, $New)
    $changes = @()
    if (-not $Old) { $Old = @{ live = @{}; community = @{} } }

    foreach ($city in $New.live.Keys) {
        $n = $New.live[$city]
        if (-not $Old.live.ContainsKey($city)) {
            $changes += ("LIVE NEW {0}: {1} slot(s) open, earliest {2}" -f $city, $n.slots, (Format-Date $n.earliestDate))
            continue
        }
        $o = $Old.live[$city]
        if ($o.slots -ne $n.slots) { $changes += ("LIVE {0}: {1} -> {2} slots" -f $city, $o.slots, $n.slots) }
        if ($o.earliestDate -ne $n.earliestDate) {
            $changes += ("LIVE {0}: earliest {1} -> {2}" -f $city, (Format-Date $o.earliestDate), (Format-Date $n.earliestDate))
        }
        foreach ($vt in $n.visaTypes.Keys) {
            $nv = $n.visaTypes[$vt]
            $ov = if ($o.visaTypes.ContainsKey($vt)) { $o.visaTypes[$vt] } else { $null }
            if ($ov -and $ov.slots -eq $nv.slots -and $ov.earliestSlotDate -eq $nv.earliestSlotDate) { continue }
            $oldSlots = if ($ov) { $ov.slots } else { 0 }
            $changes += ("LIVE {0} {1}: {2} -> {3} slots (earliest {4})" -f $city, $vt, $oldSlots, $nv.slots, (Format-Date $nv.earliestSlotDate))
        }
    }
    foreach ($city in $Old.live.Keys) {
        if (-not $New.live.ContainsKey($city)) { $changes += ("LIVE GONE {0}" -f $city) }
    }

    foreach ($key in $New.community.Keys) {
        $n = $New.community[$key]
        if (-not $Old.community.ContainsKey($key)) {
            $changes += ("COMM NEW {0}: {1} slots ({2})" -f $key, $n.totalSlots, $n.status)
            continue
        }
        $o = $Old.community[$key]
        if ($o.totalSlots -ne $n.totalSlots -or $o.status -ne $n.status) {
            $changes += ("COMM {0}: {1}/{2} -> {3}/{4}" -f $key, $o.totalSlots, $o.status, $n.totalSlots, $n.status)
        }
        if ($o.earliestDate -ne $n.earliestDate) {
            $changes += ("COMM {0}: earliest {1} -> {2}" -f $key, (Format-Date $o.earliestDate), (Format-Date $n.earliestDate))
        }
    }
    foreach ($key in $Old.community.Keys) {
        if (-not $New.community.ContainsKey($key)) { $changes += ("COMM GONE {0}" -f $key) }
    }

    return $changes
}

# ---------- main ----------
function Test-InWindow {
    $h = (Get-Date).Hour
    return ($h -ge [int]$Script:Config.startHour -and $h -lt [int]$Script:Config.endHour)
}

function Poll-Once {
    $hasCredentials = $Script:Config.email -and $Script:Config.email -notmatch "^YOUR_" -and $Script:Config.password
    if ($Script:Token -or $hasCredentials) {
        if (-not $Script:Token) {
            if (-not (Login)) { return }
        }
    } elseif (-not $Script:PublicWarned) {
        $Script:PublicWarned = $true
        Write-Log "No credentials configured - running in public mode (live grid only). Add email/password to config.json for community slot detail."
    }

    $snap = Get-Snapshot
    if (-not $snap) { return }

    if ($snap.canViewSlots -eq $false) {
        if (-not $Script:GateWarned) {
            $Script:GateWarned = $true
            Write-Log "WARNING: canViewSlots=false (need 5 contributions today or a paid plan)"
            if (-not $NoToast) { Show-Notification -Title "Volant Visa Slots Monitor" -Message "Slot access is currently gated. Contribute 5 checks today or upgrade to keep monitoring." }
        }
        return
    }

    $changes = Get-Diff -Old $Script:lastState -New $snap
    $hadBaseline = $null -ne $Script:lastState
    $prevOpen = if ($Script:lastState -and $Script:lastState.ContainsKey("_lastOpen")) { @($Script:lastState["_lastOpen"]) } else { @() }

    # which city|visaType combos currently have slots
    $open = @()
    foreach ($city in $snap.live.Keys) {
        foreach ($vt in $snap.live[$city].visaTypes.Keys) {
            if ([int]$snap.live[$city].visaTypes[$vt].slots -gt 0) { $open += ("{0}|{1}" -f $city, $vt) }
        }
    }
    $snap["_lastOpen"] = $open

    $Script:lastState = $snap
    $snap | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Script:StatePath -Encoding UTF8

    # Telegram: always send the full status update
    if ($Script:Config.telegramToken -and $Script:Config.telegramChatId) {
        $statusText = Build-StatusMessage $snap
        if (Send-Telegram -Text $statusText) {
            Write-Log ("Telegram status sent ({0} cities)" -f $snap.live.Count)
        }
    }

    # Telegram: newly-open slots => ALERT spam in caps + emojis
    $newlyOpen = @($open | Where-Object { $_ -notin $prevOpen })
    if ($newlyOpen.Count -gt 0 -and $Script:Config.telegramToken -and $Script:Config.telegramChatId) {
        $alertText = Build-AlertMessage $snap $open
        $spam = [int]$Script:Config.alertSpamCount
        if ($spam -lt 1) { $spam = 1 }
        for ($i = 0; $i -lt $spam; $i++) {
            Send-Telegram -Text $alertText
            Start-Sleep -Milliseconds 800
        }
        Write-Log ("ALERT spam x{0}: {1}" -f $spam, ($newlyOpen -join ", "))
    }

    if ($changes.Count -gt 0) {
        $msg = ($changes | Select-Object -First 4) -join "`n"
        if ($changes.Count -gt 4) { $msg += "`n...and {0} more change(s)" -f ($changes.Count - 4) }
        Write-Log ("CHANGE: " + ($changes -join " | "))
        if ($hadBaseline) {
            if (-not $NoToast) { Show-Notification -Title ("Volant Visa Slot Change ({0})" -f $changes.Count) -Message $msg }
        } else {
            Write-Log "Baseline established - no alert for initial state."
        }
    } else {
        Write-Log ("No changes ({0} live cities, {1} community entries)" -f $snap.live.Count, $snap.community.Count)
    }
}

$Script:lastState = $null
if (Test-Path -LiteralPath $Script:StatePath) {
    try {
        $raw = Get-Content -Raw -LiteralPath $Script:StatePath
        $Script:lastState = ConvertTo-Hashtable ($raw | ConvertFrom-Json)
    } catch {
        Write-Log ("Could not read previous state: {0}" -f $_.Exception.Message)
    }
}

$windowDesc = if ([int]$Script:Config.startHour -eq 0 -and [int]$Script:Config.endHour -eq 24) {
    "24/7"
} else {
    "{0}:00-{1}:00" -f $Script:Config.startHour, $Script:Config.endHour
}
Write-Log ("Volant Visa Slots Monitor started ({0}, every {1} min)" -f $windowDesc, $Script:Config.pollMinutes)

if ($TestToast) {
    Show-Notification -Title "Volant Visa Slots Monitor" -Message "Test notification - alerts are working!"
    Write-Log "Test toast sent"
    exit 0
}

if ($TestTelegram) {
    if (-not $Script:Config.telegramToken -or -not $Script:Config.telegramChatId) {
        Write-Log "Telegram not configured - add telegramToken + telegramChatId to config.json"
        exit 1
    }
    $msg = "🧪 <b>Volant Visa Slots Monitor</b>`nTest message from your PC - {0}" -f (Get-Date -Format "MMM d, h:mm tt")
    if (Send-Telegram -Text $msg) { Write-Log "Test Telegram sent"; exit 0 } else { Write-Log "Test Telegram FAILED"; exit 1 }
}

if ($TestAlert) {
    if (-not $Script:Config.telegramToken -or -not $Script:Config.telegramChatId) {
        Write-Log "Telegram not configured - add telegramToken + telegramChatId to config.json"
        exit 1
    }
    $sample = @{ live = @{
        "New Delhi" = @{ slots = 2; visaTypes = @{ "B1/B2" = @{ slots = 2; earliestSlotDate = "Aug 27, 2026"; earliestSlotTime = "9:00 AM" } } }
        "Mumbai"   = @{ slots = 4; visaTypes = @{ "F-1"  = @{ slots = 4; earliestSlotDate = "Aug 26, 2026"; earliestSlotTime = "9:00 AM" } } }
    } }
    $alert = Build-AlertMessage $sample @("New Delhi|B1/B2", "Mumbai|F-1")
    if (Send-Telegram -Text $alert) { Write-Log "Test ALERT sent"; exit 0 } else { Write-Log "Test ALERT FAILED"; exit 1 }
}

if ($TestLogin) {
    if (Login) { Write-Log "Login OK"; exit 0 } else { Write-Log "Login FAILED"; exit 1 }
}

if ($Once) { Poll-Once; exit 0 }

# single-instance guard for the persistent loop (watchdog + startup may both fire)
$Script:Mutex = New-Object System.Threading.Mutex($false, "Local\VolantVisaSlotsMonitor")
if (-not $Script:Mutex.WaitOne(0)) {
    Write-Log "Another instance already running - exiting."
    exit 0
}

$minSleep = [Math]::Max(30, [int]$Script:Config.pollMinutes * 60)
while ($true) {
    if (Test-InWindow) {
        $started = Get-Date
        Poll-Once
        $elapsed = ((Get-Date) - $started).TotalSeconds
        Start-Sleep -Seconds ([Math]::Max(30, $minSleep - $elapsed))
    } else {
        Start-Sleep -Seconds 120
    }
}
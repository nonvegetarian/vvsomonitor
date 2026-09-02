<#
.SYNOPSIS
    Volant Visa Slots Monitor - polls the public visa slot availability API
    and sends Telegram alerts whenever slots open. Runs 24/7.

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
    [switch]$TestAlert,
    [switch]$ParseCheck
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
$Script:OcrWarned = $false
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
    param([string]$Text, [int]$RecipientDelayMs = 300)
    $ids = @($Script:Config.telegramChatIds)
    if (-not $Script:Config.telegramToken -or $ids.Count -eq 0) { return $false }
    $ok = 0
    foreach ($chatId in $ids) {
        try {
            $url = "https://api.telegram.org/bot{0}/sendMessage" -f $Script:Config.telegramToken
            $body = @{
                chat_id = [string]$chatId
                text = $Text
                parse_mode = "HTML"
                disable_web_page_preview = $true
            }
            $json = $body | ConvertTo-Json -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $null = Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec 20
            $ok++
            Start-Sleep -Milliseconds $RecipientDelayMs
        } catch {
            Write-Log ("Telegram send failed for chat {0}: {1}" -f $chatId, $_.Exception.Message)
        }
    }
    return ($ok -gt 0)
}

function Send-TelegramPhoto {
    param([string]$ImagePath, [string]$Caption)
    $ids = @($Script:Config.telegramChatIds)
    if (-not $Script:Config.telegramToken -or $ids.Count -eq 0 -or -not (Test-Path -LiteralPath $ImagePath)) { return $false }
    $ok = 0
    foreach ($chatId in $ids) {
        try {
            $url = "https://api.telegram.org/bot{0}/sendPhoto" -f $Script:Config.telegramToken
            $client = New-Object System.Net.Http.HttpClient
            $client.Timeout = [TimeSpan]::FromSeconds(60)
            $form = New-Object System.Net.Http.MultipartFormDataContent
            $form.Add((New-Object System.Net.Http.StringContent([string]$chatId)), "chat_id")
            $form.Add((New-Object System.Net.Http.StringContent($Caption)), "caption")
            $fs = [System.IO.File]::OpenRead($ImagePath)
            $fileContent = New-Object System.Net.Http.StreamContent($fs)
            $fileContent.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue("application/octet-stream")
            $form.Add($fileContent, "photo", ([IO.Path]::GetFileName($ImagePath)))
            $resp = $client.PostAsync($url, $form).GetAwaiter().GetResult()
            $fs.Close()
            $client.Dispose()
            if ($resp.IsSuccessStatusCode) { $ok++ }
            Start-Sleep -Milliseconds 300
        } catch {
            Write-Log ("Photo send failed for chat {0}: {1}" -f $chatId, $_.Exception.Message)
        }
    }
    return ($ok -gt 0)
}

function Build-AlertMessage {
    param($Evidence)
    $lines = @()
    $lines += "🚨🚨🔴 <b>SLOTS OPEN FOUND! SLOTS OPEN FOUND! SLOTS OPEN FOUND!</b> 🔴🚨🚨"
    $lines += ""
    foreach ($e in $Evidence) {
        $line = "🔴 <b>{0} | {1} SLOTS: {2}</b> | 🟢 per VSG live count" -f $e.city.ToUpper(), $e.visaType.ToUpper(), $e.slots
        if ($e.earliestDate) { $line += " | 🎯 {0} {1}" -f (Format-Date $e.earliestDate), $e.earliestTime }
        if ($null -ne $e.ageSec) { $line += " | 🕐 data {0}s old" -f $e.ageSec }
        $lines += $line
        if ($e.ocr -and $e.ocr.hasNegative) { $lines += "⚠️ latest VSG screenshot reads 'no slots' - verify before acting" }
    }
    $lines += ""
    $lines += "⚡ CHECK NOW: https://www.usvisascheduling.com/en-US/"
    $lines += "📸 VSG community screenshots attached below"
    return $lines -join "`n"
}

# ---------- evidence / ocr ----------
function Get-VisaKeywords {
    param([string]$VisaType)
    $v = ($VisaType -replace "[^A-Za-z0-9]", "").ToLower()
    if ($v -match "^b1b2$" -or $v -match "^b1$" -or $v -match "^b2$") { return @("b1", "b2", "b1/b2", "b1-b2", "tourist", "business") }
    if ($v -match "^f1$")  { return @("f1", "f-1", "student") }
    if ($v -match "^h1b" -or $v -match "^h2" -or $v -match "^h3" -or $v -match "^ewi") { return @("h1b", "h-1b", "h2a", "h2b", "h3", "work") }
    if ($v -match "^l1$")  { return @("l1", "l-1") }
    if ($v -match "^l2$")  { return @("l2", "l-2") }
    if ($v -match "^j1$")  { return @("j1", "j-1", "exchange") }
    if ($v -match "^o1$")  { return @("o1", "extraordinary ability") }
    if ($v -match "^c1d")  { return @("c1/d", "c1d", "crew") }
    if ($v -match "^i+$")  { return @("media", "press") }
    return @()
}

function Invoke-OcrText {
    param([string]$ImagePath)
    if (-not (Get-Command tesseract -ErrorAction SilentlyContinue)) {
        if (-not $Script:OcrWarned) {
            $Script:OcrWarned = $true
            Write-Log "WARNING: tesseract not installed - OCR verification disabled (all evidence marked unverified)"
        }
        return $null
    }
    try {
        $out = & tesseract $ImagePath stdout --psm 6 2>&1
        $text = ($out | Where-Object { $_ -is [string] }) -join "`n"
        return $text
    } catch {
        Write-Log ("OCR failed for {0}: {1}" -f $ImagePath, $_.Exception.Message)
        return $null
    }
}

function Save-RemoteImage {
    param([string]$Url, [string]$DestPath)
    try {
        $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
        Invoke-WebRequest -Uri $Url -OutFile $DestPath -TimeoutSec 30 -UseBasicParsing -Headers @{ "User-Agent" = $ua }
        return (Test-Path -LiteralPath $DestPath)
    } catch {
        Write-Log ("Image download failed ({0}): {1}" -f $Url, $_.Exception.Message)
        return $false
    }
}

function Test-ScreenshotEvidence {
    param([string]$ImagePath, [string]$VisaType)
    $result = @{ verdict = "unverified"; dateCount = 0; excerpt = ""; text = ""; hasNegative = $false; strongDates = @(); weakDates = @(); keywordsMatched = @() }
    $text = Invoke-OcrText -ImagePath $ImagePath
    if ($null -eq $text) { return $result }
    $result.text = $text
    $low = $text.ToLower()
    $excerpt = ($low -replace "\s+", " ").Trim()
    if ($excerpt.Length -gt 160) { $excerpt = $excerpt.Substring(0, 160) }
    $result.excerpt = $excerpt

    $negatives = @("no slots", "no appointment", "no dates available", "no availability", "no available dates", "fully booked", "no visa appointment", "slots are not available", "no dates")
    $hasNegative = $false
    foreach ($n in $negatives) { if ($low.Contains($n)) { $hasNegative = $true; break } }
    $result.hasNegative = $hasNegative

    # strong = day-level dates (d MMM yyyy / MMM d, yyyy / dd/mm/yyyy); weak = bare month-year (calendar/copyright noise)
    $strong = @{}
    $weak = @{}
    $strongPatterns = @(
        '(?i)\b\d{1,2}[-/\. ](jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]{0,6}[-/\. ]\d{2,4}\b',
        '(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]{0,6}\.?\s+\d{1,2}(st|nd|rd|th)?,?\s*\d{4}\b',
        '\b\d{1,2}/\d{1,2}/\d{2,4}\b'
    )
    foreach ($p in $strongPatterns) {
        foreach ($m in [regex]::Matches($text, $p)) { $strong[$m.Value.ToLower()] = $true }
    }
    foreach ($m in [regex]::Matches($text, '(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]{0,6}\.?,?\s+\d{4}\b')) { $weak[$m.Value.ToLower()] = $true }
    $result.strongDates = $strong.Keys | Sort-Object
    $result.weakDates = $weak.Keys | Sort-Object
    $count = $strong.Count
    $result.dateCount = $count

    $kw = Get-VisaKeywords -VisaType $VisaType
    $result.keywordsMatched = @()
    $flavorHit = ($kw.Count -eq 0)
    foreach ($k in $kw) { if ($low.Contains($k)) { $flavorHit = $true; $result.keywordsMatched += $k } }

    # DEBUG LOGGING - always enabled for now
    $dbg = "OCR DEBUG {0}: raw_len={1} neg={2} strong={3} weak={4} kw_matched={5} flavorHit={6} verdict={7}" -f $VisaType, $text.Length, $hasNegative, ($result.strongDates -join ','), ($result.weakDates -join ','), ($result.keywordsMatched -join ','), $flavorHit, $result.verdict
    Write-Log $dbg

    # if the image explicitly says "no slots" — that beats any date noise; suppress entirely
    if ($hasNegative) { $result.verdict = "suppressed"; return $result }

    if ($count -gt 0 -and $flavorHit) { $result.verdict = "verified" } else { $result.verdict = "unverified" }
    return $result
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
                    lastChecked     = $v.lastChecked
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
                screenshotUrl = $c.screenshotUrl
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

    # which city|visaType combos currently have slots (fresh data only)
    $staleSecs = 300
    if ($Script:Config.staleSeconds) { $staleSecs = [int]$Script:Config.staleSeconds }
    $nowUtc = [datetime]::UtcNow
    $open = @()
    foreach ($city in $snap.live.Keys) {
        foreach ($vt in $snap.live[$city].visaTypes.Keys) {
            $v = $snap.live[$city].visaTypes[$vt]
            if ([int]$v.slots -le 0) { continue }
            $age = $null
            if ($v.lastChecked) {
                try { $age = [int]($nowUtc - ([datetime]$v.lastChecked).ToUniversalTime()).TotalSeconds } catch { $age = $null }
            }
            if ($null -eq $age -or $age -gt $staleSecs) {
                Write-Log ("STALE SKIP {0}|{1}: slots>0 but data age unknown or >{2}s" -f $city, $vt, $staleSecs)
                continue
            }
            $open += ("{0}|{1}" -f $city, $vt)
        }
    }
    # ---- OCR evidence for guru claims ----
    $origin = $Script:Config.apiBase -replace "/api/?$", ""
    $evidence = @()
    foreach ($key in $open) {
        $parts = $key -split "\|", 2
        $city = $parts[0]; $vt = $parts[1]
        $c = $snap.live[$city]; if (-not $c) { continue }
        $v = $c.visaTypes[$vt]; if (-not $v) { continue }
        $ageSec = $null
        if ($v.lastChecked) { try { $ageSec = [int]($nowUtc - ([datetime]$v.lastChecked).ToUniversalTime()).TotalSeconds } catch { } }
        if ($null -ne $ageSec -and $ageSec -lt 0) { $ageSec = 0 }
        $rec = @{ source = "guru"; key = $key; city = $city; visaType = $vt; slots = [int]$v.slots; earliestDate = $v.earliestSlotDate; earliestTime = $v.earliestSlotTime; ageSec = $ageSec; screenshotUrl = $null; variant = ""; imagePath = $null; ocr = @{ verdict = "unverified"; dateCount = 0; excerpt = ""; hasNegative = $false } }
        if ($c.screenshotUrl) {
            $rec.screenshotUrl = $origin + $c.screenshotUrl
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ("guru_{0}_{1}_{2}.png" -f ($city -replace "\W", "_"), ($vt -replace "\W", "_"), (Get-Random))
            if (Save-RemoteImage -Url $rec.screenshotUrl -DestPath $tmp) {
                Write-Log ("OCR CHECK {0}: url={1}" -f $key, $rec.screenshotUrl)
                $rec.ocr = Test-ScreenshotEvidence -ImagePath $tmp -VisaType $vt
                $rec.imagePath = $tmp
            }
        }
        if ($rec.ocr.hasNegative) {
            Write-Log ("WARN {0}: VSG count says open but screenshot reads 'no slots' (verdict={1})" -f $key, $rec.ocr.verdict)
        }
        Write-Log ("EVIDENCE {0}: slots={1} OCR verdict={2} dates={3} neg={4}" -f $key, $rec.slots, $rec.ocr.verdict, $rec.ocr.dateCount, $rec.ocr.hasNegative)
        $evidence += $rec
    }

    # alert-once over ALERTED keys only (suppressed claims can re-alert later if evidence improves)
    $alertKeys = @($evidence | ForEach-Object { $_.key })
    $snap["_lastOpen"] = $alertKeys

    $Script:lastState = $snap
    $snap | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Script:StatePath -Encoding UTF8

    # Telegram: silent unless something NEW opens
    $newlyOpen = @($alertKeys | Where-Object { $_ -notin $prevOpen })
    if ($newlyOpen.Count -gt 0 -and $evidence.Count -gt 0 -and $Script:Config.telegramToken -and $Script:Config.telegramChatIds) {
        $alertText = Build-AlertMessage $evidence
        Send-Telegram -Text $alertText
        # attach images (max 5, dedupe by city)
        $sentCities = @{}
        $count = 0
        foreach ($e in $evidence) {
            if ($count -ge 5) { break }
            $cap = $e.city.ToUpper()
            if ($e.visaType) { $cap += " | $($e.visaType)" }
            if ($e.variant) { $cap += " ($($e.variant))" }
            if ($sentCities.ContainsKey($cap)) { continue }
            if ($e.imagePath -and (Test-Path -LiteralPath $e.imagePath)) {
                $caption = "📸 $cap — VSG community screenshot"
                Send-TelegramPhoto -ImagePath $e.imagePath -Caption $caption
                $sentCities[$cap] = $true
                $count++
            }
        }
        Write-Log ("ALERT sent once: {0} (with $count image(s))" -f ($newlyOpen -join ", "))
    } elseif ($evidence.Count -gt 0) {
        Write-Log ("Openings persist (no new) - staying silent: {0}" -f ($alertKeys -join ", "))
    } else {
        Write-Log ("No openings - staying silent ({0} cities checked)" -f $snap.live.Count)
    }
    # cleanup any remaining temp images
    foreach ($e in $evidence) {
        if ($e.imagePath -and (Test-Path -LiteralPath $e.imagePath)) {
            Remove-Item -LiteralPath $e.imagePath -Force -ErrorAction SilentlyContinue
        }
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

if ($ParseCheck) { Write-Host "PARSE OK"; exit 0 }

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
    if (-not $Script:Config.telegramToken -or -not $Script:Config.telegramChatIds) {
        Write-Log "Telegram not configured - add telegramToken + telegramChatIds to config.json"
        exit 1
    }
    $msg = "🧪 <b>Volant Visa Slots Monitor</b>`nTest message from your PC - {0}" -f (Get-Date -Format "MMM d, h:mm tt")
    if (Send-Telegram -Text $msg) { Write-Log "Test Telegram sent"; exit 0 } else { Write-Log "Test Telegram FAILED"; exit 1 }
}

if ($TestAlert) {
    $sample = @(
        @{ source = "guru"; key = "New Delhi|B1/B2"; city = "New Delhi"; visaType = "B1/B2"; slots = 2; earliestDate = "Aug 27, 2026"; earliestTime = "9:00 AM"; ageSec = 42; screenshotUrl = $null; variant = ""; imagePath = $null; ocr = @{ verdict = "verified"; dateCount = 3; excerpt = "b1/b2 27 feb 2026"; hasNegative = $false } },
        @{ source = "guru"; key = "Chennai|F-1"; city = "Chennai"; visaType = "F-1"; slots = 1; earliestDate = "Sep 10, 2026"; earliestTime = "10:30 AM"; ageSec = 76; screenshotUrl = $null; variant = ""; imagePath = $null; ocr = @{ verdict = "verified"; dateCount = 2; excerpt = "f1 dates"; hasNegative = $false } },
        @{ source = "guru"; key = "Hyderabad|H-1B"; city = "Hyderabad"; visaType = "H-1B"; slots = 3; earliestDate = "Aug 28, 2026"; earliestTime = "8:00 AM"; ageSec = 30; screenshotUrl = $null; variant = ""; imagePath = $null; ocr = @{ verdict = "verified"; dateCount = 1; excerpt = "h1b"; hasNegative = $false } }
    )
    $alert = Build-AlertMessage $sample
    Write-Host "----- alert preview -----"
    Write-Host $alert
    Write-Host "-------------------------"
    if ($Script:Config.telegramToken -and $Script:Config.telegramChatIds) {
        if (Send-Telegram -Text $alert) { Write-Log "Test ALERT sent"; exit 0 } else { Write-Log "Test ALERT FAILED"; exit 1 }
    }
    exit 0
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
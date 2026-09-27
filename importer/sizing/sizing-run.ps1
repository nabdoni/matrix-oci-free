<#
.SYNOPSIS
  Spike 0: measure how much data a Discord server holds, WITHOUT downloading any media.

.DESCRIPTION
  Lists every channel and thread with DiscordChatExporter, exports them ONE AT A TIME as JSON
  (text only, in partitions), tallies message counts and attachment sizes (fileSizeBytes is in
  the JSON), deletes each temp export, and writes sizing-summary.md + CSVs.

  Read-only: nothing is changed on Discord and nothing touches the Oracle server.
  Resumable: re-run the same command and finished channels are skipped.
  Disk use: about one partition (~50 MB) at a time.

  The token is read from $env:DISCORD_TOKEN, or prompted for (input hidden). It is never written
  to disk and never printed.

.EXAMPLE
  .\sizing-run.ps1 -GuildId 123456789012345678 -DownloadDce
  .\sizing-run.ps1 -GuildId 123456789012345678            # resume
  .\sizing-run.ps1 -GuildId 123456789012345678 -Limit 5   # dry run on the first 5 channels
  .\sizing-run.ps1 -GuildId 123456789012345678 -ReportOnly
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$GuildId,
  [string]$DceExe,
  [string]$WorkDir = (Join-Path $PSScriptRoot 'work'),
  [int]$PartitionSize = 50000,
  [switch]$DownloadDce,
  [int]$Limit = 0,
  [string]$OnlyChannel,
  [switch]$ReportOnly,
  [string]$Python
)

$ErrorActionPreference = 'Stop'
$DceVersion = '2.48'
$DceZipName = 'DiscordChatExporter.Cli.win-x64.zip'
$DceZipUrl = "https://github.com/Tyrrrz/DiscordChatExporter/releases/download/$DceVersion/$DceZipName"
$DceZipBytes = 11448499

function Say($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) }

# ---- python ----------------------------------------------------------------------------
function Resolve-Python {
  if ($Python) { return $Python }
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'),
    'python', 'python3')
  foreach ($c in $candidates) {
    try {
      $v = & $c --version 2>$null
      if ($LASTEXITCODE -eq 0 -and $v -match 'Python 3') { return $c }
    } catch { }
  }
  throw 'Python 3 not found. Install it (winget install Python.Python.3.12) or pass -Python <path>.'
}
$py = Resolve-Python
$sizingPy = Join-Path $PSScriptRoot 'sizing.py'
$db = Join-Path $WorkDir 'sizing.db'
$outDir = $WorkDir
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

function Run-Sizing([string[]]$SizingArgs) {
  & $py $sizingPy @SizingArgs
  if ($LASTEXITCODE -ne 0) { throw "sizing.py $($SizingArgs[0]) failed (exit $LASTEXITCODE)" }
}

if ($ReportOnly) {
  Run-Sizing @('report', '--db', $db, '--out', $outDir)
  Say "Wrote $(Join-Path $outDir 'sizing-summary.md')"
  return
}

# ---- exporter --------------------------------------------------------------------------
if ($DownloadDce) {
  $dceDir = Join-Path $WorkDir 'dce'
  New-Item -ItemType Directory -Force -Path $dceDir | Out-Null
  $zip = Join-Path $dceDir $DceZipName
  if (-not (Test-Path $zip)) {
    Say "Downloading $DceZipName ($DceZipBytes bytes) from GitHub release $DceVersion"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $DceZipUrl -OutFile $zip -UseBasicParsing
  }
  $len = (Get-Item $zip).Length
  if ($len -ne $DceZipBytes) { throw "Downloaded size $len does not match expected $DceZipBytes; delete $zip and retry." }
  Say ("SHA-256 of download: " + (Get-FileHash -Algorithm SHA256 $zip).Hash + "  (GitHub publishes no checksum for this asset; size verified)")
  Expand-Archive -Path $zip -DestinationPath $dceDir -Force
}
if (-not $DceExe) { $DceExe = Join-Path $WorkDir 'dce\DiscordChatExporter.Cli.exe' }
if (-not (Test-Path $DceExe)) { throw "DiscordChatExporter not found at $DceExe. Re-run with -DownloadDce or pass -DceExe." }

# ---- token (in-process only) -----------------------------------------------------------
if (-not $env:DISCORD_TOKEN) {
  $sec = Read-Host -AsSecureString 'Discord token (input hidden)'
  $env:DISCORD_TOKEN = [System.Net.NetworkCredential]::new('', $sec).Password
}
if (-not $env:DISCORD_TOKEN) { throw 'No token provided.' }

# Channel names contain emoji/unicode. The exporter writes in the console's code page, so force UTF-8
# for it (and for reading its output back); otherwise names come out as "??".
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

function Run-Dce([string]$ArgLine, [string]$StdOut, [string]$StdErr) {
  $p = Start-Process -FilePath $DceExe -ArgumentList $ArgLine -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr
  return $p.ExitCode
}

# ---- channel + thread list -------------------------------------------------------------
$listOut = Join-Path $WorkDir 'channels.raw.txt'
$listErr = Join-Path $WorkDir 'channels.err.txt'
Say "Listing channels and threads for guild $GuildId"
$code = Run-Dce "channels -g $GuildId --include-threads all" $listOut $listErr
if ($code -ne 0) {
  $full = (Get-Content $listErr -Raw -ErrorAction SilentlyContinue)
  $first = (($full -split "`r?`n" | Where-Object { $_ -match 'Exception|failed|forbidden|unauthorized' } | Select-Object -First 1) -replace '^.*DiscordChatExporterException:\s*', '').Trim()
  $hint = if ($full -match 'forbidden') {
    "403 Forbidden: the token is valid but cannot see this server. The bot is probably not in the server, or the guild ID is wrong. " +
    "Run '$DceExe guilds' to list the servers this token can see; if it is empty, invite the bot with the OAuth2 link (scope 'bot', permissions 66560)."
  } elseif ($full -match 'unauthorized') {
    "401 Unauthorized: the token is invalid or was reset. Set `$env:DISCORD_TOKEN again."
  } else { "See $listErr for the full error." }
  throw "channels command failed (exit $code): $first`n$hint`n(full error: $listErr)"
}
$items = New-Object System.Collections.Generic.List[object]
$lastParent = ''
foreach ($line in (Get-Content $listOut -Encoding UTF8)) {
  if ($line -match '^\s*\*\s*(\d{10,})\s*\|\s*Thread / (.+?)\s*\|\s*(Archived|Active)\s*$') {
    $items.Add([pscustomobject]@{ Id = $Matches[1]; Name = "Thread / $($Matches[2])"; Kind = 'Thread'; Parent = $lastParent })
  } elseif ($line -match '^\s*(\d{10,})\s*\|\s*(.+?)\s*$') {
    $lastParent = $Matches[2]
    $items.Add([pscustomobject]@{ Id = $Matches[1]; Name = $Matches[2]; Kind = 'Channel'; Parent = '' })
  }
}
if ($items.Count -eq 0) { throw "No channels parsed from $listOut. Check the guild ID and that the token can see the server." }
$items | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $WorkDir 'channels.csv')
Say ("{0} items ({1} channels, {2} threads)" -f $items.Count, ($items | Where-Object Kind -eq 'Channel').Count, ($items | Where-Object Kind -eq 'Thread').Count)
Say "NOTE: the token can only list channels it can see. If this is fewer than the server really has, give the bot's role View Channels + Read Message History on the missing ones."

if ($OnlyChannel) { $items = @($items | Where-Object Id -eq $OnlyChannel) }

# ---- resumable state -------------------------------------------------------------------
$stateFile = Join-Path $WorkDir 'state.json'
$done = @{}
$failed = @{}
if (Test-Path $stateFile) {
  $st = Get-Content $stateFile -Raw | ConvertFrom-Json
  foreach ($d in @($st.done)) { $done[[string]$d] = $true }
  if ($st.failed) { foreach ($p in $st.failed.PSObject.Properties) { $failed[$p.Name] = [string]$p.Value } }
}
function Save-State {
  $obj = [pscustomobject]@{ done = @($done.Keys); failed = $failed }
  $obj | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $stateFile
}

$tmp = Join-Path $WorkDir 'tmp'
$todo = @($items | Where-Object { -not $done.ContainsKey($_.Id) })
if ($Limit -gt 0) { $todo = @($todo | Select-Object -First $Limit) }
Say ("{0} to process, {1} already done" -f $todo.Count, $done.Count)

function Fmt-Span([TimeSpan]$t) { '{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds }
function Fmt-Bytes([double]$b) {
  if ($b -ge 1e9) { '{0:N2} GB' -f ($b / 1e9) } elseif ($b -ge 1e6) { '{0:N1} MB' -f ($b / 1e6) } else { '{0:N0} KB' -f ($b / 1e3) }
}
function Get-Stats {
  try { return (& $py $sizingPy stats --db $db | ConvertFrom-Json) } catch { return $null }
}

$runClock = [Diagnostics.Stopwatch]::StartNew()
$totalItems = $items.Count
$stats = Get-Stats
$lastHeartbeat = Get-Date
$n = 0
foreach ($it in $todo) {
  $n++
  $doneNow = $done.Count
  Say ("[{0}/{1}] {2} ({3})" -f $n, $todo.Count, $it.Name, $it.Id)
  if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  # --opt=value form: Windows PowerShell 5.1 silently drops empty-string arguments to native programs.
  Run-Sizing @('begin', '--db', $db, "--id=$($it.Id)", "--name=$($it.Name)", "--kind=$($it.Kind)", "--parent=$($it.Parent)")

  $outTpl = Join-Path $tmp '%c.json'
  $argLine = 'export -c {0} -f Json --markdown false --partition {1} -o "{2}"' -f $it.Id, $PartitionSize, $outTpl
  $so = Join-Path $WorkDir 'export.out.txt'
  $se = Join-Path $WorkDir 'export.err.txt'

  # Run the exporter in the background and keep the progress display alive while it works.
  $p = Start-Process -FilePath $DceExe -ArgumentList $argLine -NoNewWindow -PassThru `
        -RedirectStandardOutput $so -RedirectStandardError $se
  $null = $p.Handle   # PS 5.1: without touching Handle, ExitCode can come back empty
  $chanClock = [Diagnostics.Stopwatch]::StartNew()
  while (-not $p.HasExited) {
    # A directory listing reports 0 bytes for a file another process still has open, so read the real
    # length through a stream opened with sharing (verified: 0 vs 600000 bytes on a file mid-write).
    $written = 0
    foreach ($jf in @(Get-ChildItem $tmp -Filter '*.json' -ErrorAction SilentlyContinue)) {
      try {
        $fs = [IO.File]::Open($jf.FullName, 'Open', 'Read', 'ReadWrite,Delete')
        try { $written += $fs.Length } finally { $fs.Dispose() }
      } catch { $written += $jf.Length }
    }
    $pct = if ($totalItems -gt 0) { [int](100 * $doneNow / $totalItems) } else { 0 }
    $eta = ''
    if ($n -gt 1) {
      $perChan = $runClock.Elapsed.TotalSeconds / ($n - 1)
      $eta = ' | ETA ~' + (Fmt-Span ([TimeSpan]::FromSeconds($perChan * ($todo.Count - $n + 1)))) + ' (rough: channel sizes vary)'
    }
    $msgs = if ($stats) { '{0:N0}' -f $stats.messages } else { '0' }
    $media = if ($stats) { Fmt-Bytes $stats.media_bytes } else { '0 KB' }
    Write-Progress -Id 1 -Activity "Sizing server $GuildId" `
      -Status ("{0}/{1} channels | elapsed {2}{3}" -f $doneNow, $totalItems, (Fmt-Span $runClock.Elapsed), $eta) `
      -CurrentOperation ("So far: {0} messages, {1} of media" -f $msgs, $media) -PercentComplete $pct
    Write-Progress -Id 2 -ParentId 1 -Activity ("Now: {0}" -f $it.Name) `
      -Status ("{0} elapsed, {1} of text exported so far" -f (Fmt-Span $chanClock.Elapsed), (Fmt-Bytes ([double]$written)))
    if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge 60) {
      Say ("  ...still on '{0}': {1} elapsed, {2} written | run total {3}, {4}/{5} channels" -f `
        $it.Name, (Fmt-Span $chanClock.Elapsed), (Fmt-Bytes ([double]$written)), (Fmt-Span $runClock.Elapsed), $doneNow, $totalItems)
      $lastHeartbeat = Get-Date
    }
    Start-Sleep -Milliseconds 500
  }
  $p.WaitForExit()
  $code = $p.ExitCode
  Write-Progress -Id 2 -Activity 'channel' -Completed
  if ($code -ne 0) {
    $reason = ((Get-Content $se -Raw -ErrorAction SilentlyContinue) + (Get-Content $so -Raw -ErrorAction SilentlyContinue))
    $reason = ($reason -replace '\s+', ' ').Trim()
    if ($reason.Length -gt 300) { $reason = $reason.Substring(0, 300) }
    $failed[$it.Id] = "$($it.Name): $reason"
    Say "  FAILED (exit $code): $reason"
    Save-State
    continue
  }
  $files = @(Get-ChildItem -Path $tmp -Filter '*.json' -ErrorAction SilentlyContinue)
  foreach ($f in $files) {
    Run-Sizing @('ingest', '--db', $db, '--file', $f.FullName)
    Remove-Item -Force $f.FullName
  }
  Run-Sizing @('finish', '--db', $db, '--id', $it.Id)
  $done[$it.Id] = $true
  if ($failed.ContainsKey($it.Id)) { $failed.Remove($it.Id) }
  Save-State
  $stats = Get-Stats
  if ($stats) {
    Say ("  done in {0}. Running total: {1:N0} messages, {2} of media, {3}/{4} channels, elapsed {5}" -f `
      (Fmt-Span $chanClock.Elapsed), $stats.messages, (Fmt-Bytes $stats.media_bytes), $done.Count, $totalItems, (Fmt-Span $runClock.Elapsed))
  }
  if (($n % 10) -eq 0) { Run-Sizing @('report', '--db', $db, '--out', $outDir) }
}

Write-Progress -Id 2 -Activity 'channel' -Completed
Write-Progress -Id 1 -Activity 'sizing' -Completed
Say ("Run finished in {0}" -f (Fmt-Span $runClock.Elapsed))
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
Run-Sizing @('report', '--db', $db, '--out', $outDir)
if ($failed.Count -gt 0) {
  $failed.GetEnumerator() | ForEach-Object { "{0}`t{1}" -f $_.Key, $_.Value } | Set-Content -Encoding UTF8 (Join-Path $WorkDir 'failures.tsv')
  Say ("{0} channel(s) failed; reasons in {1}" -f $failed.Count, (Join-Path $WorkDir 'failures.tsv'))
}
Say "Done. Read: $(Join-Path $outDir 'sizing-summary.md')"

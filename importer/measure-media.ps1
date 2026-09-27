# measure-media.ps1 — size your Discord archive BEFORE choosing storage.
#
# Run this on your PC (Windows x64), not on the ARM VM: the DiscordChatExporter
# Docker image is amd64-only. Uses the cross-platform npm CLI.
#
#   1. install once:  npm install -g @discord-chat-exporter/cli
#   2. set your token:  $env:DCE_TOKEN = "<your user token>"
#   3. run:              .\measure-media.ps1 -Guild <server-id> -Channel <channel-id>
#
# It exports ONE channel with media, then extrapolates across the whole server so
# you can size storage (Matrix media store, object storage, or both) from a
# measurement instead of a guess.
param(
  [Parameter(Mandatory = $true)][string]$Guild,
  [Parameter(Mandatory = $true)][string]$Channel,
  [string]$Out = "$env:USERPROFILE\discord-export-probe"
)

$ErrorActionPreference = 'Stop'
if (-not $env:DCE_TOKEN) { throw "Set `$env:DCE_TOKEN first (Settings > Developer Mode > Copy Token)." }
if (-not (Get-Command dce -ErrorAction SilentlyContinue)) {
  Write-Output "Installing @discord-chat-exporter/cli ..."
  npm install -g @discord-chat-exporter/cli
}

New-Item -ItemType Directory -Force -Path $Out | Out-Null
$mediaDir = Join-Path $Out 'media'

Write-Output "Exporting channel $Channel with media (this can take a while) ..."
dce export -t $env:DCE_TOKEN -c $Channel -f json -o (Join-Path $Out 'probe.json') --media --media-dir "$mediaDir\" --reuse-media

$json = Get-Content (Join-Path $Out 'probe.json') -Raw | ConvertFrom-Json
$messages = @($json.messages).Count
$bytes = (Get-ChildItem $mediaDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Sum Length).Sum
if (-not $bytes) { $bytes = 0 }
$mb = [math]::Round($bytes / 1MB, 1)
$perMsg = if ($messages -gt 0) { [math]::Round($bytes / $messages, 0) } else { 0 }
Write-Output ""
Write-Output "== probe channel =="
Write-Output "  messages      : $messages"
Write-Output "  media bytes   : $mb MB"
Write-Output "  per message   : $perMsg bytes"

Write-Output ""
Write-Output "== channels in guild $Guild =="
$channels = dce channels -t $env:DCE_TOKEN -g $Guild
$channels | Out-String | Write-Output

Write-Output "== extrapolation =="
Write-Output "  Measure a second, busier channel and compare. Then:"
Write-Output "    total media ~= (sum of messages across channels) x $perMsg bytes"
Write-Output "  Rough DB-only cost of the text (no media): ~2-3 KB per Matrix message"
Write-Output "  => a 1M-message archive is ~2-3 GB of Postgres, and media is whatever the"
Write-Output "     probe says. 50 GB of boot volume is the binding constraint, not RAM."
Write-Output ""
Write-Output "Keep probe.json: it is the manifest of what Discord still serves, so you can"
Write-Output "prove later whether anything was lost."

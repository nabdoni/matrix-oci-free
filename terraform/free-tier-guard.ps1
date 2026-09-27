# free-tier-guard.ps1 — Windows equivalent of free-tier-guard.sh.
# Fails if the live stack would leave OCI Always Free.
#   Always Free: A1 2 OCPU / 12 GB total, 200 GB block volume, 20 GB object storage,
#   50k object API requests/month, 10 TB egress/month, 1x 10 Mbps flexible LB.
# Usage:  .\free-tier-guard.ps1            # check current state
#         .\free-tier-guard.ps1 -Plan      # also list resource types in the pending plan
param([switch]$Plan)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# terraform is often not on PATH in a fresh PowerShell (winget puts it in a links dir)
if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    $candidates = @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\terraform.exe",
        "C:\Program Files\Terraform\terraform.exe"
    ) | Where-Object { Test-Path $_ }
    if ($candidates) { Set-Alias -Name terraform -Value ($candidates | Select-Object -First 1) }
    else { Write-Output 'terraform not found on PATH or in the usual install locations'; exit 2 }
}

$LimitOcpu = 2
$LimitMem  = 12
$LimitBlock = 200
$HomeRegion = if ($env:OCI_HOME_REGION) { $env:OCI_HOME_REGION } else { 'us-ashburn-1' }
# oci_core_instance.region in state is the short region KEY (e.g. "iad"), not the
# region NAME (e.g. "us-ashburn-1") that admins think in terms of. Compare like-for-like.
$RegionKeyMap = @{ 'us-ashburn-1' = 'iad' }
$HomeRegionKey = if ($RegionKeyMap.ContainsKey($HomeRegion)) { $RegionKeyMap[$HomeRegion] } else { $HomeRegion }

$problems = @()
$notes = @()

$state = terraform show -json | ConvertFrom-Json
$resources = @($state.values.root_module.resources)
foreach ($child in @($state.values.root_module.child_modules)) { $resources += @($child.resources) }
if (-not $resources -or $resources.Count -eq 0) { Write-Output "no resources in state (nothing deployed yet) - OK"; exit 0 }

$instances = @($resources | Where-Object { $_.type -eq 'oci_core_instance' })
$ocpu = 0; $mem = 0; $block = 0
foreach ($i in $instances) {
    $v = $i.values
    $o = if ($v.shape_config) { [int]$v.shape_config.ocpus } else { 0 }
    $m = if ($v.shape_config) { [int]$v.shape_config.memory_in_gbs } else { 0 }
    $ocpu += $o; $mem += $m
    $bootGb = [int]((@($v.source_details) | Select-Object -First 1).boot_volume_size_in_gbs)
    $block += $bootGb
    $notes += "instance $($v.display_name): $($v.shape) $o OCPU / $m GB, $bootGb GB boot volume, in $($v.availability_domain) @ $($v.region)"
    if ($v.region -and $v.region -ne $HomeRegionKey) { $problems += "instance in region key '$($v.region)'; Always Free compute only applies in $HomeRegion ('$HomeRegionKey')" }
    if ($v.shape -notlike '*A1*') { $notes += "non-A1 shape $($v.shape): E2.1.Micro (x2) is free, anything else is not" }
}
$block += [int](($resources | Where-Object { $_.type -eq 'oci_core_volume' } | ForEach-Object { $_.values.size_in_gbs } | Measure-Object -Sum).Sum)

if ($ocpu -gt $LimitOcpu)    { $problems += "A1 OCPU total $ocpu > $LimitOcpu free" }
if ($mem  -gt $LimitMem)     { $problems += "A1 memory total $mem GB > $LimitMem GB free" }
if ($block -gt $LimitBlock)  { $problems += "block volume total $block GB > $LimitBlock GB free" }
$notes += "block volume provisioned: $block GB of $LimitBlock GB free"
$notes += "A1 shape: $ocpu OCPU / $mem GB of $LimitOcpu OCPU / $LimitMem GB free"

$watch = @{
    'oci_nat_gateway'                  = 'NAT gateway is NOT Always Free'
    'oci_waf'                          = 'WAF is NOT Always Free'
    'oci_public_ip'                    = 'reserved public IPs are not Always Free'
    'oci_load_balancer'                = 'one 10 Mbps flexible LB is free'
    'oci_flexible_load_balancer'       = 'one 10 Mbps flexible LB is free'
    'oci_database_autonomous_database' = '2 x 20 GB ADB instances are free'
    'oci_bastion'                      = 'Bastion is free (5 bastions)'
}
foreach ($type in $watch.Keys) {
    $count = @($resources | Where-Object { $_.type -eq $type }).Count
    if ($count -gt 0) { $notes += "$type x$count present - verify: $($watch[$type])" }
}

Write-Output '== free-tier guard =='
$notes | ForEach-Object { Write-Output "  - $_" }
if ($problems.Count -gt 0) {
    Write-Output '!! BLOCKING ISSUES'
    $problems | ForEach-Object { Write-Output "  X $_" }
    exit 1
}
Write-Output 'OK: inside Always Free allowances.'

if ($Plan) {
    $planFile = Join-Path $env:TEMP 'buncha-plan.tfplan'
    terraform plan -out=$planFile | Out-Null
    $p = (terraform show -json $planFile | ConvertFrom-Json).resource_changes |
        Where-Object { $_.change.actions -ne 'no-op' } |
        Select-Object -ExpandProperty type -Unique
    Write-Output '== resource types changing in plan =='
    $p | ForEach-Object { Write-Output "  - $_" }
}
exit 0

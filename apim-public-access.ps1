#Requires -Version 7
<#
.SYNOPSIS
  Opens or closes APIM's public inbound endpoint, leaving the private endpoint as
  the only way in when closed.
.DESCRIPTION
  APIM must be CREATED with public access enabled - Azure rejects a service that
  has a private endpoint yet starts Disabled (ActivateServiceWithPrivateEndpoint-
  AccessNotAllowed) - so step 2 ships public-enabled. Once step 2 has created APIM
  AND its private endpoint, this flips publicNetworkAccess with a single targeted
  update: no full redeploy. The agent path is unaffected either way, because it
  always uses the private endpoint.
.PARAMETER Access
  Target state for the public inbound endpoint: Disabled (default, closes it) or
  Enabled (reopens it).
.PARAMETER NoWait
  Return as soon as the update is accepted instead of waiting for it to finish. An
  APIM update can take 15-30 minutes; use this to fire it and check back later.
.EXAMPLE
  pwsh -File .\apim-public-access.ps1
  Closes public inbound (default -Access Disabled) and waits for confirmation.
.EXAMPLE
  pwsh -File .\apim-public-access.ps1 -Access Enabled
  Reopens public inbound.
#>
[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'params\lab.json'),
  [ValidateSet('Enabled', 'Disabled')]
  [string]$Access = 'Disabled',
  [switch]$NoWait
)

$ErrorActionPreference = 'Stop'

$lab = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$rg  = $lab.resourceGroupName

# Discover APIM live rather than deriving the name: a redeployment under a
# different deployment name would leave a derived name stale, and there is only
# ever one gateway in this resource group.
$apim = az apim list -g $rg --query "[0].name" -o tsv 2>$null
if (-not $apim) { throw "No APIM found in '$rg'. Deploy step 2 first." }

# publicNetworkAccess (Enabled/Disabled) is the ARM source of truth.
$target = $Access

$info = az apim show -g $rg -n $apim --query "{public:publicNetworkAccess, state:provisioningState}" -o json 2>$null | ConvertFrom-Json
$current = $info.public
if ($current -eq $target) {
  $other = if ($target -eq 'Disabled') { 'Enabled' } else { 'Disabled' }
  Write-Host "APIM '$apim' public access is already $target - nothing to do. Run with -Access $other to change it." -ForegroundColor Green
  return
}
if ($info.state -eq 'Updating') {
  Write-Host "APIM '$apim' is currently Updating - another operation is in progress. Re-run once provisioningState is Succeeded." -ForegroundColor Yellow
  return
}

Write-Host "APIM '$apim' public access: $current -> $target" -ForegroundColor Cyan

# 'az apim update' pins an API version the StandardV2 SKU rejects
# (OperationSupportedInSkuForApiVersions), so PATCH the resource directly at a
# supported api-version. Build the URL with -f: interpolating "...$apimId?api..."
# mangles the query string and az resolves a bogus host.
$apimId = (az apim show -g $rg -n $apim --query id -o tsv 2>$null).Trim()
$url    = 'https://management.azure.com{0}?api-version=2024-05-01' -f $apimId
$body   = @{ properties = @{ publicNetworkAccess = $target } } | ConvertTo-Json -Compress

# Pass the body via a file, not inline: az.cmd on Windows strips the JSON quotes.
$bodyFile = New-TemporaryFile
try {
  $body | Set-Content -Path $bodyFile -Encoding ascii
  az rest --method patch --url $url --body "@$bodyFile" --only-show-errors | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to submit public-access change to $target on '$apim'." }
}
finally {
  Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
}

# The PATCH is a long-running operation - it returns before the change commits, so
# poll the ARM value rather than trusting the immediate response.
if ($NoWait) {
  Write-Host "Update submitted. Check completion with:" -ForegroundColor Green
  Write-Host "  az apim show -g $rg -n $apim --query publicNetworkAccess -o tsv   # -> $target"
  return
}

Write-Host "Waiting for the update to commit (an APIM update can take 15-30 minutes)..." -ForegroundColor Yellow
$deadline = (Get-Date).AddMinutes(30)
do {
  Start-Sleep -Seconds 20
  $now = az apim show -g $rg -n $apim --query publicNetworkAccess -o tsv 2>$null
} while ($now -ne $target -and (Get-Date) -lt $deadline)

if ($now -eq $target) {
  Write-Host "Done. APIM '$apim' public access is now $target." -ForegroundColor Green
}
else {
  Write-Warning "Still '$now' after 30 min - the operation may still be running. Re-check with: az apim show -g $rg -n $apim --query publicNetworkAccess -o tsv"
}

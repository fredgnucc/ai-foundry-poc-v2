#Requires -Version 7
<#
.SYNOPSIS
  Opens an SSH SOCKS tunnel to the jump host and launches a browser through it.
.DESCRIPTION
  The browser stays on your laptop, so you keep your existing Entra session. Only
  the TCP connections are relayed, from inside the VNet, where the Foundry
  data-plane hostname resolves to the private endpoint instead of a public one.

  DNS is deliberately resolved at the far end. Without that the browser would look
  up the data-plane host locally, get the public address, and be refused exactly
  as it is today.
.PARAMETER Url
  Page to open. Defaults to the Foundry portal.
.PARAMETER TunnelOnly
  Open the tunnel and print the proxy settings without launching a browser.
#>
[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'params\lab.json'),
  [string]$Url = 'https://ai.azure.com',
  [string]$IdentityFile,
  [switch]$TunnelOnly
)

$ErrorActionPreference = 'Stop'

$lab = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$rg = $lab.resourceGroupName

# Admin user is not committed to lab.json; it matches the template default.
$adminUser = if ($env:LAB_ADMIN_USER) { $env:LAB_ADMIN_USER } else { 'azureuser' }
$vm = az vm list -g $rg --query "[?starts_with(name,'vm-') && ends_with(name,'-jump')].name | [0]" -o tsv 2>$null
if (-not $vm) { throw "No jump host VM found in '$rg'. Deploy step 1 first." }

$power = az vm get-instance-view -g $rg -n $vm `
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv 2>$null
if ($power -ne 'PowerState/running') {
  Write-Host "Jump host '$vm' is $($power -replace 'PowerState/','') - starting it (~1 min)..." -ForegroundColor Yellow
  az vm start -g $rg -n $vm --only-show-errors | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to start jump host '$vm'." }
  Write-Host "Jump host '$vm' started." -ForegroundColor Green
} else {
  Write-Host "Jump host '$vm' is running." -ForegroundColor Green
}

# Names are derived the same way Bicep derives them, so nothing has to be passed
# between the deployment and this script.
$suffix = az deployment sub show -n aigwp-infra --query "properties.outputs.publicIpAddress.value" -o tsv 2>$null
if ($suffix) {
  $ip = $suffix
}
else {
  # Fall back to reading the address live, which survives a redeployment that
  # changed the deployment name.
  $pip = az network public-ip list -g $rg --query "[?starts_with(name,'pip-') && ends_with(name,'-jump')] | [0]" -o json 2>$null | ConvertFrom-Json
  if (-not $pip) { throw "No jump host public IP found in '$rg'. Deploy stage 4 first." }
  $ip = $pip.ipAddress
}

$socksPort = $lab.socksPort
$target = "$adminUser@$ip"

# Reuse a tunnel that is already up. Without this, opening a second one on the
# same port trips ExitOnForwardFailure and the script dies on a working setup.
$ssh = $null
$alreadyUp = Test-NetConnection -ComputerName 127.0.0.1 -Port $socksPort `
  -InformationLevel Quiet -WarningAction SilentlyContinue

if ($alreadyUp) {
  Write-Host "Reusing existing SOCKS proxy on 127.0.0.1:$socksPort" -ForegroundColor Green
}
else {
  # A stale entry from a previous VM on the same address makes ssh refuse to connect.
  $knownHosts = Join-Path $env:USERPROFILE '.ssh\known_hosts'
  if (Test-Path $knownHosts) {
    ssh-keygen -R "[$ip]:$($lab.sshPort)" 2>$null | Out-Null
    ssh-keygen -R $ip 2>$null | Out-Null
  }

  $sshArgs = @(
    '-p', $lab.sshPort
    '-D', "127.0.0.1:$socksPort"
    '-N'
    '-o', 'StrictHostKeyChecking=accept-new'
    '-o', 'ServerAliveInterval=30'
    '-o', 'ExitOnForwardFailure=yes'
  )
  if ($IdentityFile) { $sshArgs += @('-i', $IdentityFile) }
  $sshArgs += $target

  Write-Host "Opening SOCKS tunnel: ssh $($sshArgs -join ' ')" -ForegroundColor Cyan
  $ssh = Start-Process ssh -ArgumentList $sshArgs -PassThru -NoNewWindow

  # ExitOnForwardFailure means ssh dies rather than silently running without the
  # forward, so a live listener is proof the tunnel is actually usable.
  $listening = $false
  foreach ($i in 1..20) {
    Start-Sleep -Milliseconds 500
    if ($ssh.HasExited) { throw "ssh exited with code $($ssh.ExitCode) before the tunnel was established." }
    if (Test-NetConnection -ComputerName 127.0.0.1 -Port $socksPort -InformationLevel Quiet -WarningAction SilentlyContinue) {
      $listening = $true
      break
    }
  }
  if (-not $listening) {
    Stop-Process -Id $ssh.Id -ErrorAction SilentlyContinue
    throw "SOCKS proxy did not come up on 127.0.0.1:$socksPort."
  }

  Write-Host "SOCKS proxy listening on 127.0.0.1:$socksPort (ssh pid $($ssh.Id))" -ForegroundColor Green
}

if ($TunnelOnly) {
  Write-Host "`nPoint any client at socks5://127.0.0.1:$socksPort with remote DNS." -ForegroundColor Cyan
  Write-Host "Check what the jump host resolves, to confirm you are inside:" -ForegroundColor Cyan
  Write-Host "  ssh -p $($lab.sshPort) $target 'dig +short <account>.services.ai.azure.com'"
  if ($ssh) { Write-Host "Stop the tunnel with: Stop-Process -Id $($ssh.Id)" }
  return
}

$edge = Get-ChildItem @(
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge not found. Use -TunnelOnly and configure your browser manually.' }

# Verify the jump host resolves the data-plane name to a private address before
# handing the tunnel to a browser, where a failure just looks like a page error.
#
# Deliberately a DNS check, not an HTTP one: the public front door still
# terminates TLS and answers 200 on '/', so an HTTP probe passes even with no
# tunnel at all and proves nothing.
$probeHost = az cognitiveservices account list -g $lab.resourceGroupName -o json 2>$null |
  ConvertFrom-Json | Select-Object -First 1
if ($probeHost -and $probeHost.properties.endpoint) {
  $name = ([Uri]$probeHost.properties.endpoint).Host
  $resolved = (ssh -p $lab.sshPort -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 `
    $target "dig +short $name" 2>$null) | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1

  if (-not $resolved) {
    Write-Warning "Could not resolve $name on the jump host. The tunnel may still work; check the private DNS zone links."
  }
  elseif ($resolved -notmatch '^(10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)') {
    Write-Warning "$name resolves to $resolved on the jump host - a public address. The private DNS zone link is missing, so the browser will be refused."
  }
  else {
    Write-Host "Jump host resolves $name -> $resolved (private)" -ForegroundColor Green
  }
}

# A throwaway profile keeps this out of your normal browser: the proxy applies to
# the whole process, and you do not want your day-to-day tabs routed through Azure.
$profileDir = Join-Path $env:TEMP 'aigwp-jump-profile'

# Built as ONE pre-quoted string, not an array. Start-Process joins an array with
# spaces and adds no quoting, so --host-resolver-rules (whose value contains
# spaces) is split into separate argv entries: Edge receives a truncated
# '--host-resolver-rules=MAP' and opens the remaining fragments as URLs, giving
# five junk tabs.
#
# The MAP rule is defensive, not the mechanism. Measured: with the rule mangled
# and therefore ignored, the private portal still loaded - Chromium already sends
# hostnames to a socks5:// proxy rather than resolving them locally. The rule
# guarantees it rather than relying on that default.
# EXCLUDE 127.0.0.1 keeps the proxy itself reachable.
$edgeArgs = '--user-data-dir="{0}" --proxy-server="socks5://127.0.0.1:{1}" --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" --no-first-run --no-default-browser-check "{2}"' -f $profileDir, $socksPort, $Url

Write-Host "Launching Edge through the tunnel (throwaway profile: $profileDir)" -ForegroundColor Cyan
Start-Process $edge.FullName -ArgumentList $edgeArgs | Out-Null

Write-Host "`nWhen you are done:" -ForegroundColor Yellow
if ($ssh) {
  Write-Host "  Stop-Process -Id $($ssh.Id)   # closes the tunnel"
}
else {
  Write-Host "  close the ssh window you opened manually   # this script reused it"
}

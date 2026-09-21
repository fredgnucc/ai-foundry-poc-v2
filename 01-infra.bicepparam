using '01-infra.bicep'

// params/lab.json is the single source of truth for structural configuration.
// The two user-specific values - your SSH source address and public key - are
// read from the environment instead, so nothing personal is ever committed.
var lab = loadJsonContent('params/lab.json')

param location = lab.location
param resourceGroupName = lab.resourceGroupName
param namePrefix = lab.namePrefix
param nameSeed = lab.nameSeed
param tags = lab.tags

param vnetAddressPrefix = lab.vnetAddressPrefix
param apimSubnetPrefix = lab.apimSubnetPrefix
param agentSubnetPrefix = lab.agentSubnetPrefix
param peSubnetPrefix = lab.peSubnetPrefix
param jumpSubnetPrefix = lab.jumpSubnetPrefix

param sshPort = lab.sshPort
param jumpVmSize = lab.jumpVmSize

// Optional. Source allowed to SSH to the jump host; defaults to "*" (any
// address) because access is gated by your SSH key, not by IP - convenient for a
// roaming POC. Lock it to a /32 by setting it first:
//   $env:LAB_SSH_SOURCE = "$((Invoke-RestMethod https://api.ipify.org))/32"
param allowedSshSource = readEnvironmentVariable('LAB_SSH_SOURCE', '*')

// Optional, defaults to azureuser:
//   $env:LAB_ADMIN_USER = 'someoneelse'
param adminUsername = readEnvironmentVariable('LAB_ADMIN_USER', 'azureuser')

// Required. Your SSH public key - set it first:
//   $env:LAB_SSH_PUBKEY = (Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" -Raw).Trim()
param sshPublicKey = readEnvironmentVariable('LAB_SSH_PUBKEY')

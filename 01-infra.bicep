targetScope = 'subscription'

metadata description = '''
Step 1 of 3 - infrastructure.

Resource group, the VNet with its four subnets (two of them delegated), NSGs,
private DNS zones, and a jump host. Costs almost nothing and proves the two
subnet delegations are accepted before any billable service is created.

The jump host exists because the next step disables the Foundry account's public
data plane: once that happens nothing on your laptop can reach it, so you need a
host inside the VNet to test from. Its SSH source and key are read from the
environment (see 01-infra.bicepparam) so no personal address or key is committed.
'''

import { resourceSuffix, labNames } from './shared/naming.bicep'

// No defaults anywhere: every value comes from params/lab.json (or the
// environment, for the two user-specific ones), so there is one source of truth
// and a missing value fails loudly.
param location string
param resourceGroupName string
param namePrefix string
param nameSeed string
param tags object

param vnetAddressPrefix string
param apimSubnetPrefix string
param agentSubnetPrefix string
param peSubnetPrefix string
param jumpSubnetPrefix string

@description('SSH port the jump host listens on. Kept off 22 on purpose: a tenant policy strips internet-facing inbound-22 rules minutes after deployment.')
param sshPort int

@description('Source allowed to reach the SSH port. Defaults to "*" (any address) via the bicepparam because access is gated by the SSH key; override with a /32 to lock it down.')
param allowedSshSource string

param jumpVmSize string

@description('Admin user for the jump host. Defaults to azureuser via the bicepparam.')
param adminUsername string

@description('SSH public key authorised on the jump host. Supplied from an environment variable so it never lands in a committed file.')
param sshPublicKey string

var names = labNames(namePrefix, resourceSuffix(subscription().id, resourceGroupName, namePrefix, nameSeed))

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module network 'modules/network.bicep' = {
  scope: rg
  name: 'network'
  params: {
    location: location
    tags: tags
    vnetName: names.vnet
    vnetAddressPrefix: vnetAddressPrefix
    apimSubnetPrefix: apimSubnetPrefix
    agentSubnetPrefix: agentSubnetPrefix
    peSubnetPrefix: peSubnetPrefix
    jumpSubnetPrefix: jumpSubnetPrefix
    sshPort: sshPort
    allowedSshSource: allowedSshSource
  }
}

// CRLF must be stripped first. cloud-init decides how to handle user-data by
// matching the first line against '#cloud-config'; a trailing \r makes that
// match fail, so the whole document is classified 'text/x-not-multipart' and
// silently ignored - the VM boots with a default sshd and no error anywhere.
var cloudInit = replace(
  replace(loadTextContent('modules/cloud-init.yaml'), '\r\n', '\n'),
  '__SSH_PORT__',
  string(sshPort)
)

module jumpHost 'modules/jump-host.bicep' = {
  scope: rg
  name: 'jump-host'
  params: {
    location: location
    tags: tags
    subnetId: network.outputs.jumpSubnetId
    publicIpName: names.jumpPip
    vmName: names.jumpVm
    vmSize: jumpVmSize
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    cloudInit: cloudInit
  }
}

output vnetName string = names.vnet
output apimSubnetId string = network.outputs.apimSubnetId
output agentSubnetId string = network.outputs.agentSubnetId
output peSubnetId string = network.outputs.peSubnetId
output jumpSubnetId string = network.outputs.jumpSubnetId
output jumpVmName string = jumpHost.outputs.vmName
output publicIpAddress string = jumpHost.outputs.publicIpAddress
output privateIpAddress string = jumpHost.outputs.privateIpAddress
output sshCommand string = 'ssh -p ${sshPort} -D 1080 ${adminUsername}@${jumpHost.outputs.publicIpAddress}'

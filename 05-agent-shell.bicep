targetScope = 'subscription'

metadata description = '''
Step 5 (optional) - shell access for the step-4 hosted agent.

Additive: it does NOT modify steps 1-4. It adds a private Key Vault (with its
private DNS zone and endpoint) holding the SSH key of the jump-host user
'foundrydiag', readable only by the agent, and a VM runCommand that creates that
user (key accepted only from the agent subnet; sudo only with allowSudo).

Run it through enable-shell.py: it generates the key pair, deploys this, and posts
the agent version with the run_command tool.
'''

import { resourceSuffix, labNames, subnetNames } from './shared/naming.bicep'

param location string
param tags object
param resourceGroupName string
param namePrefix string
param nameSeed string
param projectName string
param sshPort int
param agentSubnetPrefix string

@description('Agent identity of the hosted agent (read by enable-shell.py).')
param agentPrincipalId string

@secure()
@description('OpenSSH ed25519 private key for sshUser.')
param sshPrivateKey string

@description('OpenSSH public key line matching sshPrivateKey.')
param sshPublicKey string

@description('PoC only: passwordless sudo for sshUser on the jump host.')
param allowSudo bool = false

param sshUser string = 'foundrydiag'
param secretName string = 'jump-ssh-key'

var names = labNames(namePrefix, resourceSuffix(subscription().id, resourceGroupName, namePrefix, nameSeed))
var vaultName = take('kv-${namePrefix}-${resourceSuffix(subscription().id, resourceGroupName, namePrefix, nameSeed)}', 24)

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: resourceGroupName
}

resource jumpNic 'Microsoft.Network/networkInterfaces@2024-05-01' existing = {
  scope: rg
  name: '${names.jumpVm}-nic-01'
}

module shell 'modules/agent-shell.bicep' = {
  scope: rg
  name: 'agent-shell'
  params: {
    location: location
    tags: tags
    vaultName: vaultName
    vnetName: names.vnet
    peSubnetName: subnetNames.privateEndpoints
    accountName: names.account
    projectName: projectName
    agentPrincipalId: agentPrincipalId
    sshPrivateKey: sshPrivateKey
    secretName: secretName
    jumpVmName: names.jumpVm
    sshUser: sshUser
    sshPublicKey: sshPublicKey
    agentSubnetPrefix: agentSubnetPrefix
    allowSudo: allowSudo
  }
}

var sshHost = jumpNic.properties.ipConfigurations[0].properties.privateIPAddress

output vaultUri string = shell.outputs.vaultUri
output secretName string = secretName
output sshHost string = sshHost
output sshPort int = sshPort
output sshUser string = sshUser
output allowSudo bool = allowSudo
@description('runCommand whose instance view holds the jump host key (HOSTKEY line).')
output setupRunCommandId string = shell.outputs.setupRunCommandId

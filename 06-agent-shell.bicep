targetScope = 'subscription'

metadata description = '''
Step 6 (optional) - shell access for the step-5 hosted agent.

Additive: it does NOT modify steps 1-5. It adds a private Key Vault (with its
private DNS zone and endpoint) holding the SSH key of a non-sudo jump-host user,
readable only by the agent. hosted-agent.py --enable-shell reads this
deployment's outputs and passes them to the agent as SSH_* settings.

The jump-host user and its authorized_keys are created over SSH, not here
(see README, Step 6).
'''

import { resourceSuffix, labNames, subnetNames } from './shared/naming.bicep'

param location string
param tags object
param resourceGroupName string
param namePrefix string
param nameSeed string
param projectName string
param sshPort int

@description('Agent identity of the hosted agent (printed by hosted-agent.py).')
param agentPrincipalId string

@secure()
@description('OpenSSH ed25519 private key for sshUser.')
param sshPrivateKey string

@description('Public host key line of the jump host, e.g. "ssh-ed25519 AAAA...". Pinned by the agent.')
param jumpHostKey string

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
  }
}

var sshHost = jumpNic.properties.ipConfigurations[0].properties.privateIPAddress

output vaultUri string = shell.outputs.vaultUri
output secretName string = secretName
output sshHost string = sshHost
output sshPort int = sshPort
output sshUser string = sshUser
output sshKnownHost string = '[${sshHost}]:${sshPort} ${jumpHostKey}'

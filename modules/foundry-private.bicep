metadata description = '''
Foundry account with agent compute injected into your virtual network.

This is the piece that changes the architecture: with networkInjections the agent
runtime runs in your delegated subnet instead of on the Microsoft-managed platform
network, so it can reach a private API Management gateway. Without it, agent calls
egress from a platform public IP and a private gateway is unreachable.

Note networkInjections uses `subnetArmId`, not the usual `subnetResourceId`.
Injection can only be set at account creation - it cannot be added later.
'''

import { privateDnsZoneNames } from '../shared/naming.bicep'

param location string
param tags object
param accountName string
param modelName string
param modelVersion string
param modelCapacity int

@description('Deployment SKU, e.g. GlobalStandard or DataZoneStandard (separate quota).')
param modelSku string

@description('False when the chat model lives in a separate model account (option C).')
param deployModel bool = true

@description('Subnet delegated to Microsoft.App/environments that hosts agent compute.')
param agentSubnetId string

@description('Subnet for the account private endpoint.')
param peSubnetId string

@description('Foundry project name. Created plain here; agent runtime is added in a later stage.')
param projectName string

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    // No public data plane: the gateway reaches the model over a private endpoint.
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: []
      ipRules: []
    }
    networkInjections: [
      {
        scenario: 'agent'
        subnetArmId: agentSubnetId
        useMicrosoftManagedNetwork: false
      }
    ]
    // Left enabled because APIM authenticates to the model with its managed
    // identity anyway; the account-level capability host requires local auth
    // during provisioning in the reference template.
    disableLocalAuth: false
  }
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = if (deployModel) {
  parent: account
  name: modelName
  sku: {
    name: modelSku
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

// Plain project: no BYO connections and no capability host yet. Those arrive in
// a later stage, so the gateway path can be proven before the expensive
// Cosmos/Search/Storage dependencies exist.
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: account
  name: projectName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: projectName
  }
  dependsOn: [ deployment ]
}

module accountPe 'private-endpoint.bicep' = {
  name: 'pe-account'
  params: {
    location: location
    tags: tags
    name: 'pe-${accountName}'
    subnetId: peSubnetId
    targetResourceId: account.id
    groupId: 'account'
    // All three zones are required: Foundry, OpenAI and Cognitive Services
    // hostnames all resolve to the same private endpoint.
    privateDnsZoneNames: privateDnsZoneNames.foundry
  }
}

output accountId string = account.id
output accountName string = account.name
output accountPrincipalId string = account.identity.principalId
output deploymentName string = modelName
output projectName string = project.name
output projectPrincipalId string = project.identity.principalId

metadata description = '''
Model-only Foundry account (option C). It holds the chat model and nothing else:
no projects, no agent network injection, no local auth, private endpoint only.

Why: a hosted agent's identity can always call the models of its own project's
account through the project endpoint, without any role. With the model here,
the project's account has no chat model to call, so the only way to the model is
the gateway, whose managed identity is the only caller with a role on this account.
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
param peSubnetId string

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: accountName
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
      virtualNetworkRules: []
      ipRules: []
    }
    // Entra only: the gateway's managed identity is the one caller.
    disableLocalAuth: true
  }
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
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

module pe 'private-endpoint.bicep' = {
  name: 'pe-${accountName}'
  params: {
    location: location
    tags: tags
    name: 'pe-${accountName}'
    subnetId: peSubnetId
    targetResourceId: account.id
    groupId: 'account'
    privateDnsZoneNames: privateDnsZoneNames.foundry
  }
}

output accountName string = account.name
output deploymentName string = deployment.name

targetScope = 'subscription'

metadata description = '''
Step 2 of 3 - the AI Gateway.

Foundry account with agent network injection, the model deployment, a plain
project, and the account private endpoint; API Management Standard v2 with
outbound VNet integration plus its own inbound private endpoint; gateway
diagnostics; and the association that wires them together (RBAC, backend, API,
policy, product, links, and the admin-connected model).

This is the headline result: model traffic flows through APIM over private
networking, before the expensive Cosmos / Search / Storage dependencies exist.
The agent's egress is still a public Microsoft address at this point - that only
moves into your VNet in step 3, once the project capability host is set.

References the VNet and subnets created in step 1 with `existing` (instead of
resourceId(): at subscription scope the resourceId(rg, type, ...) overload is
ambiguous for a nested type and ARM misreads the resource group as a sub id).
'''

import { resourceSuffix, labNames, subnetNames, productName, privateDnsZoneNames } from './shared/naming.bicep'

param location string
param resourceGroupName string
param namePrefix string
param nameSeed string
param tags object

param projectName string
param modelName string
param modelVersion string
param modelCapacity int
param inferenceApiVersion string

@description('APIM publisher email (required by the service).')
param publisherEmail string

@description('''
Whether the gateway keeps a public inbound endpoint (it always also has a private
endpoint). Azure only allows APIM to be *created* with public access enabled, so
leave this true for the first apply of step 2. To reach the genuinely-closed
state, re-apply step 2 with this set to false: on an APIM that already has its
private endpoint, disabling public access is a valid update. The agent path is
private either way - it reaches the gateway through the private endpoint from
inside the VNet.
''')
param allowPublicGatewayAccess bool

@description('Per-minute token limit enforced at the gateway. 0 disables it.')
param tokenLimitPerMinute int

var names = labNames(namePrefix, resourceSuffix(subscription().id, resourceGroupName, namePrefix, nameSeed))

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: names.vnet
  scope: resourceGroup(resourceGroupName)

  resource agentSubnet 'subnets' existing = {
    name: subnetNames.agent
  }

  resource apimSubnet 'subnets' existing = {
    name: subnetNames.apim
  }

  resource peSubnet 'subnets' existing = {
    name: subnetNames.privateEndpoints
  }
}

var subnetId = {
  agent: vnet::agentSubnet.id
  apim: vnet::apimSubnet.id
  privateEndpoints: vnet::peSubnet.id
}

module foundry 'modules/foundry-private.bicep' = {
  scope: resourceGroup(resourceGroupName)
  name: 'foundry'
  params: {
    location: location
    tags: tags
    accountName: names.account
    projectName: projectName
    modelName: modelName
    modelVersion: modelVersion
    modelCapacity: modelCapacity
    agentSubnetId: subnetId.agent
    peSubnetId: subnetId.privateEndpoints
  }
}

module gateway 'modules/gateway.bicep' = {
  scope: resourceGroup(resourceGroupName)
  name: 'gateway'
  params: {
    location: location
    tags: tags
    apimName: names.apim
    // Standard v2 only. Basic v2 has no VNet capability; Premium v2 would need
    // injection - a different subnet delegation and manual private DNS.
    apimSku: 'StandardV2'
    publisherEmail: publisherEmail
    publisherName: '${names.account} AI Gateway'
    integrationSubnetId: subnetId.apim
    publicNetworkAccess: allowPublicGatewayAccess ? 'Enabled' : 'Disabled'
  }
}

module gatewayPe 'modules/private-endpoint.bicep' = {
  scope: resourceGroup(resourceGroupName)
  name: 'gateway-pe'
  params: {
    location: location
    tags: tags
    name: 'pe-${names.apim}'
    subnetId: subnetId.privateEndpoints
    targetResourceId: gateway.outputs.apimId
    groupId: 'Gateway'
    privateDnsZoneNames: privateDnsZoneNames.apim
  }
}

// The only way to observe the agent's real source address: delegated-subnet IP
// usage is not exposed anywhere else in Azure. See modules/observability.bicep.
module observability 'modules/observability.bicep' = {
  scope: resourceGroup(resourceGroupName)
  name: 'observability'
  params: {
    location: location
    tags: tags
    workspaceName: names.logAnalytics
    apimName: names.apim
    diagnosticSettingName: 'diag-${namePrefix}-apim'
  }
  dependsOn: [ gateway ]
}

// Wires the gateway to the account. Depends on both because it references the
// APIM managed identity and the Foundry account/project as existing resources.
module association 'modules/association.bicep' = {
  scope: resourceGroup(resourceGroupName)
  name: 'association'
  params: {
    accountName: names.account
    apimName: names.apim
    projectName: projectName
    productName: productName(names.account, projectName)
    modelName: modelName
    modelVersion: modelVersion
    inferenceApiVersion: inferenceApiVersion
    tokenLimitPerMinute: tokenLimitPerMinute
  }
  dependsOn: [ foundry, gateway ]
}

output accountName string = names.account
output projectName string = foundry.outputs.projectName
output deploymentName string = foundry.outputs.deploymentName
// connectionName is the admin-connected model connection created by association;
// it is named after the account. agent.py-style callers use it to route through
// the gateway rather than directly to the model.
output connectionName string = names.account
output apimName string = names.apim
output workspaceName string = observability.outputs.workspaceName
output projectEndpoint string = 'https://${names.account}.services.ai.azure.com/api/projects/${projectName}'
output gatewayEndpoint string = 'https://${names.apim}.azure-api.net/${names.account}'

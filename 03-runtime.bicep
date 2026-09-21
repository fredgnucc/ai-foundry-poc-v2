targetScope = 'subscription'

metadata description = '''
Step 3 of 3 - the standard agent runtime.

BYO dependencies (Cosmos DB, AI Search, Storage - all public access disabled,
reached over private endpoints), then the connections, RBAC and the project
capability host that activate the runtime.

Setting the project capability host is the single trigger that makes the platform
provision the single-tenant data proxy inside the delegated agent subnet. After
this, the agent's outbound traffic originates from a 10.x address in that subnet
instead of a public Microsoft one - which is the whole point of the lab, and is
observable in the APIM gateway log (see queries.kql).

One-way door: a capability host cannot be updated once created. To change it you
delete and recreate the project. Existing agents and threads are NOT migrated
from Microsoft-managed storage, so recreate any agent after this step.

References the VNet / PE subnet from step 1 and the account/project from step 2
with `existing`.
'''

import { resourceSuffix, labNames, subnetNames } from './shared/naming.bicep'

param location string
param resourceGroupName string
param namePrefix string
param nameSeed string
param tags object

@description('AI Search tier. Standard matches the Microsoft reference template; basic is cheaper and is enough for this lab.')
@allowed([ 'basic', 'standard' ])
param searchSku string

param projectName string

@description('Capability host name. Arbitrary, but only one per project and immutable once created.')
param capabilityHostName string

var names = labNames(namePrefix, resourceSuffix(subscription().id, resourceGroupName, namePrefix, nameSeed))

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: names.vnet
  scope: resourceGroup(resourceGroupName)

  resource peSubnet 'subnets' existing = {
    name: subnetNames.privateEndpoints
  }
}

module dependencies 'modules/dependencies.bicep' = {
  scope: resourceGroup(resourceGroupName)
  name: 'dependencies'
  params: {
    location: location
    tags: tags
    storageName: names.storage
    cosmosName: names.cosmos
    searchName: names.search
    searchSku: searchSku
    peSubnetId: vnet::peSubnet.id
  }
}

// The capability host provisions containers in Cosmos, so the whole runtime must
// wait for the dependencies to exist first.
module agentRuntime 'modules/agent-runtime.bicep' = {
  scope: resourceGroup(resourceGroupName)
  name: 'agent-runtime'
  params: {
    accountName: names.account
    projectName: projectName
    storageName: names.storage
    cosmosName: names.cosmos
    searchName: names.search
    capabilityHostName: capabilityHostName
  }
  dependsOn: [ dependencies ]
}

output storageName string = dependencies.outputs.storageName
output cosmosName string = dependencies.outputs.cosmosName
output searchName string = dependencies.outputs.searchName
output capabilityHostName string = agentRuntime.outputs.capabilityHostName

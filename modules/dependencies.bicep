metadata description = '''
BYO dependencies required by the Foundry Standard Agent Setup: Cosmos DB (threads),
AI Search (vectors) and Storage (files). All three are created with public network
access disabled and reached over private endpoints.

Values here mirror Microsoft's network-secured reference template, including the
non-obvious ones: Storage must allow no shared-key access, Cosmos disables local
auth, and AI Search needs the aadOrApiKey auth option for Foundry's AAD connection.
Source: https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup
'''

import { privateDnsZoneNames } from '../shared/naming.bicep'

param location string
param tags object
param storageName string
param cosmosName string
param searchName string
param peSubnetId string

@description('AI Search tier. The reference template uses standard; basic also supports private endpoints but not all agent features.')
@allowed([ 'basic', 'standard' ])
param searchSku string

// Standard ZRS is unavailable in a few regions, fall back to GRS there.
var noZrsRegions = [ 'southindia', 'westus' ]
var storageSku = contains(noZrsRegions, location) ? 'Standard_GRS' : 'Standard_ZRS'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: storageSku }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    // Foundry authenticates to storage with a managed identity, so shared keys
    // are switched off entirely rather than merely left unused.
    allowSharedKeyAccess: false
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: []
    }
  }
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: cosmosName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    disableLocalAuth: true
    enableAutomaticFailover: false
    enableMultipleWriteLocations: false
    enableFreeTier: false
    publicNetworkAccess: 'Disabled'
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
  }
}

resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: searchName
  location: location
  tags: tags
  sku: { name: searchSku }
  identity: { type: 'SystemAssigned' }
  properties: {
    // Foundry's CognitiveSearch connection uses AAD. Local auth stays enabled but
    // aadOrApiKey is what makes the AAD path work; apiKeyOnly would 403 the agent.
    disableLocalAuth: false
    authOptions: {
      aadOrApiKey: { aadAuthFailureMode: 'http401WithBearerChallenge' }
    }
    hostingMode: 'default'
    partitionCount: 1
    replicaCount: 1
    semanticSearch: 'disabled'
    publicNetworkAccess: 'disabled'
    networkRuleSet: {
      bypass: 'None'
      ipRules: []
    }
  }
}

module storagePe 'private-endpoint.bicep' = {
  name: 'pe-storage'
  params: {
    location: location
    tags: tags
    name: 'pe-${storageName}-blob'
    subnetId: peSubnetId
    targetResourceId: storage.id
    groupId: 'blob'
    privateDnsZoneNames: privateDnsZoneNames.storage
  }
}

module cosmosPe 'private-endpoint.bicep' = {
  name: 'pe-cosmos'
  params: {
    location: location
    tags: tags
    name: 'pe-${cosmosName}-sql'
    subnetId: peSubnetId
    targetResourceId: cosmos.id
    groupId: 'Sql'
    privateDnsZoneNames: privateDnsZoneNames.cosmos
  }
}

module searchPe 'private-endpoint.bicep' = {
  name: 'pe-search'
  params: {
    location: location
    tags: tags
    name: 'pe-${searchName}'
    subnetId: peSubnetId
    targetResourceId: search.id
    groupId: 'searchService'
    privateDnsZoneNames: privateDnsZoneNames.search
  }
}

output storageId string = storage.id
output storageName string = storage.name
output cosmosId string = cosmos.id
output cosmosName string = cosmos.name
output searchId string = search.id
output searchName string = search.name

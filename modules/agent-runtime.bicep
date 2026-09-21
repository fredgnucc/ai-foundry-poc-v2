metadata description = '''
Turns a plain Foundry project into a standard agent runtime: BYO connections,
the RBAC the runtime needs, and the capability host that activates it.

Ordering is load-bearing and is the usual source of failure:
  connections -> control-plane RBAC -> capability host -> Cosmos data-plane role
The capability host provisions containers in Cosmos, so the data-plane role that
targets them can only be assigned once it exists.

Do NOT create an account-level capability host. The resource provider creates
`{account}@aml_aiagentservice` automatically when the account is deployed with
networkInjections.scenario=agent; a second one fails with HTTP 409 on the same ClientId.
'''

param accountName string
param projectName string
param storageName string
param cosmosName string
param searchName string

@description('Capability host name. Arbitrary, but only one per project.')
param capabilityHostName string

var storageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var cosmosDbOperator = '230815da-be43-4aae-9cb4-875f7bd000aa'
var searchIndexDataContributor = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
var searchServiceContributor = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
var cosmosBuiltInDataContributor = '00000000-0000-0000-0000-000000000002'

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: account
  name: projectName
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageName
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-12-01-preview' existing = {
  name: cosmosName
}

resource search 'Microsoft.Search/searchServices@2024-06-01-preview' existing = {
  name: searchName
}

resource cosmosConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: project
  name: cosmosName
  properties: {
    category: 'CosmosDB'
    target: cosmos.properties.documentEndpoint
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: cosmos.id
      location: cosmos.location
    }
  }
}

resource storageConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: project
  name: storageName
  properties: {
    category: 'AzureStorageAccount'
    target: storage.properties.primaryEndpoints.blob
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: storage.id
      location: storage.location
    }
  }
}

resource searchConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: project
  name: searchName
  properties: {
    category: 'CognitiveSearch'
    target: 'https://${searchName}.search.windows.net'
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: search.id
      location: search.location
    }
  }
}

resource storageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, project.id, storageBlobDataContributor)
  properties: {
    principalId: project.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributor)
    principalType: 'ServicePrincipal'
  }
}

resource cosmosRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: cosmos
  name: guid(cosmos.id, project.id, cosmosDbOperator)
  properties: {
    principalId: project.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cosmosDbOperator)
    principalType: 'ServicePrincipal'
  }
}

resource searchIndexRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: search
  name: guid(search.id, project.id, searchIndexDataContributor)
  properties: {
    principalId: project.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataContributor)
    principalType: 'ServicePrincipal'
  }
}

resource searchServiceRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: search
  name: guid(search.id, project.id, searchServiceContributor)
  properties: {
    principalId: project.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchServiceContributor)
    principalType: 'ServicePrincipal'
  }
}

resource capabilityHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview' = {
  parent: project
  name: capabilityHostName
  properties: {
    // The Bicep type for capabilityHosts is stale and rejects capabilityHostKind,
    // but the ARM API requires it - without it agents fail at runtime.
    #disable-next-line BCP037
    capabilityHostKind: 'Agents'
    threadStorageConnections: [ cosmosName ]
    storageConnections: [ storageName ]
    vectorStoreConnections: [ searchName ]
  }
  dependsOn: [
    cosmosConnection
    storageConnection
    searchConnection
    storageRole
    cosmosRole
    searchIndexRole
    searchServiceRole
  ]
}

// Data-plane role on the containers the capability host just provisioned.
resource cosmosDataRole 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2022-05-15' = {
  parent: cosmos
  name: guid(project.id, cosmos.id, cosmosBuiltInDataContributor)
  properties: {
    principalId: project.identity.principalId
    roleDefinitionId: resourceId('Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions', cosmosName, cosmosBuiltInDataContributor)
    scope: '${cosmos.id}/dbs/enterprise_memory'
  }
  dependsOn: [ capabilityHost ]
}

output capabilityHostName string = capabilityHost.name

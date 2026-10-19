metadata description = '''
Private Key Vault holding the hosted agent's SSH key for the jump host.
RBAC only, no public access; the agent reads it through a private endpoint.
'''

param location string
param tags object
param vaultName string
param vnetName string
param peSubnetName string
param accountName string
param projectName string

@description('Agent identity (instance_identity.principal_id of the hosted agent).')
param agentPrincipalId string

@secure()
@description('OpenSSH ed25519 private key of the jump-host user.')
param sshPrivateKey string

param secretName string

var zoneName = 'privatelink.vaultcore.azure.net'
var secretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  name: '${accountName}/${projectName}'
}

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneName
  location: 'global'
  tags: tags
}

resource zoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: vnetName
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: vaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
    softDeleteRetentionInDays: 7
  }
}

// Written through ARM, so the deployer needs no data-plane network access.
resource secret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: vault
  name: secretName
  properties: {
    value: sshPrivateKey
    contentType: 'application/x-openssh-key'
  }
}

// The sandbox credential may be the agent identity or the project identity, so both
// may read this one secret and nothing else.
resource agentReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: secret
  name: guid(secret.id, agentPrincipalId, secretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsUserRoleId)
    principalId: agentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource projectReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: secret
  name: guid(secret.id, project.id, secretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsUserRoleId)
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

module pe 'private-endpoint.bicep' = {
  name: 'pe-${vaultName}'
  dependsOn: [ zone ]
  params: {
    location: location
    tags: tags
    name: 'pe-${vaultName}'
    subnetId: '${vnet.id}/subnets/${peSubnetName}'
    targetResourceId: vault.id
    groupId: 'vault'
    privateDnsZoneNames: [ zoneName ]
  }
}

output vaultUri string = vault.properties.vaultUri

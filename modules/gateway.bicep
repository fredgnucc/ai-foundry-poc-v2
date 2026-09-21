metadata description = 'API Management instance flagged as an AI Gateway.'

param location string
param tags object
param apimName string
param apimSku string
param publisherEmail string
param publisherName string

@description('''
Subnet for outbound VNet integration. Empty means no integration (Basic v2).
Standard v2 / Premium v2 only, and the subnet must be delegated to
Microsoft.Web/serverFarms with an NSG allowing outbound 443 to AzureKeyVault.
''')
param integrationSubnetId string = ''

@description('Inbound access to the gateway. Enabled is required at creation; Disabled is valid only as a later update, once the private endpoint exists, and then closes inbound to that endpoint only.')
@allowed([ 'Enabled', 'Disabled' ])
param publicNetworkAccess string = 'Enabled'

var useVnet = !empty(integrationSubnetId)

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: apimSku
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    // Marks the instance as an AI Gateway. Write-only: ARM accepts it but never
    // returns it on GET, so it cannot be asserted after deployment.
    #disable-next-line BCP037
    isAIGateway: true
    apiVersionConstraint: {
      minApiVersion: '2019-12-01'
    }
    // 'External' on a v2 tier means outbound integration: the gateway reaches
    // backends in the VNet while its own inbound endpoint stays public. Inbound
    // is made private separately, via a private endpoint.
    virtualNetworkType: useVnet ? 'External' : 'None'
    virtualNetworkConfiguration: useVnet ? {
      subnetResourceId: integrationSubnetId
    } : null
    publicNetworkAccess: publicNetworkAccess
  }
}

output apimId string = apim.id
output apimName string = apim.name
output principalId string = apim.identity.principalId

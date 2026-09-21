metadata description = 'One private endpoint plus its private DNS zone group.'

param location string
param tags object
param name string
param subnetId string

@description('Resource the endpoint fronts.')
param targetResourceId string

@description('Sub-resource to connect to, e.g. account, blob, sql, searchService, Gateway.')
param groupId string

@description('Private DNS zone names this endpoint registers in. Must already exist in this resource group.')
param privateDnsZoneNames array

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' existing = [for zone in privateDnsZoneNames: {
  name: zone
}]

resource pe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: name
        properties: {
          privateLinkServiceId: targetResourceId
          groupIds: [ groupId ]
        }
      }
    ]
  }
}

resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (zone, i) in privateDnsZoneNames: {
      name: replace(zone, '.', '-')
      properties: {
        privateDnsZoneId: zones[i].id
      }
    }]
  }
}

output privateEndpointId string = pe.id

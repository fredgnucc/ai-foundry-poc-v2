metadata description = '''
Virtual network for the private topology: one subnet per consumer, plus the
private DNS zones every private endpoint in this lab resolves through.

Three subnets, one per consumer. Names and delegations come from shared/naming.bicep
so they are defined in exactly one place.
'''

import { subnetNames, subnetDelegations, privateDnsZoneNames } from '../shared/naming.bicep'

param location string
param tags object
param vnetName string
param vnetAddressPrefix string
param apimSubnetPrefix string
param agentSubnetPrefix string
param peSubnetPrefix string
param jumpSubnetPrefix string

@description('Port sshd listens on. Moving it off 22 avoids tenant policy that strips internet-facing rules for 22.')
param sshPort int

@description('Source allowed to reach the SSH port. A single /32; "*" opens it to the internet.')
param allowedSshSource string

// Flattened from the shared per-service map: every zone is created once and
// linked to this VNet.
var privateDnsZones = union(
  privateDnsZoneNames.foundry,
  privateDnsZoneNames.storage,
  privateDnsZoneNames.cosmos,
  privateDnsZoneNames.search,
  privateDnsZoneNames.apim
)

// APIM requires an NSG on its integration subnet, and that NSG must allow
// outbound 443 to Key Vault - it is a hard service dependency, not optional.
resource apimNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${vnetName}-apim'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowKeyVaultOutbound'
        properties: {
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          priority: 100
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureKeyVault'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

// The agent subnet is Container Apps underneath, so it needs outbound Entra ID
// reachability or agent provisioning fails. Kept explicit rather than relying
// on the default AllowInternetOutbound, which a platform policy may remove.
resource agentNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${vnetName}-agent'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowEntraIdOutbound'
        properties: {
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          priority: 100
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureActiveDirectory'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

// A tenant policy requires every subnet to carry an NSG and silently creates an
// empty one if it is missing (vnet-<name>-snet-pe-nsg-<region>, tags copied from
// the VNet). Declaring it here stops the template and the policy from undoing
// each other on every redeploy. No rules: the defaults already permit
// intra-VNet traffic, which is all a private endpoint subnet needs.
resource peNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${vnetName}-pe'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

// The jump host is how you reach anything once public access is disabled: it
// terminates an SSH session and forwards TCP, so a browser on your laptop makes
// its connections from inside this VNet.
//
// Port is not 22 on purpose. A tenant Azure Policy silently deletes NSG rules
// allowing inbound 22 from the internet, minutes after deployment; the symptom
// is an SSH timeout on a healthy VM. Confirm with:
//   az network nic list-effective-nsg -g <rg> -n <vm>-nic-01
resource jumpNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${vnetName}-jump'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowSshInbound'
        properties: {
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          priority: 100
          sourceAddressPrefix: allowedSshSource
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: string(sshPort)
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ vnetAddressPrefix ]
    }
    subnets: [
      {
        name: subnetNames.apim
        properties: {
          addressPrefix: apimSubnetPrefix
          networkSecurityGroup: { id: apimNsg.id }
          delegations: [
            {
              name: 'apim-delegation'
              properties: { serviceName: subnetDelegations.apim }
            }
          ]
        }
      }
      {
        name: subnetNames.agent
        properties: {
          addressPrefix: agentSubnetPrefix
          networkSecurityGroup: { id: agentNsg.id }
          delegations: [
            {
              name: 'agent-delegation'
              properties: { serviceName: subnetDelegations.agent }
            }
          ]
        }
      }
      {
        name: subnetNames.privateEndpoints
        properties: {
          addressPrefix: peSubnetPrefix
          networkSecurityGroup: { id: peNsg.id }
        }
      }
      // Declared here rather than in the jump-host stage because subnets are
      // inline properties of this VNet: a subnet created by another deployment
      // would be silently removed the next time stage 1 runs.
      {
        name: subnetNames.jump
        properties: {
          addressPrefix: jumpSubnetPrefix
          networkSecurityGroup: { id: jumpNsg.id }
        }
      }
    ]
  }
}

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zone in privateDnsZones: {
  name: zone
  location: 'global'
  tags: tags
}]

resource zoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zone, i) in privateDnsZones: {
  parent: zones[i]
  name: 'link-${vnetName}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]

output vnetId string = vnet.id
output apimSubnetId string = '${vnet.id}/subnets/${subnetNames.apim}'
output agentSubnetId string = '${vnet.id}/subnets/${subnetNames.agent}'
output peSubnetId string = '${vnet.id}/subnets/${subnetNames.privateEndpoints}'
output jumpSubnetId string = '${vnet.id}/subnets/${subnetNames.jump}'
// Consumers resolve zones by name with an `existing` reference rather than
// receiving IDs: Bicep cannot index a resource collection from inside a lambda.
output privateDnsZoneNames array = privateDnsZones

metadata description = '''
Jump host: a small Linux VM whose only job is to terminate an SSH session and
forward TCP. With `ssh -D` it becomes a SOCKS proxy, so a browser on your own
laptop makes its connections from inside this VNet - keeping your existing Entra
session instead of signing in again inside an RDP session.

Bastion is deliberately not used. The Developer SKU is free but cannot tunnel;
tunnelling needs the Standard SKU, which is not.

The subnet and its NSG belong to modules/network.bicep, because subnets are
inline properties of the VNet: anything created here would be removed the next
time stage 1 ran.
'''

targetScope = 'resourceGroup'

param location string
param tags object

param subnetId string
param publicIpName string
param vmName string
param vmSize string
param adminUsername string

@description('SSH public key authorised for adminUsername. Password auth is not enabled.')
param sshPublicKey string

@description('Cloud-init document. Placeholders must already be substituted by the caller.')
param cloudInit string

// Besides inbound SSH, this is what gives the VM outbound internet. The subnet
// has no NAT gateway and default outbound access is retired for new deployments,
// so without an explicit public IP the proxied traffic would have nowhere to go.
// https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access
resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic-01'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig01'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 32
        caching: 'ReadWrite'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
      // Raw text, NOT base64. This is the native resource type, which expects
      // an already-encoded value - so it is encoded exactly once, here.
      //
      // cloud-init classifies user-data by matching the first line against
      // '#cloud-config'. Double-encoding, or a CRLF after that header, breaks
      // the match: the document is silently discarded, the VM boots with a
      // default sshd on port 22, and the deployment still reports Succeeded.
      // The tell is in /var/log/cloud-init.log:
      //   handlers[WARNING]: Unhandled non-multipart (text/x-not-multipart) userdata
      // Verify on the host with:
      //   head -c 40 /var/lib/cloud/instance/user-data.txt
      customData: base64(cloudInit)
    }
    networkProfile: {
      networkInterfaces: [
        { id: nic.id }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: { enabled: true }
    }
  }
}

output vmName string = vm.name
output vmId string = vm.id
output publicIpAddress string = pip.properties.ipAddress
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress

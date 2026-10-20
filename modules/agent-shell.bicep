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

@description('Jump host VM where the runCommand creates the user.')
param jumpVmName string

param sshUser string

@description('OpenSSH public key line of sshUser.')
param sshPublicKey string

@description('Only this CIDR may log in with the key (the agent subnet).')
param agentSubnetPrefix string

@description('PoC only: passwordless sudo for sshUser. False removes the sudoers file.')
param allowSudo bool

var zoneName = 'privatelink.vaultcore.azure.net'
var secretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var sudoersFile = '/etc/sudoers.d/90-${sshUser}'
var sudoLine = allowSudo
  ? 'echo \'${sshUser} ALL=(ALL) NOPASSWD:ALL\' > /tmp/sudo-${sshUser} && visudo -cf /tmp/sudo-${sshUser} && install -m 440 /tmp/sudo-${sshUser} ${sudoersFile} && rm /tmp/sudo-${sshUser}'
  : 'rm -f ${sudoersFile}'

resource jumpVm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: jumpVmName
}

// Runs as root through the VM agent: no SSH from the deployer. The public key
// changes on every enable-shell.py run, so the script changes and runs again.
// The last line prints the host key; enable-shell.py reads it from the instance
// view to pin it in the agent (Bicep cannot read the instance view).
resource userSetup 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: jumpVm
  name: '${sshUser}-setup'
  location: location
  tags: tags
  properties: {
    asyncExecution: false
    timeoutInSeconds: 300
    treatFailureAsDeploymentFailure: true
    source: {
      script: join([
        'set -e'
        'id ${sshUser} >/dev/null 2>&1 || useradd -m -s /bin/bash ${sshUser}'
        'install -d -m 700 -o ${sshUser} -g ${sshUser} /home/${sshUser}/.ssh'
        'echo \'from="${agentSubnetPrefix}",no-port-forwarding,no-agent-forwarding,no-X11-forwarding ${sshPublicKey}\' > /home/${sshUser}/.ssh/authorized_keys'
        'chown ${sshUser}: /home/${sshUser}/.ssh/authorized_keys'
        'chmod 600 /home/${sshUser}/.ssh/authorized_keys'
        sudoLine
        'echo "HOSTKEY $(cut -d" " -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)"'
      ], '\n')
    }
  }
}

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
output setupRunCommandId string = userSetup.id

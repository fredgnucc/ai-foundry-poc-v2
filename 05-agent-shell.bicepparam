using '05-agent-shell.bicep'

var lab = loadJsonContent('params/lab.json')

param location = lab.location
param tags = lab.tags
param resourceGroupName = lab.resourceGroupName
param namePrefix = lab.namePrefix
param nameSeed = lab.nameSeed
param projectName = lab.projectName
param sshPort = lab.sshPort
param agentSubnetPrefix = lab.agentSubnetPrefix

// Set by enable-shell.py in the bicep process environment only; never stored.
param agentPrincipalId = readEnvironmentVariable('AGENT_PRINCIPAL_ID')
param sshPrivateKey = readEnvironmentVariable('JUMP_SSH_PRIVATE_KEY')
param sshPublicKey = readEnvironmentVariable('JUMP_SSH_PUBLIC_KEY')
param allowSudo = bool(readEnvironmentVariable('JUMP_ALLOW_SUDO', 'false'))

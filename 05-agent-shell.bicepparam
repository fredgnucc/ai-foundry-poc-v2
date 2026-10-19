using '05-agent-shell.bicep'

var lab = loadJsonContent('params/lab.json')

param location = lab.location
param tags = lab.tags
param resourceGroupName = lab.resourceGroupName
param namePrefix = lab.namePrefix
param nameSeed = lab.nameSeed
param projectName = lab.projectName
param sshPort = lab.sshPort

// Set by the deploy command in README Step 5; never stored in the repo.
param agentPrincipalId = readEnvironmentVariable('AGENT_PRINCIPAL_ID')
param sshPrivateKey = readEnvironmentVariable('JUMP_SSH_PRIVATE_KEY')
param jumpHostKey = readEnvironmentVariable('JUMP_HOST_KEY')

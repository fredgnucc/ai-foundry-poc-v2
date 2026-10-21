using '07-teams.bicep'

var lab = loadJsonContent('params/lab.json')

param tags = lab.tags
param resourceGroupName = lab.resourceGroupName
param namePrefix = lab.namePrefix
param nameSeed = lab.nameSeed
param projectName = lab.projectName

// Set by publish-teams.py in the bicep process environment only.
param agentName = readEnvironmentVariable('TEAMS_AGENT_NAME')
param agentClientId = readEnvironmentVariable('TEAMS_AGENT_CLIENT_ID')
param displayName = readEnvironmentVariable('TEAMS_DISPLAY_NAME', readEnvironmentVariable('TEAMS_AGENT_NAME'))

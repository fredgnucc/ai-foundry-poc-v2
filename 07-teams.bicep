targetScope = 'subscription'

metadata description = '''
Step 7 (optional) - Azure Bot Service for publishing an agent to Teams and Microsoft 365 Copilot.

Additive: it does NOT modify steps 1-6. The bot forwards Teams/Copilot messages to the
agent's Activity Protocol endpoint. Run it through publish-teams.py: it reads the agent
identity, deploys this, opens only the Activity Protocol route to Microsoft 365
(enable_m365_public_endpoint) and calls the Microsoft 365 publish API.
'''

import { resourceSuffix, labNames } from './shared/naming.bicep'

param tags object
param resourceGroupName string
param namePrefix string
param nameSeed string
param projectName string

@description('Agent to publish.')
param agentName string

@description('instance_identity.client_id of the agent (read by publish-teams.py).')
param agentClientId string

@description('Name shown in Teams and Copilot.')
param displayName string = agentName

var suffix = resourceSuffix(subscription().id, resourceGroupName, namePrefix, nameSeed)
var names = labNames(namePrefix, suffix)
var endpoint = 'https://${names.account}.services.ai.azure.com/api/projects/${projectName}/agents/${agentName}/endpoint/protocols/activityProtocol'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: resourceGroupName
}

module bot 'modules/teams-bot.bicep' = {
  scope: rg
  name: 'teams-bot-${agentName}'
  params: {
    tags: tags
    // Bot names are global: 2-64 chars, letters, digits, '-', '_', '.'.
    botName: take('bot-${namePrefix}-${agentName}-${suffix}', 64)
    displayName: displayName
    msaAppId: agentClientId
    endpoint: endpoint
  }
}

output botId string = bot.outputs.botId
output activityEndpoint string = endpoint

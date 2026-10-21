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

@description('Same value the portal sets on the bots it creates. Without api-version Foundry rejects the call.')
param activityApiVersion string = '2025-11-15-preview'

var suffix = resourceSuffix(subscription().id, resourceGroupName, namePrefix, nameSeed)
var names = labNames(namePrefix, suffix)
var botName = 'bot-${namePrefix}-${agentName}-${suffix}'
var endpoint = 'https://${names.account}.services.ai.azure.com/api/projects/${projectName}/agents/${agentName}/endpoint/protocols/activityprotocol?api-version=${activityApiVersion}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: resourceGroupName
}

module bot 'modules/teams-bot.bicep' = {
  scope: rg
  name: 'teams-bot-${agentName}'
  params: {
    tags: tags
    // Azure Bot Service limits names to 42 characters. Preserve existing short names.
    botName: length(botName) <= 42 ? botName : '${take('bot-${namePrefix}-${agentName}', 28)}-${uniqueString(suffix, agentName)}'
    displayName: displayName
    msaAppId: agentClientId
    endpoint: endpoint
  }
}

output botId string = bot.outputs.botId
output activityEndpoint string = endpoint

metadata description = 'Azure Bot Service (Teams channel) in front of a Foundry agent Activity Protocol endpoint.'

param tags object
param botName string
param displayName string

@description('instance_identity.client_id of the agent.')
param msaAppId string
param endpoint string
param sku string = 'F0'

resource bot 'Microsoft.BotService/botServices@2022-09-15' = {
  name: botName
  kind: 'azurebot'
  location: 'global'
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    displayName: displayName
    endpoint: endpoint
    msaAppId: msaAppId
    msaAppTenantId: tenant().tenantId
    msaAppType: 'SingleTenant'
    publicNetworkAccess: 'Disabled'
  }
}

resource teams 'Microsoft.BotService/botServices/channels@2022-09-15' = {
  parent: bot
  name: 'MsTeamsChannel'
  location: 'global'
  properties: {
    channelName: 'MsTeamsChannel'
  }
}

output botId string = bot.id

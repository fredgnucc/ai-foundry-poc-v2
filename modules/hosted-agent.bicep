metadata description = '''
Foundry User for the project managed identity, scoped to the Foundry account.
Hosted agents need it for model inference through the project endpoint
(see "Hosted agent permissions reference" on Microsoft Learn).
'''

param accountName string
param projectName string

var foundryUser = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: account
  name: projectName
}

resource foundryUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, project.id, foundryUser)
  properties: {
    principalId: project.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUser)
    principalType: 'ServicePrincipal'
  }
}

output projectPrincipalId string = project.identity.principalId

metadata description = '''
An embedding model deployment added to the existing Foundry account.

Additive only: the account and its chat deployment from step 2 are referenced with
`existing` and are never modified. Foundry IQ needs an embedding model to vectorize
content for agentic retrieval; the chat model alone cannot.
'''

param accountName string
param embeddingModelName string
param embeddingModelVersion string
param embeddingModelCapacity int

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource embedding 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: account
  name: embeddingModelName
  sku: {
    name: 'GlobalStandard'
    capacity: embeddingModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingModelName
      version: embeddingModelVersion
    }
  }
}

output embeddingDeploymentName string = embedding.name

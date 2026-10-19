targetScope = 'subscription'

metadata description = '''
Step 4 (optional) - Foundry IQ knowledge test.

Isolated from the core three-step deploy and additive by design: it does NOT
redeploy or modify steps 1-3. It only adds an embedding model deployment to the
existing Foundry account (step 2), which Foundry IQ needs to vectorize content for
agentic retrieval.

Two more things complete the test but live outside this template:
  * the free semantic ranker on the AI Search service - a one-line, reversible
    control-plane toggle (see README), not redeployed here to avoid touching the
    step-3 Search definition, and
  * the knowledge source + knowledge base themselves - Azure AI Search data-plane
    objects, created with the portal wizard, then queried with foundry-iq-test.py.

References the account from step 2 with `existing`.
'''

import { resourceSuffix, labNames } from './shared/naming.bicep'

param resourceGroupName string
param namePrefix string
param nameSeed string

param embeddingModelName string
param embeddingModelVersion string
param embeddingModelCapacity int

var names = labNames(namePrefix, resourceSuffix(subscription().id, resourceGroupName, namePrefix, nameSeed))

module embedding 'modules/embedding.bicep' = {
  scope: resourceGroup(resourceGroupName)
  name: 'embedding'
  params: {
    accountName: names.account
    embeddingModelName: embeddingModelName
    embeddingModelVersion: embeddingModelVersion
    embeddingModelCapacity: embeddingModelCapacity
  }
}

output embeddingDeploymentName string = embedding.outputs.embeddingDeploymentName
output searchName string = names.search

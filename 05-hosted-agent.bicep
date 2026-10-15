targetScope = 'subscription'

metadata description = '''
Step 5 (optional) - Foundry hosted agent.

Additive like step 4: it does NOT redeploy or modify steps 1-3. It adds the one
thing a hosted agent needs that the lab doesn't have yet: the Foundry User role for
the project managed identity on the Foundry account. Hosted agents call models
through the project endpoint, and that call relies on the project identity's access.
A project created in the portal gets this role automatically; a Bicep-created
project does not.

The agent itself is a Foundry data-plane object, so Bicep cannot create it.
hosted-agent.py zips hosted-agent/, uploads it, waits for the build, and calls it.

No new networking: the account was created with networkInjections on the agent
subnet, and hosted agent sessions run there too.

References the account and project from step 2 with `existing`.
'''

import { resourceSuffix, labNames } from './shared/naming.bicep'

param resourceGroupName string
param namePrefix string
param nameSeed string
param projectName string

var names = labNames(namePrefix, resourceSuffix(subscription().id, resourceGroupName, namePrefix, nameSeed))

module hostedAgent 'modules/hosted-agent.bicep' = {
  scope: resourceGroup(resourceGroupName)
  name: 'hosted-agent'
  params: {
    accountName: names.account
    projectName: projectName
  }
}

output projectPrincipalId string = hostedAgent.outputs.projectPrincipalId

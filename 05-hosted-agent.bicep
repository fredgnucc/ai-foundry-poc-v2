targetScope = 'subscription'

metadata description = '''
Step 5 (optional) - Foundry hosted agent, routed through the AI gateway.

Additive like step 4: it does NOT redeploy or modify steps 1-3. It adds a second
API to the step-2 gateway for hosted agents: Microsoft Entra token in (no key),
the gateway's managed identity out, Responses API only.

The agent's code does the routing, not RBAC: a hosted agent's identity can always
call models through its own project endpoint (implicit access, no role needed), so
no role assignment here can block that path. main.py only knows AI_GATEWAY_URL.

The agent itself is a Foundry data-plane object, so Bicep cannot create it.
hosted-agent.py zips hosted-agent/, uploads it with this deployment's gatewayUrl
as AI_GATEWAY_URL, waits for the build, and calls it.

No new networking: hosted agent sessions run in the agent subnet (networkInjections)
and reach APIM through its private endpoint.

References the account and gateway from step 2 with `existing`.
'''

import { resourceSuffix, labNames } from './shared/naming.bicep'

param resourceGroupName string
param namePrefix string
param nameSeed string

var names = labNames(namePrefix, resourceSuffix(subscription().id, resourceGroupName, namePrefix, nameSeed))

module hostedAgent 'modules/hosted-agent.bicep' = {
  scope: resourceGroup(resourceGroupName)
  name: 'hosted-agent'
  params: {
    accountName: names.account
    apimName: names.apim
  }
}

output gatewayUrl string = hostedAgent.outputs.gatewayUrl

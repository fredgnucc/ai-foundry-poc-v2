metadata description = '''
Keyless gateway API for hosted agents. The caller sends a Microsoft Entra token
instead of a subscription key; APIM forwards Responses API calls to the step-2
backend, which signs them with the gateway's managed identity.
'''

param accountName string
param apimName string

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
}

// A second API next to the step-2 one (key auth, every path). Same backend, so the
// same managed identity and its Cognitive Services OpenAI User role.
var apiName = '${accountName}-entra'

resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: apiName
  properties: {
    displayName: apiName
    path: apiName
    protocols: [ 'https' ]
    // The Entra token replaces the subscription key, so no product either.
    subscriptionRequired: false
  }
}

// Responses API only. Any other path gets 404 from APIM.
resource responses 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'post-responses'
  properties: {
    displayName: 'post-responses'
    method: 'POST'
    urlTemplate: '/v1/responses'
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(replace(loadTextContent('policy-entra.xml'), '__TENANT__', tenant().tenantId), '__BACKEND__', accountName)
  }
  dependsOn: [ responses ]
}

output gatewayUrl string = '${apim.properties.gatewayUrl}/${apiName}/v1'

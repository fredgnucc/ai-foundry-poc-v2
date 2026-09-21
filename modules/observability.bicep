metadata description = '''
Gateway telemetry. This is not optional instrumentation in this lab, it is the
only instrument available.

Azure does not expose IP utilisation for delegated subnets ("The Azure portal
doesn't currently expose IP utilization for delegated subnets, so you can't
monitor it directly" - agents-networking-deep-dive), and the data proxy's NICs
are platform-managed and never appear in the resource group. So the gateway log
is the only place the agent's real source address is observable.

CallerIpAddress is the field that answers whether agent egress traverses the
VNet: a 10.20.1.x address means the traffic came from the data proxy in
snet-agent, anything public means it left Microsoft's network instead.

GatewayLlmLogs is enabled alongside GatewayLogs because it carries the model and
token detail that the token-limit policy acts on.
'''

param location string
param tags object
param workspaceName string
param apimName string
param diagnosticSettingName string

@description('Kept short deliberately - this is POC evidence, not retained telemetry.')
param retentionInDays int = 30

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

// Diagnostic settings are extension resources, so the scope is the APIM instance
// rather than the resource group.
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: diagnosticSettingName
  scope: apim
  properties: {
    workspaceId: workspace.id
    // Without this, logs land in the legacy shared AzureDiagnostics table, where
    // the column is CallerIPAddress and most fields arrive as typed suffixes
    // (responseCode_d, url_s). 'Dedicated' gives the documented
    // ApiManagementGatewayLogs schema with CallerIpAddress. Measured: the default
    // silently produced AzureDiagnostics rows and an empty
    // ApiManagementGatewayLogs table, which looks exactly like broken logging.
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'GatewayLogs'
        enabled: true
      }
      {
        category: 'GatewayLlmLogs'
        enabled: true
      }
    ]
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output customerId string = workspace.properties.customerId

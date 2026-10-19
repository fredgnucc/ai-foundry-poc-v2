metadata description = '''
Single source of truth for naming and network structure.

Every stage is an independent deployment, so nothing is passed between them: each
one re-derives identical names from the same four inputs. Those formulas live here
only, so renaming anything is a one-line change.

Values a user chooses (region, address space, model) belong in params/lab.json.
Values that are structural (subnet names, delegations) belong here.
'''

@export()
@description('''
Deterministic suffix shared by every resource in the lab. A hash of the four
inputs, so it is stable across the three deployment steps - each recomputes the
same value - and exists purely to avoid naming collisions: it makes the globally
unique names (Storage, APIM, Cosmos, the Foundry endpoint) unique, and keeps two
instances with a different resource group or seed from clashing.
''')
func resourceSuffix(subscriptionId string, resourceGroupName string, namePrefix string, nameSeed string) string =>
  uniqueString(subscriptionId, resourceGroupName, namePrefix, nameSeed)

@export()
@description('''
All resource names, derived from the prefix and suffix. Every name leads with a
resource-type token (CAF style) so a portal or CLI listing groups by type and each
resource is identifiable at a glance; the shared prefix and suffix follow.
''')
func labNames(namePrefix string, suffix string) object => {
  account: toLower('aif-${namePrefix}-${suffix}')
  // Model-only account used when separateModelAccount is true (step 2).
  modelAccount: toLower('aim-${namePrefix}-${suffix}')
  apim: toLower('apim-${namePrefix}-${suffix}')
  vnet: toLower('vnet-${namePrefix}-${suffix}')
  // Storage names are alphanumeric only and capped at 24 characters.
  storage: toLower('st${namePrefix}${suffix}')
  cosmos: toLower('cosmos-${namePrefix}-${suffix}')
  search: toLower('srch-${namePrefix}-${suffix}')
  jumpVm: toLower('vm-${namePrefix}-jump')
  jumpPip: toLower('pip-${namePrefix}-jump')
  logAnalytics: toLower('log-${namePrefix}-${suffix}')
}

@export()
@description('APIM product name, which the portal derives from the account and project.')
func productName(accountName string, projectName string) string =>
  toLower('${accountName}-${projectName}-ai')

@export()
@description('Subnet names. Structural, not user configuration.')
var subnetNames = {
  apim: 'snet-apim'
  agent: 'snet-agent'
  privateEndpoints: 'snet-pe'
  jump: 'snet-jump'
}

@export()
@description('''
Required subnet delegations. These are not interchangeable:
APIM Standard v2 outbound integration needs Microsoft.Web/serverFarms, while
Foundry agent compute needs Microsoft.App/environments. (Premium v2 injection
would need Microsoft.Web/hostingEnvironments instead - a different design.)
''')
var subnetDelegations = {
  apim: 'Microsoft.Web/serverFarms'
  agent: 'Microsoft.App/environments'
}

@export()
@description('Private DNS zones required for the private endpoints in this lab.')
var privateDnsZoneNames = {
  foundry: [
    'privatelink.services.ai.azure.com'
    'privatelink.openai.azure.com'
    'privatelink.cognitiveservices.azure.com'
  ]
  #disable-next-line no-hardcoded-env-urls
  storage: [ 'privatelink.blob.core.windows.net' ]
  cosmos: [ 'privatelink.documents.azure.com' ]
  search: [ 'privatelink.search.windows.net' ]
  apim: [ 'privatelink.azure-api.net' ]
}

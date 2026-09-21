using '03-runtime.bicep'

var lab = loadJsonContent('params/lab.json')

param location = lab.location
param resourceGroupName = lab.resourceGroupName
param namePrefix = lab.namePrefix
param nameSeed = lab.nameSeed
param tags = lab.tags

param searchSku = lab.searchSku
param projectName = lab.projectName
param capabilityHostName = lab.capabilityHostName

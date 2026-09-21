using '02-gateway.bicep'

var lab = loadJsonContent('params/lab.json')

param location = lab.location
param resourceGroupName = lab.resourceGroupName
param namePrefix = lab.namePrefix
param nameSeed = lab.nameSeed
param tags = lab.tags

param projectName = lab.projectName
param modelName = lab.modelName
param modelVersion = lab.modelVersion
param modelCapacity = lab.modelCapacity
param inferenceApiVersion = lab.inferenceApiVersion

param publisherEmail = lab.publisherEmail
param allowPublicGatewayAccess = lab.allowPublicGatewayAccess
param tokenLimitPerMinute = lab.tokenLimitPerMinute

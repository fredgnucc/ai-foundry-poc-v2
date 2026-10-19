using '04-hosted-agent.bicep'

var lab = loadJsonContent('params/lab.json')

param resourceGroupName = lab.resourceGroupName
param namePrefix = lab.namePrefix
param nameSeed = lab.nameSeed

using '06-foundry-iq.bicep'

var lab = loadJsonContent('params/lab.json')

param resourceGroupName = lab.resourceGroupName
param namePrefix = lab.namePrefix
param nameSeed = lab.nameSeed

param embeddingModelName = lab.embeddingModelName
param embeddingModelVersion = lab.embeddingModelVersion
param embeddingModelCapacity = lab.embeddingModelCapacity

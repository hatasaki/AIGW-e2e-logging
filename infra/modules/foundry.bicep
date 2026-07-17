// Azure AI Foundry (Cognitive Services AIServices) account + model deployment.
param location string
param tags object
param accountName string
param projectName string
param modelName string
param modelVersion string
param modelSkuName string
param modelCapacity int
@description('Optional user/principal object id granted Cognitive Services OpenAI User for local testing.')
param principalId string = ''

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // Custom subdomain is required for Entra ID (AAD) token auth and the OpenAI endpoint.
    customSubDomainName: accountName
    allowProjectManagement: true
    publicNetworkAccess: 'Enabled'
    // Force Entra ID auth only (APIM authenticates with its managed identity).
    disableLocalAuth: true
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: account
  name: projectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'AI Gateway hosted agents'
    description: 'Microsoft Foundry project for hosted agents behind API Management.'
  }
}

var modelDefinition = empty(modelVersion)
  ? { format: 'OpenAI', name: modelName }
  : { format: 'OpenAI', name: modelName, version: modelVersion }

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: modelName
  sku: {
    name: modelSkuName
    capacity: modelCapacity
  }
  properties: {
    model: modelDefinition
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
}

// Cognitive Services OpenAI User (data-plane) for the deploying user (local testing).
var openAiUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')

resource userOpenAiAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(account.id, principalId, openAiUserRoleId)
  scope: account
  properties: {
    principalId: principalId
    roleDefinitionId: openAiUserRoleId
    principalType: 'User'
  }
}

// The azd Foundry extension deploys Hosted Agent versions through the project data plane.
var foundryProjectManagerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'eadc314b-1a2d-4efa-be10-5d325db5065e')
resource deployerProjectManager 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(project.id, principalId, foundryProjectManagerRoleId)
  scope: project
  properties: {
    principalId: principalId
    roleDefinitionId: foundryProjectManagerRoleId
    principalType: 'User'
  }
}

output accountName string = account.name
output accountId string = account.id
output principalId string = account.identity.principalId
output openAiEndpoint string = 'https://${accountName}.openai.azure.com'
output modelDeploymentName string = deployment.name
output projectName string = project.name
output projectId string = project.id
output projectEndpoint string = 'https://${accountName}.services.ai.azure.com/api/projects/${project.name}'
output projectPrincipalId string = project.identity.principalId

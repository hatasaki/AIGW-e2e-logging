param foundryAccountName string
param foundryProjectName string
param principalId string

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryAccountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: account
  name: foundryProjectName
}

// Foundry Agent Consumer: least-privilege access to invoke Hosted Agent endpoints.
var foundryAgentConsumerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'eed3b665-ab3a-47b6-8f48-c9382fb1dad6')

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(project.id, principalId, foundryAgentConsumerRoleId)
  scope: project
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: foundryAgentConsumerRoleId
  }
}

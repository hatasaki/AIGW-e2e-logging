// Grants the APIM managed identity data-plane access to Foundry (Model GW -> Foundry via MI).
param foundryAccountName string
param apimPrincipalId string

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryAccountName
}

var openAiUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')

resource apimOpenAiAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, apimPrincipalId, openAiUserRoleId)
  scope: account
  properties: {
    principalId: apimPrincipalId
    roleDefinitionId: openAiUserRoleId
    principalType: 'ServicePrincipal'
  }
}

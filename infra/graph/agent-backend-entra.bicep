// Entra application that represents the private Agent backend API.
// APIM requests an app-only token for this audience with its managed identity. Container Apps
// Easy Auth validates the token and permits only the dedicated APIM UAMI client ID.
extension microsoftGraphV1

param displayName string
@description('Stable Microsoft Graph alternate key. Must not change when the Application ID URI changes.')
param uniqueName string
@description('Application ID URI used as the APIM-to-Agent token audience.')
param identifierUri string
@description('Object ID of the APIM caller managed identity that receives the Agent.Invoke app role.')
param callerPrincipalId string
@description('Stable ID of the Agent.Invoke app role. Must not change when the audience URI changes.')
param invokeRoleId string

resource app 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: uniqueName
  displayName: displayName
  signInAudience: 'AzureADMyOrg'
  identifierUris: [ identifierUri ]
  api: {
    // Easy Auth daemon authorization uses the v1 `appid` caller claim for allowedApplications.
    requestedAccessTokenVersion: 1
  }
  appRoles: [
    {
      id: invokeRoleId
      value: 'Agent.Invoke'
      displayName: 'Invoke Agent backend'
      description: 'Allows API Management to invoke the protected Agent backends.'
      allowedMemberTypes: [ 'Application' ]
      isEnabled: true
    }
  ]
}

resource servicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: app.appId
  // Prevents Entra from issuing role-less app-only tokens to unassigned callers.
  appRoleAssignmentRequired: true
}

// Grant the application role only to the UAMI used by APIM for Agent backend calls.
resource callerRoleAssignment 'Microsoft.Graph/appRoleAssignedTo@v1.0' = {
  principalId: callerPrincipalId
  resourceId: servicePrincipal.id
  appRoleId: invokeRoleId
}

output clientId string = app.appId
output objectId string = app.id
output servicePrincipalObjectId string = servicePrincipal.id
output identifierUri string = identifierUri
output invokeRoleId string = invokeRoleId

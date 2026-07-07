// Entra ID app registration for the frontend/BFF (Microsoft Graph Bicep extension).
// The app is both the Easy Auth client and the API whose scope the BFF forwards to APIM.
extension microsoftGraphV1

param displayName string
param redirectUri string
@description('App ID URI used as the token audience, e.g. api://aigw-<token>.')
param identifierUri string
param scopeName string = 'user_impersonation'

var scopeId = guid(identifierUri, scopeName)

resource app 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: 'aigw-${uniqueString(identifierUri)}'
  displayName: displayName
  signInAudience: 'AzureADMyOrg'
  identifierUris: [ identifierUri ]
  web: {
    redirectUris: [ redirectUri ]
    implicitGrantSettings: {
      // App Service Easy Auth uses the hybrid flow (response_type=code id_token), so the
      // app must be allowed to issue ID tokens. Without this the /.auth callback returns 401.
      enableIdTokenIssuance: true
      enableAccessTokenIssuance: false
    }
  }
  api: {
    requestedAccessTokenVersion: 2
    oauth2PermissionScopes: [
      {
        id: scopeId
        value: scopeName
        type: 'User'
        isEnabled: true
        adminConsentDisplayName: 'Access the AI gateway as the signed-in user'
        adminConsentDescription: 'Allows the app to call the AI gateway (APIM Agent GW) on behalf of the signed-in user.'
        userConsentDisplayName: 'Access the AI gateway on your behalf'
        userConsentDescription: 'Allows the app to call the AI gateway on your behalf.'
      }
    ]
  }
  requiredResourceAccess: [
    {
      resourceAppId: '00000003-0000-0000-c000-000000000000' // Microsoft Graph
      resourceAccess: [
        {
          id: 'e1fe6dd8-ba31-4d61-89e7-88639da4683d' // User.Read (delegated)
          type: 'Scope'
        }
      ]
    }
  ]
}

resource servicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: app.appId
}

output clientId string = app.appId
output objectId string = app.id
output identifierUri string = identifierUri

// =====================================================================================
// resources.bicep - resource group scoped orchestration of the whole platform.
// =====================================================================================

@description('Primary Azure region.')
param location string
@description('Region for the frontend App Service (may differ from primary for quota reasons).')
param webLocation string
param tags object
param abbrs object
param resourceToken string
param principalId string

param modelName string
param modelVersion string
param modelSkuName string
param modelCapacity int

param apimSkuName string
param apimCapacity int
param apimPublisherEmail string
param apimPublisherName string

param appServicePlanSkuName string
param appServicePlanSkuTier string

param learnMcpUrl string
param updatesMcpUrl string
param deepWikiMcpUrl string

param createAuthApp bool
param authClientId string

@description('Whether the expert agent container app already exists (set by azd).')
param agentExpertExists bool = false
@description('Whether the updates agent container app already exists (set by azd).')
param agentUpdatesExists bool = false

// ---- Deterministic resource names (so auth + app service can cross-reference) ----
var webAppName = '${abbrs.appServiceWebApp}${resourceToken}'
var webAppHostName = '${webAppName}.azurewebsites.net'
var webRedirectUri = 'https://${webAppHostName}/.auth/login/aad/callback'
var agentExpertAppName = '${abbrs.containerApp}expert-${resourceToken}'
var agentUpdatesAppName = '${abbrs.containerApp}updates-${resourceToken}'

// App setting name that will hold the Easy Auth client secret (populated by postprovision hook).
var authClientSecretSettingName = 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'

// Deterministic App ID URI used as the token audience across Easy Auth, the app registration
// and the Agent GW validate-jwt policy.
var apiIdentifierUri = createAuthApp ? 'api://aigw-${resourceToken}' : (empty(authClientId) ? 'api://aigw-${resourceToken}' : 'api://${authClientId}')

// Dedicated audience for APIM -> Agent service-to-service authentication.
var agentBackendIdentifierUri = 'api://${tenant().tenantId}/aigw-agent-backend-${resourceToken}'
// Preserve the Graph alternate key originally derived from the pre-v1 readable URI. The key
// identifies the app resource and must remain stable when its identifier URI/token version changes.
var originalAgentBackendIdentifierUri = 'api://aigw-agent-backend-${resourceToken}'
var agentBackendUniqueName = 'aigw-agent-backend-${uniqueString(originalAgentBackendIdentifierUri)}'
var agentBackendInvokeRoleId = guid(originalAgentBackendIdentifierUri, 'Agent.Invoke')

// Header used to carry the user's oid through every gateway hop.
var oidHeaderName = 'x-client-user-oid'

// ---- Agent backend Entra app (APIM managed identity audience) ----
module agentBackendEntra 'graph/agent-backend-entra.bicep' = {
  name: 'agent-backend-entra-app'
  params: {
    displayName: 'aigw-agent-backend (${resourceToken})'
    uniqueName: agentBackendUniqueName
    identifierUri: agentBackendIdentifierUri
    callerPrincipalId: agentBackendCallerIdentity.outputs.principalId
    invokeRoleId: agentBackendInvokeRoleId
  }
}

var agentBackendAuthClientId = agentBackendEntra.outputs.clientId

// ---- Monitoring ----
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    tags: tags
    logAnalyticsName: '${abbrs.logAnalyticsWorkspace}${resourceToken}'
    applicationInsightsName: '${abbrs.applicationInsights}${resourceToken}'
  }
}

// ---- User-assigned identity shared by the apps (ACR pull) ----
module appIdentity 'modules/identity.bicep' = {
  name: 'app-identity'
  params: {
    location: location
    tags: tags
    name: '${abbrs.managedIdentityUserAssigned}apps-${resourceToken}'
  }
}

// Dedicated caller identity for APIM -> Agent authentication. Keeping this separate from the
// APIM system identity narrows the token's purpose and exposes stable client/principal IDs for
// Easy Auth application + principal allowlists.
module agentBackendCallerIdentity 'modules/identity.bicep' = {
  name: 'agent-backend-caller-identity'
  params: {
    location: location
    tags: tags
    name: '${abbrs.managedIdentityUserAssigned}apim-agent-auth-${resourceToken}'
  }
}

// ---- Container registry ----
module registry 'modules/registry.bicep' = {
  name: 'registry'
  params: {
    location: location
    tags: tags
    name: '${abbrs.containerRegistry}${resourceToken}'
    pullPrincipalId: appIdentity.outputs.principalId
  }
}

// ---- Foundry (Azure OpenAI / AIServices) + model deployment ----
module foundry 'modules/foundry.bicep' = {
  name: 'foundry'
  params: {
    location: location
    tags: tags
    accountName: '${abbrs.cognitiveServicesFoundry}${resourceToken}'
    projectName: 'proj-${resourceToken}'
    modelName: modelName
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    modelCapacity: modelCapacity
    principalId: principalId
  }
}

// ---- API Management service + App Insights logger + diagnostics + agent subscription ----
module apim 'modules/apim.bicep' = {
  name: 'apim'
  params: {
    location: location
    tags: tags
    serviceName: '${abbrs.apiManagementService}${resourceToken}'
    skuName: apimSkuName
    skuCapacity: apimCapacity
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    appInsightsName: monitoring.outputs.applicationInsightsName
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    oidHeaderName: oidHeaderName
    agentBackendCallerIdentityId: agentBackendCallerIdentity.outputs.resourceId
  }
}

// ---- Model GW (Responses/Chat to Foundry, token metric + oid) ----
module modelGw 'modules/apim-model-gw.bicep' = {
  name: 'apim-model-gw'
  params: {
    apimName: apim.outputs.name
    apiPath: 'model'
    foundryOpenAiEndpoint: foundry.outputs.openAiEndpoint
    appInsightsLoggerId: apim.outputs.appInsightsLoggerId
    oidHeaderName: oidHeaderName
  }
}

// ---- APIM managed identity -> Foundry data-plane access ----
module foundryAccess 'modules/foundry-role.bicep' = {
  name: 'foundry-access'
  params: {
    foundryAccountName: foundry.outputs.accountName
    apimPrincipalId: apim.outputs.identityPrincipalId
  }
}

// APIM invokes the Hosted Agent endpoint with its system identity.
module hostedAgentConsumerAccess 'modules/foundry-agent-consumer-role.bicep' = {
  name: 'hosted-agent-consumer-access'
  params: {
    foundryAccountName: foundry.outputs.accountName
    foundryProjectName: foundry.outputs.projectName
    principalId: apim.outputs.identityPrincipalId
  }
}

// ---- MCP GW (Learn, Release communications, and DeepWiki HTTP APIs with oid trace) ----
module mcpGw 'modules/apim-mcp-gw.bicep' = {
  name: 'apim-mcp-gw'
  params: {
    apimName: apim.outputs.name
    appInsightsLoggerId: apim.outputs.appInsightsLoggerId
    oidHeaderName: oidHeaderName
    learnMcp: {
      path: 'mcp-learn'
      displayName: 'MCP GW - Microsoft Learn'
      backendUrl: learnMcpUrl
    }
    updatesMcp: {
      path: 'mcp-updates'
      displayName: 'MCP GW - Release communications'
      backendUrl: updatesMcpUrl
    }
    deepWikiMcp: {
      path: 'mcp-deepwiki'
      displayName: 'MCP GW - DeepWiki'
      backendUrl: deepWikiMcpUrl
    }
  }
}

// ---- Container Apps environment + two agents ----
// Preserve the azd-deployed agent images across re-provisions (avoids reverting to the placeholder).
module fetchExpertImage 'modules/fetch-container-image.bicep' = {
  name: 'fetch-expert-image'
  params: {
    exists: agentExpertExists
    name: agentExpertAppName
  }
}
module fetchUpdatesImage 'modules/fetch-container-image.bicep' = {
  name: 'fetch-updates-image'
  params: {
    exists: agentUpdatesExists
    name: agentUpdatesAppName
  }
}

module containerApps 'modules/containerapps.bicep' = {
  name: 'container-apps'
  params: {
    location: location
    tags: tags
    environmentName: '${abbrs.containerAppsEnvironment}${resourceToken}'
    identityId: appIdentity.outputs.resourceId
    identityClientId: appIdentity.outputs.clientId
    registryLoginServer: registry.outputs.loginServer
    logAnalyticsCustomerId: monitoring.outputs.logAnalyticsCustomerId
    logAnalyticsSharedKey: monitoring.outputs.logAnalyticsSharedKey
    appInsightsConnectionString: monitoring.outputs.applicationInsightsConnectionString
    apimName: apim.outputs.name
    apimSubscriptionName: apim.outputs.agentSubscriptionName
    modelGwBaseUrl: '${apim.outputs.gatewayUrl}/model/openai/v1'
    modelDeploymentName: foundry.outputs.modelDeploymentName
    mcpLearnUrl: '${apim.outputs.gatewayUrl}/mcp-learn'
    mcpUpdatesUrl: '${apim.outputs.gatewayUrl}/mcp-updates'
    oidHeaderName: oidHeaderName
    tenantId: tenant().tenantId
    agentBackendAuthClientId: agentBackendAuthClientId
    agentBackendAuthAudience: agentBackendIdentifierUri
    agentBackendCallerClientId: agentBackendCallerIdentity.outputs.clientId
    expertImage: fetchExpertImage.outputs.image
    updatesImage: fetchUpdatesImage.outputs.image
    expertApp: {
      name: agentExpertAppName
      serviceTag: 'agent-expert'
      agentName: 'azure-expert'
      instructions: 'You are an Azure expert. Use the Microsoft Learn MCP tools to ground every answer in official documentation. Cite the docs you used.'
    }
    updatesApp: {
      name: agentUpdatesAppName
      serviceTag: 'agent-updates'
      agentName: 'azure-updates'
      instructions: 'You are an Azure updates specialist. Use the Release communications MCP tools to report the latest Azure service updates, retirements and roadmap items. Be concise and include dates.'
    }
  }
}

// ---- Agent GW (validate-jwt -> oid, forwards to container apps) ----
module agentGw 'modules/apim-agent-gw.bicep' = {
  name: 'apim-agent-gw'
  params: {
    apimName: apim.outputs.name
    appInsightsLoggerId: apim.outputs.appInsightsLoggerId
    tenantId: tenant().tenantId
    audienceUri: apiIdentifierUri
    audienceAppId: createAuthApp ? entra!.outputs.clientId : authClientId
    agentBackendAudience: agentBackendIdentifierUri
    agentBackendCallerClientId: agentBackendCallerIdentity.outputs.clientId
    oidHeaderName: oidHeaderName
    expertApi: {
      path: 'agents/expert'
      displayName: 'Agent GW - Azure expert'
      backendUrl: 'https://${containerApps.outputs.expertFqdn}'
    }
    updatesApi: {
      path: 'agents/updates'
      displayName: 'Agent GW - Azure updates'
      backendUrl: 'https://${containerApps.outputs.updatesFqdn}'
    }
    deepWikiApi: {
      path: 'agents/deepwiki'
      displayName: 'Agent GW - DeepWiki (Foundry Hosted)'
      backendUrl: '${foundry.outputs.projectEndpoint}/agents/deepwiki-agent/endpoint/protocols/openai'
    }
  }
}

// ---- Entra app registration (Microsoft Graph Bicep extension) ----
module entra 'graph/entra.bicep' = if (createAuthApp) {
  name: 'entra-app'
  params: {
    displayName: 'aigw-e2e-logging (${resourceToken})'
    redirectUri: webRedirectUri
    identifierUri: apiIdentifierUri
  }
}

// ---- Frontend App Service (Flask BFF + UI) with Easy Auth ----
module web 'modules/appservice.bicep' = {
  name: 'web'
  params: {
    location: webLocation
    tags: tags
    planName: '${abbrs.appServicePlan}${resourceToken}'
    planSkuName: appServicePlanSkuName
    planSkuTier: appServicePlanSkuTier
    siteName: webAppName
    serviceTag: 'web'
    identityId: appIdentity.outputs.resourceId
    appInsightsConnectionString: monitoring.outputs.applicationInsightsConnectionString
    authClientId: createAuthApp ? entra!.outputs.clientId : authClientId
    authClientCredentialSettingName: authClientSecretSettingName
    apiIdentifierUri: apiIdentifierUri
    tenantId: tenant().tenantId
    agentGwExpertBaseUrl: '${apim.outputs.gatewayUrl}/agents/expert/openai/v1'
    agentGwUpdatesBaseUrl: '${apim.outputs.gatewayUrl}/agents/updates/openai/v1'
    agentGwDeepWikiBaseUrl: '${apim.outputs.gatewayUrl}/agents/deepwiki/openai/v1'
    oidHeaderName: oidHeaderName
  }
}

// ---- Outputs ----
output containerRegistryLoginServer string = registry.outputs.loginServer
output containerRegistryName string = registry.outputs.name

output appInsightsConnectionString string = monitoring.outputs.applicationInsightsConnectionString
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId

output apimGatewayUrl string = apim.outputs.gatewayUrl
output apimName string = apim.outputs.name
output agentGwExpertUrl string = '${apim.outputs.gatewayUrl}/agents/expert'
output agentGwUpdatesUrl string = '${apim.outputs.gatewayUrl}/agents/updates'
output agentGwDeepWikiUrl string = '${apim.outputs.gatewayUrl}/agents/deepwiki'
output modelGwUrl string = '${apim.outputs.gatewayUrl}/model'
output mcpGwLearnUrl string = '${apim.outputs.gatewayUrl}/mcp-learn'
output mcpGwUpdatesUrl string = '${apim.outputs.gatewayUrl}/mcp-updates'
output mcpGwDeepWikiUrl string = '${apim.outputs.gatewayUrl}/mcp-deepwiki'

output foundryProjectEndpoint string = foundry.outputs.projectEndpoint
output foundryProjectId string = foundry.outputs.projectId

output webAppName string = webAppName
output webAppUri string = 'https://${webAppHostName}'
output agentExpertAppName string = agentExpertAppName
output agentUpdatesAppName string = agentUpdatesAppName

output authClientId string = createAuthApp ? entra!.outputs.clientId : authClientId
output authAppObjectId string = createAuthApp ? entra!.outputs.objectId : ''
output agentBackendAuthClientId string = agentBackendAuthClientId
output agentBackendAuthAudience string = agentBackendIdentifierUri
output agentBackendCallerClientId string = agentBackendCallerIdentity.outputs.clientId
output agentBackendCallerPrincipalId string = agentBackendCallerIdentity.outputs.principalId
output authClientSecretSettingName string = authClientSecretSettingName
output modelDeploymentName string = foundry.outputs.modelDeploymentName

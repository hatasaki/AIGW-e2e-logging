// =====================================================================================
// aigw-e2e-logging - main entrypoint (subscription scope)
// Deploys an end-to-end AI gateway topology that propagates the authenticated user's
// Entra `oid` across API Management Agent GW, Model GW and MCP GW for per-user
// log search and token accounting.
// =====================================================================================
targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment. Used to derive resource names and the resource group.')
param environmentName string

@minLength(1)
@description('Primary Azure region for all resources (e.g. eastus2).')
param location string

@description('Region for the frontend App Service. Defaults to the primary location; override when the primary region lacks App Service (serverFarms) quota.')
param webLocation string = ''

@description('Object id of the principal running the deployment (azd sets AZURE_PRINCIPAL_ID). Granted data-plane access to Foundry for local testing.')
param principalId string = ''

// ---- Foundry model ----
@description('Foundry (Azure OpenAI) model name to deploy behind the Model GW.')
param modelName string = 'gpt-5.4-mini'

@description('Model version. Leave empty to let Azure pick the default version for the model.')
param modelVersion string = ''

@description('Model deployment SKU (throughput) name.')
param modelSkuName string = 'GlobalStandard'

@description('Model deployment capacity (thousands of TPM units, provider dependent).')
param modelCapacity int = 50

// ---- API Management ----
@description('API Management SKU. StandardV2 supports MCP servers, token metrics and LLM logging.')
param apimSkuName string = 'StandardV2'

@description('API Management capacity units.')
param apimCapacity int = 1

@description('APIM publisher email (required by the service).')
param apimPublisherEmail string = 'admin@contoso.com'

@description('APIM publisher organization name.')
param apimPublisherName string = 'Contoso AI Platform'

// ---- App Service plan ----
@description('App Service plan SKU name. Default F1 (Free) avoids dedicated-VM quota.')
param appServicePlanSkuName string = 'F1'

@description('App Service plan SKU tier. Default Free.')
param appServicePlanSkuTier string = 'Free'

// ---- MCP backends (public, streamable HTTP) ----
@description('Backend MCP server for the Azure expert agent.')
param learnMcpUrl string = 'https://learn.microsoft.com/api/mcp'

@description('Backend MCP server for the Azure updates agent.')
param updatesMcpUrl string = 'https://www.microsoft.com/releasecommunications/mcp'

// ---- Entra ID app registration ----
@description('When true, creates the Entra app registration for the frontend/BFF via the Microsoft Graph Bicep extension.')
param createAuthApp bool = true

@description('Existing app (client) id to use when createAuthApp = false.')
param authClientId string = ''

@description('Set by azd: whether the expert agent container app already exists.')
param agentExpertExists bool = false
@description('Set by azd: whether the updates agent container app already exists.')
param agentUpdatesExists bool = false

@description('Optional extra resource tags.')
param tags object = {}

var abbrs = loadJsonContent('abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tagsAll = union({ 'azd-env-name': environmentName }, tags)

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: '${abbrs.resourceGroup}${environmentName}'
  location: location
  tags: tagsAll
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    webLocation: empty(webLocation) ? location : webLocation
    tags: tagsAll
    abbrs: abbrs
    resourceToken: resourceToken
    principalId: principalId
    modelName: modelName
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    modelCapacity: modelCapacity
    apimSkuName: apimSkuName
    apimCapacity: apimCapacity
    apimPublisherEmail: apimPublisherEmail
    apimPublisherName: apimPublisherName
    appServicePlanSkuName: appServicePlanSkuName
    appServicePlanSkuTier: appServicePlanSkuTier
    learnMcpUrl: learnMcpUrl
    updatesMcpUrl: updatesMcpUrl
    createAuthApp: createAuthApp
    authClientId: authClientId
    agentExpertExists: agentExpertExists
    agentUpdatesExists: agentUpdatesExists
  }
}

// ---- Outputs consumed by azd, hooks and the app runtime ----
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_RESOURCE_GROUP string = rg.name

output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.containerRegistryLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = resources.outputs.containerRegistryName

output APPLICATIONINSIGHTS_CONNECTION_STRING string = resources.outputs.appInsightsConnectionString
output LOG_ANALYTICS_WORKSPACE_ID string = resources.outputs.logAnalyticsWorkspaceId

// APIM gateway URLs
output APIM_GATEWAY_URL string = resources.outputs.apimGatewayUrl
output AGENT_GW_EXPERT_URL string = resources.outputs.agentGwExpertUrl
output AGENT_GW_UPDATES_URL string = resources.outputs.agentGwUpdatesUrl
output MODEL_GW_URL string = resources.outputs.modelGwUrl
output MCP_GW_LEARN_URL string = resources.outputs.mcpGwLearnUrl
output MCP_GW_UPDATES_URL string = resources.outputs.mcpGwUpdatesUrl

// Service resource names (used by hooks)
output SERVICE_WEB_NAME string = resources.outputs.webAppName
output SERVICE_WEB_URI string = resources.outputs.webAppUri
output SERVICE_AGENT_EXPERT_NAME string = resources.outputs.agentExpertAppName
output SERVICE_AGENT_UPDATES_NAME string = resources.outputs.agentUpdatesAppName

// Entra / auth
output AUTH_CLIENT_ID string = resources.outputs.authClientId
output AUTH_APP_OBJECT_ID string = resources.outputs.authAppObjectId
output AUTH_CLIENT_SECRET_SETTING_NAME string = resources.outputs.authClientSecretSettingName
output MODEL_DEPLOYMENT_NAME string = resources.outputs.modelDeploymentName

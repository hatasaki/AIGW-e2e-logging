// Container Apps environment + two Microsoft Agent Framework agents (single image, env-driven).
param location string
param tags object
param environmentName string
param identityId string
param identityClientId string
param registryLoginServer string
param logAnalyticsCustomerId string
@secure()
param logAnalyticsSharedKey string
param appInsightsConnectionString string

param apimName string
param apimSubscriptionName string
param modelGwBaseUrl string
param modelDeploymentName string
param mcpLearnUrl string
param mcpUpdatesUrl string
param oidHeaderName string

@description('{ name, serviceTag, agentName, instructions } for the Azure expert agent.')
param expertApp object

@description('{ name, serviceTag, agentName, instructions } for the Azure updates agent.')
param updatesApp object

@description('Currently deployed expert image (from a prior azd deploy); empty on first provision.')
param expertImage string = ''

@description('Currently deployed updates image (from a prior azd deploy); empty on first provision.')
param updatesImage string = ''

// Placeholder image; used only on first provision before azd deploy builds the real image.
var placeholderImage = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
var targetPort = 8000

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
}
resource apimSub 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' existing = {
  parent: apimService
  name: apimSubscriptionName
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
  }
}

var apps = [
  union(expertApp, { mcpUrl: mcpLearnUrl, image: empty(expertImage) ? placeholderImage : expertImage })
  union(updatesApp, { mcpUrl: mcpUpdatesUrl, image: empty(updatesImage) ? placeholderImage : updatesImage })
]

resource containerApps 'Microsoft.App/containerApps@2024-03-01' = [
  for a in apps: {
    name: a.name
    location: location
    tags: union(tags, { 'azd-service-name': a.serviceTag })
    identity: {
      type: 'UserAssigned'
      userAssignedIdentities: {
        '${identityId}': {}
      }
    }
    properties: {
      managedEnvironmentId: env.id
      configuration: {
        activeRevisionsMode: 'Single'
        ingress: {
          external: true
          targetPort: targetPort
          transport: 'auto'
          allowInsecure: false
        }
        registries: [
          {
            server: registryLoginServer
            identity: identityId
          }
        ]
        secrets: [
          {
            name: 'apim-subscription-key'
            value: apimSub.listSecrets().primaryKey
          }
        ]
      }
      template: {
        containers: [
          {
            name: 'agent'
            image: a.image
            resources: {
              cpu: json('0.5')
              memory: '1Gi'
            }
            env: [
              { name: 'PORT', value: string(targetPort) }
              { name: 'AGENT_NAME', value: a.agentName }
              { name: 'AGENT_INSTRUCTIONS', value: a.instructions }
              { name: 'MODEL_GW_BASE_URL', value: modelGwBaseUrl }
              { name: 'MODEL_DEPLOYMENT_NAME', value: modelDeploymentName }
              { name: 'MCP_SERVER_URL', value: a.mcpUrl }
              { name: 'OID_HEADER_NAME', value: oidHeaderName }
              { name: 'APIM_SUBSCRIPTION_KEY', secretRef: 'apim-subscription-key' }
              { name: 'AZURE_CLIENT_ID', value: identityClientId }
              { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
            ]
          }
        ]
        scale: {
          minReplicas: 1
          maxReplicas: 3
        }
      }
    }
  }
]

output expertFqdn string = containerApps[0].properties.configuration.ingress.fqdn
output updatesFqdn string = containerApps[1].properties.configuration.ingress.fqdn
output expertAppName string = containerApps[0].name
output updatesAppName string = containerApps[1].name

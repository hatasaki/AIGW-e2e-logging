// Agent GW: Responses endpoints that validate the user token, derive oid, and route to either
// Container Apps agents or the Foundry Hosted DeepWiki agent.
param apimName string
param appInsightsLoggerId string
param tenantId string
@description('App ID URI used as the primary accepted token audience.')
param audienceUri string
@description('App (client) id also accepted as an audience.')
param audienceAppId string
@description('Application ID URI of the Agent backend API. APIM obtains a managed-identity token for this audience.')
param agentBackendAudience string
@description('Client ID of the user-assigned identity APIM uses to call the Agent backends.')
param agentBackendCallerClientId string
param oidHeaderName string

@description('{ path, displayName, backendUrl } for the expert agent API.')
param expertApi object

@description('{ path, displayName, backendUrl } for the updates agent API.')
param updatesApi object

@description('{ path, displayName, backendUrl } for the Foundry Hosted DeepWiki agent API.')
param deepWikiApi object

var openIdConfigUrl = '${environment().authentication.loginEndpoint}${tenantId}/v2.0/.well-known/openid-configuration'
var containerPolicyXml = replace(replace(replace(replace(replace(loadTextContent('../policies/agent-gw.xml'), '__OPENID_CONFIG_URL__', openIdConfigUrl), '__AUDIENCE_URI__', audienceUri), '__AUDIENCE_APPID__', audienceAppId), '__AGENT_BACKEND_AUDIENCE__', agentBackendAudience), '__AGENT_BACKEND_CALLER_CLIENT_ID__', agentBackendCallerClientId)
var hostedPolicyXml = replace(replace(replace(loadTextContent('../policies/agent-hosted-gw.xml'), '__OPENID_CONFIG_URL__', openIdConfigUrl), '__AUDIENCE_URI__', audienceUri), '__AUDIENCE_APPID__', audienceAppId)

var apis = [
  union(expertApi, { name: 'agent-gw-expert', policy: containerPolicyXml })
  union(updatesApi, { name: 'agent-gw-updates', policy: containerPolicyXml })
  union(deepWikiApi, { name: 'agent-gw-deepwiki', policy: hostedPolicyXml })
]

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
}

resource agentApis 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = [
  for a in apis: {
    parent: apimService
    name: a.name
    properties: {
      displayName: a.displayName
      description: 'User-authenticated agent endpoint (Responses API). Validates the user token and forwards oid.'
      path: a.path
      protocols: [ 'https' ]
      serviceUrl: a.backendUrl
      // JWT validation (not a subscription) protects this API.
      subscriptionRequired: false
      type: 'http'
    }
  }
]

resource agentOps 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = [
  for (a, i) in apis: {
    parent: agentApis[i]
    name: 'create-response'
    properties: {
      displayName: 'Create response'
      method: 'POST'
      urlTemplate: '/openai/v1/responses'
      templateParameters: []
      responses: []
    }
  }
]

resource agentPolicies 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = [
  for (a, i) in apis: {
    parent: agentApis[i]
    name: 'policy'
    properties: {
      format: 'rawxml'
      value: a.policy
    }
    dependsOn: [ agentOps[i] ]
  }
]

resource agentDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = [
  for (a, i) in apis: {
    parent: agentApis[i]
    name: 'applicationinsights'
    properties: {
      loggerId: appInsightsLoggerId
      metrics: true
      alwaysLog: 'allErrors'
      sampling: {
        samplingType: 'fixed'
        percentage: 100
      }
      verbosity: 'information'
      httpCorrelationProtocol: 'W3C'
      logClientIp: true
      frontend: {
        request: {
          headers: [ oidHeaderName ]
          body: { bytes: 8192 }
        }
        response: {
          headers: []
          body: { bytes: 8192 }
        }
      }
      backend: {
        request: {
          headers: [ oidHeaderName ]
          body: { bytes: 8192 }
        }
        response: {
          headers: []
          body: { bytes: 8192 }
        }
      }
    }
  }
]

// Azure Monitor LLM logging (prompts/completions/tokens) for the agent APIs. The agent's
// Responses-API-compatible output (with usage) is parsed into ApiManagementGatewayLlmLog.
resource agentLlmDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = [
  for (a, i) in apis: {
    parent: agentApis[i]
    name: 'azuremonitor'
    properties: {
      loggerId: '${apimService.id}/loggers/azuremonitor'
      sampling: {
        samplingType: 'fixed'
        percentage: 100
      }
      largeLanguageModel: {
        logs: 'enabled'
        requests: {
          maxSizeInBytes: 32768
          messages: 'all'
        }
        responses: {
          maxSizeInBytes: 32768
          messages: 'all'
        }
      }
    }
  }
]

output expertApiName string = agentApis[0].name
output updatesApiName string = agentApis[1].name
output deepWikiApiName string = agentApis[2].name

// API Management service + App Insights logger + diagnostics + agent subscription.
// One instance hosts three logical gateways (Agent GW, Model GW, MCP GW).
param location string
param tags object
param serviceName string
param skuName string
param skuCapacity int
param publisherEmail string
param publisherName string
param appInsightsName string
param logAnalyticsWorkspaceId string
param oidHeaderName string
@description('Resource ID of the user-assigned identity dedicated to APIM-to-Agent authentication.')
param agentBackendCallerIdentityId string

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' = {
  name: serviceName
  location: location
  tags: tags
  sku: {
    name: skuName
    capacity: skuCapacity
  }
  identity: {
    type: 'SystemAssigned,UserAssigned'
    userAssignedIdentities: {
      '${agentBackendCallerIdentityId}': {}
    }
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2024-06-01-preview' = {
  parent: apimService
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for AI gateway telemetry'
    resourceId: appInsights.id
    credentials: {
      instrumentationKey: appInsights.properties.InstrumentationKey
    }
  }
}

// Service-wide (All APIs) App Insights diagnostic.
// Response body logging is DISABLED globally (bytes: 0) so it never interferes with
// MCP streaming. Agent GW / Model GW override this per-API to capture prompts/completions.
// The oid header is logged on every hop so telemetry is filterable by user.
resource apimDiagnostic 'Microsoft.ApiManagement/service/diagnostics@2024-06-01-preview' = {
  parent: apimService
  name: 'applicationinsights'
  properties: {
    loggerId: apimLogger.id
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
        body: { bytes: 0 }
      }
      response: {
        headers: []
        body: { bytes: 0 }
      }
    }
    backend: {
      request: {
        headers: [ oidHeaderName ]
        body: { bytes: 0 }
      }
      response: {
        headers: []
        body: { bytes: 0 }
      }
    }
  }
}

// Send AI gateway resource logs (incl. ApiManagementGatewayLlmLog) to Log Analytics.
// NOTE: on the v2 tiers these log categories are NOT members of the 'allLogs' category group,
// so they must be enabled explicitly by category or nothing is emitted.
resource apimToLaw 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'apim-to-law'
  scope: apimService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    // 'Dedicated' routes logs to resource-specific tables (ApiManagementGatewayLlmLog,
    // ApiManagementGatewayLogs, ApiManagementGatewayMCPLog). The AI gateway LLM log table
    // only exists in Dedicated mode; the legacy AzureDiagnostics table does not carry it.
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'GatewayLogs'
        enabled: true
      }
      {
        category: 'GatewayLlmLogs'
        enabled: true
      }
      {
        category: 'GatewayMCPLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// Subscription used by the agents (service-to-service) to call Model GW and MCP GW.
resource agentSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = {
  parent: apimService
  name: 'agents'
  properties: {
    displayName: 'Agents (service-to-service, all APIs)'
    scope: '/apis'
    state: 'active'
    allowTracing: false
  }
}

output name string = apimService.name
output gatewayUrl string = apimService.properties.gatewayUrl
output identityPrincipalId string = apimService.identity.principalId
output appInsightsLoggerId string = apimLogger.id
output agentSubscriptionName string = agentSubscription.name

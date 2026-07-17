// MCP GW: MCP servers exposed as transparent HTTP pass-through APIs.
//
// The APIM preview type:'mcp' contract is inconsistent between the published Bicep types and
// the resource provider, so we model the MCP gateways as plain HTTP APIs. MCP Streamable HTTP
// is JSON-RPC over HTTP (POST for messages, GET for the SSE stream, DELETE to end a session);
// a standard APIM API proxies all of it transparently while adding the oid trace.
param apimName string
param appInsightsLoggerId string
param oidHeaderName string

@description('{ path, displayName, backendUrl } for the Microsoft Learn MCP server.')
param learnMcp object

@description('{ path, displayName, backendUrl } for the Release communications MCP server.')
param updatesMcp object

@description('{ path, displayName, backendUrl } for the DeepWiki MCP server.')
param deepWikiMcp object

var servers = [ learnMcp, updatesMcp, deepWikiMcp ]
// MCP Streamable HTTP needs POST (messages), GET (SSE stream) and DELETE (end session) on the
// API root. apiIndex maps each operation to its API in the servers array above.
var operations = [
  { apiIndex: 0, method: 'POST', name: 'post' }
  { apiIndex: 0, method: 'GET', name: 'get' }
  { apiIndex: 0, method: 'DELETE', name: 'delete' }
  { apiIndex: 1, method: 'POST', name: 'post' }
  { apiIndex: 1, method: 'GET', name: 'get' }
  { apiIndex: 1, method: 'DELETE', name: 'delete' }
  { apiIndex: 2, method: 'POST', name: 'post' }
  { apiIndex: 2, method: 'GET', name: 'get' }
  { apiIndex: 2, method: 'DELETE', name: 'delete' }
]

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
}

resource mcpApis 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = [
  for s in servers: {
    parent: apimService
    name: s.path
    properties: {
      displayName: s.displayName
      description: 'MCP server pass-through governed by API Management.'
      path: s.path
      protocols: [ 'https' ]
      // Full backend MCP endpoint (e.g. https://learn.microsoft.com/api/mcp).
      serviceUrl: s.backendUrl
      subscriptionRequired: true
      subscriptionKeyParameterNames: {
        header: 'Ocp-Apim-Subscription-Key'
        query: 'subscription-key'
      }
      type: 'http'
    }
  }
]

resource mcpOps 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = [
  for op in operations: {
    parent: mcpApis[op.apiIndex]
    name: op.name
    properties: {
      displayName: op.method
      method: op.method
      urlTemplate: '/'
      templateParameters: []
      responses: []
    }
  }
]

resource mcpPolicies 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = [
  for (s, i) in servers: {
    parent: mcpApis[i]
    name: 'policy'
    properties: {
      format: 'rawxml'
      value: loadTextContent('../policies/mcp-gw.xml')
    }
    dependsOn: [ mcpOps ]
  }
]

// Log MCP tool-call requests (input) + oid header. Response body is NOT logged (streaming).
resource mcpDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = [
  for (s, i) in servers: {
    parent: mcpApis[i]
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
          body: { bytes: 0 }
        }
      }
      backend: {
        request: {
          headers: [ oidHeaderName ]
          body: { bytes: 8192 }
        }
        response: {
          headers: []
          body: { bytes: 0 }
        }
      }
    }
  }
]

output learnServerUrl string = '${apimService.properties.gatewayUrl}/${learnMcp.path}'
output updatesServerUrl string = '${apimService.properties.gatewayUrl}/${updatesMcp.path}'
output deepWikiServerUrl string = '${apimService.properties.gatewayUrl}/${deepWikiMcp.path}'

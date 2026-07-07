// Model GW: Azure OpenAI v1 (Foundry) imported from the official OpenAPI specification so that
// API Management recognizes it as an LLM API. This enables native token metrics + LLM message
// logging (which a passthrough API does NOT get). The backend authenticates to Foundry with the
// APIM managed identity.
param apimName string
param apiPath string
@description('Foundry OpenAI endpoint root, e.g. https://<account>.openai.azure.com')
param foundryOpenAiEndpoint string
param appInsightsLoggerId string
param oidHeaderName string

var backendName = 'foundry-openai-v1'

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
}

// Backend to Foundry's Azure OpenAI v1 endpoint, authenticated with APIM's managed identity.
resource inferenceBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apimService
  name: backendName
  properties: {
    description: 'Foundry Azure OpenAI v1 backend'
    url: '${foundryOpenAiEndpoint}/openai/v1'
    protocol: 'http'
    credentials: {
      #disable-next-line BCP037
      managedIdentity: {
        resource: 'https://cognitiveservices.azure.com'
      }
    }
  }
}

// Azure OpenAI v1 API imported from the OpenAPI spec (this is what makes APIM LLM-aware).
resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apimService
  name: 'model-gw'
  properties: {
    displayName: 'Model GW'
    description: 'Foundry Azure OpenAI v1 with per-oid token metrics and LLM logging.'
    apiType: 'http'
    type: 'http'
    format: 'openapi+json'
    value: string(loadJsonContent('../specs/AIFoundryOpenAIV1.json'))
    path: '${apiPath}/openai/v1'
    protocols: [ 'https' ]
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'Ocp-Apim-Subscription-Key'
      query: 'subscription-key'
    }
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(loadTextContent('../policies/model-gw.xml'), '{backend-id}', backendName)
  }
  dependsOn: [ inferenceBackend ]
}

// Override global diagnostic to capture completions (response body) + oid header for this API.
resource apiDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = {
  parent: api
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

// Azure Monitor LLM logging: populates ApiManagementGatewayLlmLog with prompts, completions and
// token usage. Uses the built-in 'azuremonitor' logger; requires the GatewayLlmLogs category to be
// enabled on the service diagnostic setting (see apim.bicep).
resource apiLlmDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = {
  parent: api
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
        maxSizeInBytes: 262144
        messages: 'all'
      }
      responses: {
        maxSizeInBytes: 262144
        messages: 'all'
      }
    }
  }
}

output apiName string = api.name

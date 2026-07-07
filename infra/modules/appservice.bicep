// Frontend App Service (Linux, Python) hosting the Flask BFF + UI, protected by Easy Auth.
param location string
param tags object
param planName string
param planSkuName string = 'F1'
param planSkuTier string = 'Free'
param siteName string
param serviceTag string
param identityId string
param appInsightsConnectionString string
param authClientId string
param authClientCredentialSettingName string
param apiIdentifierUri string
param tenantId string
param agentGwExpertBaseUrl string
param agentGwUpdatesBaseUrl string
param oidHeaderName string

// Free/Shared tiers don't support Always On.
var alwaysOn = planSkuTier != 'Free' && planSkuTier != 'Shared'

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: planSkuName
    tier: planSkuTier
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource site 'Microsoft.Web/sites@2023-12-01' = {
  name: siteName
  location: location
  tags: union(tags, { 'azd-service-name': serviceTag })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      alwaysOn: alwaysOn
      appCommandLine: 'gunicorn --worker-class gthread --workers 2 --threads 8 --timeout 600 --bind 0.0.0.0:8000 app:app'
    }
  }
}

resource appSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: site
  name: 'appsettings'
  properties: {
    SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
    ENABLE_ORYX_BUILD: 'true'
    WEBSITES_PORT: '8000'
    APPLICATIONINSIGHTS_CONNECTION_STRING: appInsightsConnectionString
    // BFF -> Agent GW routing.
    AGENT_GW_EXPERT_BASE_URL: agentGwExpertBaseUrl
    AGENT_GW_UPDATES_BASE_URL: agentGwUpdatesBaseUrl
    OID_HEADER_NAME: oidHeaderName
    // Placeholder; the postprovision hook writes the real Easy Auth client secret here.
    '${authClientCredentialSettingName}': 'placeholder-set-by-postprovision'
  }
}

// App Service Authentication (Easy Auth) with Entra ID. Requests an access token for the
// app's own API scope so the BFF can forward it to APIM Agent GW, which validates it and
// extracts oid.
resource authSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: site
  name: 'authsettingsV2'
  properties: {
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
    }
    httpSettings: {
      requireHttps: true
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: authClientId
          clientSecretSettingName: authClientCredentialSettingName
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
        }
        login: {
          loginParameters: [
            'scope=openid profile offline_access ${apiIdentifierUri}/user_impersonation'
          ]
        }
        validation: {
          allowedAudiences: [
            apiIdentifierUri
            authClientId
          ]
        }
      }
    }
    login: {
      tokenStore: {
        enabled: true
      }
    }
  }
  dependsOn: [ appSettings ]
}

output name string = site.name
output defaultHostName string = site.properties.defaultHostName
output uri string = 'https://${site.properties.defaultHostName}'

# Predeploy: place the APIM service-to-service key in a write-only Foundry connection.
$ErrorActionPreference = 'Stop'

$envValues = azd env get-values --output json | ConvertFrom-Json
$subscriptionId = $envValues.AZURE_SUBSCRIPTION_ID
$resourceGroup = $envValues.AZURE_RESOURCE_GROUP
$apimName = $envValues.APIM_SERVICE_NAME
$projectEndpoint = $envValues.FOUNDRY_PROJECT_ENDPOINT
$gatewayUrl = $envValues.APIM_GATEWAY_URL

if ([string]::IsNullOrWhiteSpace($projectEndpoint) -or [string]::IsNullOrWhiteSpace($apimName)) {
  throw 'FOUNDRY_PROJECT_ENDPOINT or APIM_SERVICE_NAME is missing. Run azd provision first.'
}

$key = az rest --method POST --url "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimName/subscriptions/agents/listSecrets?api-version=2024-06-01-preview" --query primaryKey -o tsv
if ([string]::IsNullOrWhiteSpace($key)) { throw 'Failed to retrieve the APIM agents subscription key.' }

Write-Host 'Creating/updating the write-only Foundry connection used by Hosted Agents...'
azd ai connection create apim-agent-subscription `
  --project-endpoint $projectEndpoint `
  --kind remote-tool `
  --target $gatewayUrl `
  --auth-type custom-keys `
  --custom-key "api_key=$key" `
  --force `
  --no-prompt | Out-Null

Write-Host 'Hosted Agent connection is ready.'
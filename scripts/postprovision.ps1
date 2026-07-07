# Postprovision: finalize App Service Easy Auth.
# - Creates a client secret for the auto-created Entra app and stores it in the web app.
# - Best-effort admin consent for Microsoft Graph delegated permissions.
$ErrorActionPreference = 'Stop'

Write-Host 'Reading azd environment values...'
$envValues = azd env get-values --output json | ConvertFrom-Json

$clientId    = $envValues.AUTH_CLIENT_ID
$webApp      = $envValues.SERVICE_WEB_NAME
$resourceGrp = $envValues.AZURE_RESOURCE_GROUP
$settingName = $envValues.AUTH_CLIENT_SECRET_SETTING_NAME

if ([string]::IsNullOrWhiteSpace($clientId)) {
  Write-Host 'AUTH_CLIENT_ID is empty (createAuthApp=false); skipping Easy Auth secret setup.'
  exit 0
}
if ([string]::IsNullOrWhiteSpace($settingName)) { $settingName = 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET' }

Write-Host "Creating a client secret for Entra app $clientId ..."
$secret = az ad app credential reset --id $clientId --display-name 'aigw-easyauth' --years 1 --query password -o tsv
if ([string]::IsNullOrWhiteSpace($secret)) { throw 'Failed to create the Entra app client secret.' }

Write-Host "Storing the secret in $webApp app settings ($settingName) ..."
az webapp config appsettings set -g $resourceGrp -n $webApp --settings "$settingName=$secret" | Out-Null

Write-Host 'Granting admin consent (best effort)...'
try {
  az ad app permission admin-consent --id $clientId 2>$null | Out-Null
} catch {
  Write-Warning 'Admin consent skipped (insufficient privileges). Users will consent at first sign-in.'
}

Write-Host 'Restarting web app to apply auth settings...'
az webapp restart -g $resourceGrp -n $webApp | Out-Null

Write-Host 'Easy Auth configuration complete.'

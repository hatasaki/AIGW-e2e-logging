#!/bin/sh
# Postprovision: finalize App Service Easy Auth.
# - Creates a client secret for the auto-created Entra app and stores it in the web app.
# - Best-effort admin consent for Microsoft Graph delegated permissions.
set -e

echo 'Reading azd environment values...'
eval "$(azd env get-values | sed 's/^/export /')"

CLIENT_ID="${AUTH_CLIENT_ID}"
WEB_APP="${SERVICE_WEB_NAME}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}"
SETTING_NAME="${AUTH_CLIENT_SECRET_SETTING_NAME:-MICROSOFT_PROVIDER_AUTHENTICATION_SECRET}"

if [ -z "${CLIENT_ID}" ]; then
  echo 'AUTH_CLIENT_ID is empty (createAuthApp=false); skipping Easy Auth secret setup.'
  exit 0
fi

echo "Creating a client secret for Entra app ${CLIENT_ID} ..."
SECRET=$(az ad app credential reset --id "${CLIENT_ID}" --display-name 'aigw-easyauth' --years 1 --query password -o tsv)
if [ -z "${SECRET}" ]; then
  echo 'Failed to create the Entra app client secret.' >&2
  exit 1
fi

echo "Storing the secret in ${WEB_APP} app settings (${SETTING_NAME}) ..."
az webapp config appsettings set -g "${RESOURCE_GROUP}" -n "${WEB_APP}" --settings "${SETTING_NAME}=${SECRET}" >/dev/null

echo 'Granting admin consent (best effort)...'
az ad app permission admin-consent --id "${CLIENT_ID}" >/dev/null 2>&1 || \
  echo 'Admin consent skipped (insufficient privileges). Users will consent at first sign-in.'

echo 'Restarting web app to apply auth settings...'
az webapp restart -g "${RESOURCE_GROUP}" -n "${WEB_APP}" >/dev/null

echo 'Easy Auth configuration complete.'

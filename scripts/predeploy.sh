#!/bin/sh
# Predeploy: place the APIM service-to-service key in a write-only Foundry connection.
set -e

eval "$(azd env get-values | sed 's/^/export /')"

if [ -z "${FOUNDRY_PROJECT_ENDPOINT}" ] || [ -z "${APIM_SERVICE_NAME}" ]; then
  echo 'FOUNDRY_PROJECT_ENDPOINT or APIM_SERVICE_NAME is missing. Run azd provision first.' >&2
  exit 1
fi

KEY=$(az rest --method POST \
  --url "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_SERVICE_NAME}/subscriptions/agents/listSecrets?api-version=2024-06-01-preview" \
  --query primaryKey -o tsv)

if [ -z "${KEY}" ]; then
  echo 'Failed to retrieve the APIM agents subscription key.' >&2
  exit 1
fi

echo 'Creating/updating the write-only Foundry connection used by Hosted Agents...'
azd ai connection create apim-agent-subscription \
  --project-endpoint "${FOUNDRY_PROJECT_ENDPOINT}" \
  --kind remote-tool \
  --target "${APIM_GATEWAY_URL}" \
  --auth-type custom-keys \
  --custom-key "api_key=${KEY}" \
  --force \
  --no-prompt >/dev/null

echo 'Hosted Agent connection is ready.'
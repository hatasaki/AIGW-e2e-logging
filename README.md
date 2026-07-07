# aigw-e2e-logging

End-to-end **AI gateway with per-user (`oid`) observability**, deployable with a single
`azd up`. The authenticated user's Entra ID `oid` is propagated through every hop —
API Management **Agent GW → Model GW / MCP GW** — so that agent, model and MCP traffic can be
searched by user, and model token consumption can be traced per user.

## Architecture

```
Browser ──(Entra login via Easy Auth)──► App Service (Flask BFF + UI)
   │  user access token (Bearer)
   ▼
APIM Agent GW  ── validate-jwt → extract oid → set x-user-oid ─────► Container Apps agents
   │                                                                  (Microsoft Agent Framework
   │                                                                   + FastAPI /openai/v1/responses)
   │                                        x-user-oid + APIM key ┌────┴────────────────┐
   │                                                              ▼                     ▼
   │                                                       APIM Model GW         APIM MCP GW (x2)
   │                                                    (token metric+oid)     (trace/metric+oid)
   │                                                              ▼                     ▼
   │                                                    Foundry gpt-5.4-mini   learn.microsoft.com/api/mcp
   │                                                                           microsoft.com/releasecommunications/mcp
   └──────────── logs & metrics (oid) ─────────────► Log Analytics + Application Insights
```

- **oid propagation**: Agent GW validates the user token and forwards `x-user-oid`. The agent
  re-injects `x-user-oid` on model calls (`OpenAIChatClient` default headers) and MCP calls
  (`MCPStreamableHTTPTool` header provider). Every gateway logs it.
- **Per-user token accounting**: the Model GW is imported from the **Azure OpenAI v1 OpenAPI
  spec** (so API Management is LLM-aware, not a passthrough). This enables (a) the
  `llm-emit-token-metric` policy to emit token counts to Application Insights with `oid` as a
  dimension, and (b) native **LLM logging** (`ApiManagementGatewayLlmLog`) capturing prompts,
  completions and token usage per request — correlated to `oid` via the request id.
- **Streaming** (SSE) is supported end to end (browser ⇄ BFF ⇄ Agent GW ⇄ agent ⇄ Model GW).

## Components

| Layer | Service | Source |
| --- | --- | --- |
| Frontend + BFF | App Service (Python/Flask, Easy Auth) | `src/frontend` |
| Agents (x2) | Container Apps (Agent Framework + FastAPI) | `src/agent` |
| Gateways | API Management StandardV2 (Agent/Model/MCP) | `infra/modules/apim-*.bicep`, `infra/policies` |
| Model | Azure AI Foundry deployment (`gpt-5.4-mini`) | `infra/modules/foundry.bicep` |
| Identity | Entra app registration (Graph Bicep) | `infra/graph/entra.bicep` |
| Observability | Log Analytics + Application Insights | `infra/modules/monitoring.bicep`, `docs/queries.kql` |

## Prerequisites

- [Azure Developer CLI (`azd`)](https://aka.ms/azd) and [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.73+
- Docker (for building the agent image locally) or rely on ACR remote build (default)
- Permissions to **create an Entra app registration** in your tenant (for the auto-created
  auth app). Otherwise set `CREATE_AUTH_APP=false` and supply `AUTH_CLIENT_ID` (see below).
- A region and subscription with capacity for the chosen Foundry model.

## Deploy

```bash
azd auth login
azd env new aigw-dev
azd env set AZURE_LOCATION eastus2
# Optional overrides:
# azd env set MODEL_NAME gpt-5.4-mini
# azd env set MODEL_VERSION 2025-xx-xx
azd up
```

`azd up` provisions the infrastructure, builds & pushes the two agent images and the web app,
then runs the postprovision hook that creates the Easy Auth client secret and (best effort)
grants admin consent.

When it finishes, open the `SERVICE_WEB_URI` output, sign in with Entra ID, pick an agent and chat.

## Verify oid end-to-end

1. Chat with both agents in the UI (responses stream token by token).
2. In **Log Analytics / Application Insights**, run the queries in [docs/queries.kql](docs/queries.kql):
   - per-oid **token consumption** (Model GW),
   - per-oid **MCP calls**,
   - per-oid **prompts/completions** (Agent GW / Model GW),
   - all gateway **requests** for a given oid.

## Configuration (azd env vars)

| Variable | Default | Purpose |
| --- | --- | --- |
| `AZURE_LOCATION` | – | Deployment region |
| `MODEL_NAME` | `gpt-5.4-mini` | Foundry model to deploy |
| `MODEL_VERSION` | (default) | Model version; empty = provider default |
| `MODEL_SKU_NAME` | `GlobalStandard` | Deployment throughput SKU |
| `CREATE_AUTH_APP` | `true` | Auto-create the Entra app via Graph Bicep |
| `AUTH_CLIENT_ID` | – | Existing app id when `CREATE_AUTH_APP=false` |

## Notes & verified facts

- **Agent Framework**: uses the GA release **`agent-framework==1.10.0`** (Production/Stable).
  Verified against source: `Message` (message type), `OpenAIChatClient(base_url=…, api_key=…,
  default_headers=…)`, `MCPStreamableHTTPTool(header_provider=…)` +
  `agent.run(..., function_invocation_kwargs=…)` are all correct on 1.10.
- **Responses API / Model GW**: the Model GW is imported from the official **Azure OpenAI v1
  OpenAPI specification** (`infra/specs/AIFoundryOpenAIV1.json`, `format: openapi+json`) so API
  Management treats it as an LLM API. A dedicated **backend** (`infra/modules/apim-model-gw.bicep`)
  targets `{endpoint}/openai/v1` and authenticates with the APIM **managed identity** (token
  audience `https://cognitiveservices.azure.com`); the APIM identity is granted **Cognitive
  Services OpenAI User** on Foundry. The agent calls `POST {apim}/model/openai/v1/responses`.
- **Native LLM logs go to resource-specific tables**: the APIM diagnostic setting uses
  `logAnalyticsDestinationType: Dedicated` (`infra/modules/apim.bicep`) so gateway/LLM/MCP logs
  land in `ApiManagementGatewayLlmLog` / `ApiManagementGatewayLogs` / `ApiManagementGatewayMCPLog`
  (Microsoft's recommended mode, and required for the built-in AI-gateway dashboard). When an
  existing instance is first switched to Dedicated, API Management can take a while to route logs
  to the resource-specific table; during that window the same rows are in `AzureDiagnostics`
  (see the transition query in [docs/queries.kql](docs/queries.kql)).
- **Model**: `gpt-5.4-mini` is a supported Responses model (version `2026-03-17`), but availability is
  region-dependent. Override `MODEL_NAME` / `MODEL_VERSION` / `AZURE_LOCATION` if a region lacks it.
- **MCP logging**: MCP is streaming (Streamable HTTP), so response bodies are never logged (that would
  break the transport). Each MCP call is still attributed to the user via an oid trace + `mcp-calls`
  metric, and the request (tool-call) body is captured. This is by design.
- **Microsoft Graph Bicep extension**: pinned in `infra/bicepconfig.json`
  (`microsoftgraph/v1.0:0.1.8-preview`) and verified to restore + compile with `az bicep build`.
  If a future toolchain rejects the tag, bump it to the latest from the
  [releases](https://github.com/microsoftgraph/msgraph-bicep-types/releases), or set
  `CREATE_AUTH_APP=false` and provide an existing `AUTH_CLIENT_ID`.
- **Agents on Container Apps** expose a minimal OpenAI **Responses** surface
  (`/openai/v1/responses`) via FastAPI, since Python has no turn-key Responses host yet; the
  BFF and Agent GW speak the Responses API to it.

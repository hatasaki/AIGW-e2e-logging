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
APIM Agent GW  ── validate-jwt → extract oid → set x-client-user-oid ─┬─► Container Apps agents (x2)
  │                                                                 └─► Foundry Hosted DeepWiki agent
  │                                      x-client-user-oid + APIM key          │
  │                                                        ┌───────────────────┴──────────────┐
  │                                                        ▼                                  ▼
  │                                                 APIM Model GW                      APIM MCP GW (x3)
  │                                              (token metric + oid)                (trace/metric + oid)
  │                                                        ▼                                  ▼
  │                                              Foundry gpt-5.4-mini      Learn / Release communications /
  │                                                                         DeepWiki MCP servers
   └──────────── logs & metrics (oid) ─────────────► Log Analytics + Application Insights
```

- **oid propagation**: Agent GW validates the user token and forwards `x-client-user-oid`. The
  agents re-inject `x-client-user-oid` on model calls (`OpenAIChatClient.default_headers`) and
  all MCP transport calls through an oid-scoped `httpx.AsyncClient`. Every gateway logs it.
- **Per-user token accounting**: the Model GW is imported from the **Azure OpenAI v1 OpenAPI
  spec** (so API Management is LLM-aware, not a passthrough). This enables (a) the
  `llm-emit-token-metric` policy to emit token counts to Application Insights with `oid` as a
  dimension, and (b) native **LLM logging** (`ApiManagementGatewayLlmLog`) capturing prompts,
  completions and token usage per request — correlated to `oid` via the request id.
- **Streaming** (SSE) is supported end to end (browser ⇄ BFF ⇄ Agent GW ⇄ agent ⇄ Model GW).
- **Agent backend authentication**: Agent GW replaces the validated user token with a backend
  token selected for the target. Container Apps Easy Auth accepts only the dedicated APIM UAMI;
  Foundry accepts APIM's system identity through the project-scoped **Foundry Agent Consumer** role.
- **Hosted header contract**: Foundry forwards caller headers prefixed with `x-client-` into the
  Hosted Agent container. `x-client-user-oid` is therefore used consistently by all agents,
  Model GW, and all three MCP gateways.

## Components

| Layer | Service | Source |
| --- | --- | --- |
| Frontend + BFF | App Service (Python/Flask, Easy Auth) | `src/frontend` |
| Agents (x2) | Container Apps (Easy Auth + Agent Framework `ResponsesHostServer`) | `src/agent` |
| DeepWiki Agent | Microsoft Foundry Hosted Agent (Agent Framework 1.11) | `src/agent-deepwiki` |
| Gateways | API Management StandardV2 (Agent/Model/MCP) | `infra/modules/apim-*.bicep`, `infra/policies` |
| Model | Azure AI Foundry deployment (`gpt-5.4-mini`) | `infra/modules/foundry.bicep` |
| Identity | User-facing + Agent-backend Entra app registrations (Graph Bicep) | `infra/graph` |
| Observability | Log Analytics + Application Insights | `infra/modules/monitoring.bicep`, `docs/queries.kql` |

### Agents

| UI agent | Runtime | MCP backend through APIM | Agent GW backend authentication |
| --- | --- | --- | --- |
| Azure expert | Container Apps + MAF `ResponsesHostServer` | Microsoft Learn MCP | Dedicated APIM UAMI → Agent backend API; Container Apps Easy Auth |
| Azure updates | Container Apps + MAF `ResponsesHostServer` | Microsoft Release communications MCP | Dedicated APIM UAMI → Agent backend API; Container Apps Easy Auth |
| DeepWiki | Foundry Hosted Agent + MAF `ResponsesHostServer` | `https://mcp.deepwiki.com/mcp` (anonymous backend) | APIM system MI → Foundry; project-scoped Foundry Agent Consumer |

All three agents call the model through Model GW and their MCP server through MCP GW. The
Container Apps agents expose the official MAF Responses server at `/openai/v1/responses` using
`prefix="/openai/v1"`. The Hosted Agent exposes Responses protocol `2.0.0` at its Foundry
dedicated endpoint.

## Identity and trust boundaries

| Hop | Credential / identity | Validation / authorization |
| --- | --- | --- |
| Browser → App Service | User Entra session | App Service Easy Auth |
| BFF → Agent GW | User access token only; BFF does **not** send oid | APIM `validate-jwt`; APIM derives `oid` and overwrites `x-client-user-oid` |
| Agent GW → Container Apps agents | APIM dedicated UAMI, v1 app-only token | Dedicated Agent backend Entra app requires `Agent.Invoke`; Easy Auth validates issuer, audience and allowed UAMI `appid` |
| Agent GW → Foundry Hosted Agent | APIM system-assigned MI; audience `https://ai.azure.com` | Foundry Agent Consumer on the Foundry project |
| Agent → Model/MCP GW | `Ocp-Apim-Subscription-Key` + `x-client-user-oid` | APIM subscription + per-oid diagnostics/metrics |
| Model GW → Foundry model | APIM system-assigned MI; audience `https://cognitiveservices.azure.com` | Cognitive Services OpenAI User on the Foundry account |

APIM has both **SystemAssigned** and **UserAssigned** identities. The dedicated UAMI is used only
for Container Apps Agent backend tokens; the system identity is used for Foundry model and Hosted
Agent calls. The user token never reaches an agent backend. Foundry `x-ms-user-identity`
delegation/session impersonation is intentionally **not enabled** in this implementation; oid is
used for propagation and observability, while Foundry handles its own protocol session context.

## Prerequisites

- [Azure Developer CLI (`azd`)](https://aka.ms/azd) and [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.73+
- Docker (for building the agent image locally) or rely on ACR remote build (default)
- Permissions to **create an Entra app registration and app-role assignment** in your tenant.
  `CREATE_AUTH_APP=false` can reuse an existing frontend app, but the dedicated Agent backend app
  and its APIM-only `Agent.Invoke` assignment are always created automatically.
- Permissions to assign **Foundry Project Manager** to the deployer and **Foundry Agent Consumer**
  to APIM. Hosted Agents are currently a Foundry preview feature.
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

`azd up` provisions the infrastructure, builds and pushes the two Container Apps agent images,
deploys the Hosted DeepWiki Agent source and the web app, and runs these secret-handling hooks:

- `postprovision`: creates the Easy Auth client secret and, best effort, grants admin consent.
- `predeploy`: reads the APIM `agents` subscription key and stores it as field `api_key` in the
  write-only Foundry `CustomKeys` connection `apim-agent-subscription`. The Hosted Agent receives
  it through the runtime placeholder `${{connections.apim-agent-subscription.credentials.api_key}}`.

The Container Apps agents receive the same key from a Container Apps secret created during
provisioning. The secret value is never committed to source or embedded as plaintext in
`azure.yaml`; connection reads also never return the stored credential.

When it finishes, open the `SERVICE_WEB_URI` output, sign in with Entra ID, pick an agent and chat.

## Verify oid end-to-end

1. Chat with the Azure expert, Azure updates, and DeepWiki agents in the UI.
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

Important provisioned outputs/runtime settings:

| Output / setting | Purpose |
| --- | --- |
| `FOUNDRY_PROJECT_ENDPOINT` | Existing Foundry project binding consumed by the `azure.ai.project` service |
| `AZURE_AI_PROJECT_ID` | Foundry project ARM ID used for project-scoped role checks |
| `APIM_SERVICE_NAME` | Used by the predeploy hook to retrieve the `agents` subscription secret |
| `AGENT_GW_EXPERT_URL`, `AGENT_GW_UPDATES_URL`, `AGENT_GW_DEEPWIKI_URL` | Public user-authenticated Agent GW URLs |
| `MCP_GW_LEARN_URL`, `MCP_GW_UPDATES_URL`, `MCP_GW_DEEPWIKI_URL` | Agent-only MCP GW URLs |
| `OID_HEADER_NAME` | Runtime setting fixed to `x-client-user-oid` for every agent |
| `MODEL_DEPLOYMENT_NAME` | Runtime model deployment output passed to all agents |

## Notes & verified facts

- **Agent Framework**: all three agents use **`agent-framework-core==1.11.0`**, the
  **`agent-framework-openai==1.10.1`** adapter, and the official
  **`agent-framework-foundry-hosting==1.0.0a260709`** Responses host. The two Container Apps
  agents expose the host under `/openai/v1`; the DeepWiki Hosted Agent uses protocol 2.0.0.
- **APIM-to-Agent authentication**: `infra/graph/agent-backend-entra.bicep` creates a dedicated
  Agent API audience and requires the `Agent.Invoke` app role, assigned only to a dedicated UAMI
  attached to APIM. Agent GW's `authentication-managed-identity` policy obtains the token and
  replaces the frontend user token only after extracting `oid`. Container Apps Easy Auth validates
  the v1 Bearer token's issuer/audience and `allowedApplications` matches the UAMI `appid`; no
  backend secret or application authentication code is required.
- **Hosted Agent authentication**: `infra/modules/foundry-agent-consumer-role.bicep` grants APIM's
  system identity only the Foundry Agent Consumer role at project scope. Agent GW requests a token
  for `https://ai.azure.com`, adds `Foundry-Features: HostedAgents=V1Preview`, and rewrites the
  public `/openai/v1/responses` route to the Foundry `/responses` endpoint.
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
  metric, and the request (tool-call) body is captured. Learn, Release communications, and the
  anonymous DeepWiki server (`https://mcp.deepwiki.com/mcp`) all run through MCP GW.
- **Microsoft Graph Bicep extension**: pinned in `infra/bicepconfig.json`
  (`microsoftgraph/v1.0:0.1.8-preview`) and verified to restore + compile with `az bicep build`.
  If a future toolchain rejects the tag, bump it to the latest from the
  [releases](https://github.com/microsoftgraph/msgraph-bicep-types/releases), or set
  `CREATE_AUTH_APP=false` and provide an existing `AUTH_CLIENT_ID`.
- **Agents on Container Apps** use the official `ResponsesHostServer` for request parsing,
  history, response envelopes, SSE streaming, cancellation, errors, readiness, and
  observability. Custom code is limited to binding APIM's request-scoped oid and constructing
  per-request Model/MCP clients so concurrent users cannot share headers.
- **DeepWiki compatibility**: DeepWiki currently emits empty nonstandard `_meta._fastmcp`
  metadata during MCP tool discovery. A narrow `MCPStreamableHTTPTool` subclass removes only
  MCP-invalid metadata keys; transport, discovery, retries, tool invocation and telemetry remain
  MAF implementations. The adapter can be removed when the upstream metadata becomes compliant.
- **Token accounting remains at Model GW**: the current preview MAF hosting adapter does not
  project Agent Framework `usage` content into the outer agent response. Model GW still records
  authoritative per-oid/per-model token usage through native APIM LLM logs and metrics.

"""Runtime configuration for the agent service (read from container env vars)."""
from __future__ import annotations

import os


class Settings:
    # Identity / behaviour of this agent instance (set per Container App in Bicep).
    agent_name: str = os.getenv("AGENT_NAME", "agent")
    agent_instructions: str = os.getenv(
        "AGENT_INSTRUCTIONS", "You are a helpful assistant."
    )

    # Model GW (APIM) — OpenAI v1 base URL, e.g. https://<apim>/model/openai/v1
    model_gw_base_url: str = os.getenv("MODEL_GW_BASE_URL", "")
    model_deployment_name: str = os.getenv("MODEL_DEPLOYMENT_NAME", "gpt-5.4-mini")

    # MCP GW (APIM) — streamable HTTP endpoint, e.g. https://<apim>/mcp-learn/mcp
    mcp_server_url: str = os.getenv("MCP_SERVER_URL", "")

    # Shared APIM subscription key used for the service-to-service hops.
    apim_subscription_key: str = os.getenv("APIM_SUBSCRIPTION_KEY", "")

    # Header used to carry the end-user oid to Model GW / MCP GW.
    oid_header_name: str = os.getenv("OID_HEADER_NAME", "x-user-oid")

    port: int = int(os.getenv("PORT", "8000"))


settings = Settings()

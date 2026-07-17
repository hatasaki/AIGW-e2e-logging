"""Container Apps agent hosted by the Microsoft Agent Framework Responses server.

API Management validates the user JWT and forwards the trusted Entra oid in
``x-client-user-oid``. The server binds that header to the current request while a small
``SupportsAgentRun`` proxy creates oid-scoped Model GW and MCP GW clients.
"""
from __future__ import annotations

import contextlib
import contextvars
from collections.abc import AsyncIterator, Mapping
from typing import Any

from agent_framework import Agent, AgentSession, MCPStreamableHTTPTool
from agent_framework.openai import OpenAIChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from httpx import AsyncClient, Timeout

from settings import settings

_current_oid: contextvars.ContextVar[str] = contextvars.ContextVar(
    "agent_current_oid", default="anonymous"
)


class RequestScopedAgent:
    """Create the real MAF agent per request so outbound headers cannot cross users."""

    id = settings.agent_name
    name = settings.agent_name
    description = settings.agent_instructions
    context_providers: list[Any] = []

    @contextlib.asynccontextmanager
    async def _create_agent(self):
        headers = {
            "Ocp-Apim-Subscription-Key": settings.apim_subscription_key,
            settings.oid_header_name: _current_oid.get(),
        }
        chat_client = OpenAIChatClient(
            base_url=settings.model_gw_base_url,
            api_key=settings.apim_subscription_key,
            model=settings.model_deployment_name,
            default_headers=headers,
        )

        # The MCP client owns background initialize/list/SSE/cleanup requests. Pinning the
        # headers on its request-scoped HTTP client covers that complete lifecycle.
        async with AsyncClient(
            headers=headers,
            follow_redirects=True,
            timeout=Timeout(30.0, read=300.0),
        ) as http_client:
            mcp_tool = MCPStreamableHTTPTool(
                name=f"{settings.agent_name}-mcp",
                url=settings.mcp_server_url,
                http_client=http_client,
            )
            async with mcp_tool:
                yield Agent(
                    client=chat_client,
                    name=settings.agent_name,
                    instructions=settings.agent_instructions,
                    tools=mcp_tool,
                    # ResponsesHostServer owns conversation history.
                    default_options={"store": False},
                )

    def run(
        self,
        messages=None,
        *,
        stream: bool = False,
        session: AgentSession | None = None,
        function_invocation_kwargs: Mapping[str, Any] | None = None,
        client_kwargs: Mapping[str, Any] | None = None,
        **kwargs: Any,
    ):
        if stream:
            return self._run_stream(
                messages,
                session=session,
                function_invocation_kwargs=function_invocation_kwargs,
                client_kwargs=client_kwargs,
                **kwargs,
            )
        return self._run_once(
            messages,
            session=session,
            function_invocation_kwargs=function_invocation_kwargs,
            client_kwargs=client_kwargs,
            **kwargs,
        )

    async def _run_once(self, messages, **kwargs: Any):
        async with self._create_agent() as agent:
            return await agent.run(messages, stream=False, **kwargs)

    async def _run_stream(self, messages, **kwargs: Any) -> AsyncIterator[Any]:
        async with self._create_agent() as agent:
            async for update in agent.run(messages, stream=True, **kwargs):
                yield update

    def create_session(self, *, session_id: str | None = None) -> AgentSession:
        return AgentSession(session_id=session_id)

    def get_session(
        self,
        service_session_id,
        *,
        session_id: str | None = None,
    ) -> AgentSession:
        return AgentSession(service_session_id=service_session_id, session_id=session_id)


class OidAwareResponsesHostServer(ResponsesHostServer):
    """Expose the official Responses protocol with request-scoped oid binding."""

    async def _handle_response(self, request, context, cancellation_signal):
        token = _current_oid.set(
            context.client_headers.get(settings.oid_header_name.lower(), "anonymous")
        )
        try:
            response_events = await super()._handle_response(
                request, context, cancellation_signal
            )
            async for event in response_events:
                yield event
        finally:
            _current_oid.reset(token)


# Preserve the existing APIM backend contract while delegating the complete Responses API,
# streaming lifecycle, history, errors, cancellation and readiness to MAF.
server = OidAwareResponsesHostServer(RequestScopedAgent(), prefix="/openai/v1")


if __name__ == "__main__":
    server.run()

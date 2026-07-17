"""Foundry Hosted DeepWiki agent using Microsoft Agent Framework.

The Foundry gateway forwards only caller-defined headers prefixed with ``x-client-``.
The public Agent GW therefore sets ``x-client-user-oid`` after validating the user's JWT.
This module captures that request-scoped header and re-injects it on every Model GW and MCP GW
call so the same oid remains searchable across all logical gateways.
"""
from __future__ import annotations

import contextlib
import contextvars
import os
import re
from collections.abc import AsyncIterator, Mapping
from typing import Any

from agent_framework import Agent, AgentSession, MCPStreamableHTTPTool
from agent_framework.openai import OpenAIChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from httpx import AsyncClient, Timeout

OID_HEADER_NAME = os.getenv("OID_HEADER_NAME", "x-client-user-oid")
MODEL_GW_BASE_URL = os.environ["MODEL_GW_BASE_URL"]
MODEL_DEPLOYMENT_NAME = os.environ["MODEL_DEPLOYMENT_NAME"]
MCP_SERVER_URL = os.environ["MCP_SERVER_URL"]
APIM_SUBSCRIPTION_KEY = os.environ["APIM_SUBSCRIPTION_KEY"]

_current_oid: contextvars.ContextVar[str] = contextvars.ContextVar(
    "deepwiki_current_oid", default="anonymous"
)

# MCP 2025-06-18 _meta key-name grammar. DeepWiki currently adds the nonstandard
# `_fastmcp` key (with an empty tags array) to tools/list. Preserve every standards-compliant
# metadata entry and discard only invalid extension keys before Agent Framework validates them.
_MCP_META_KEY_PATTERN = re.compile(
    r"^(?:(?:[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?)"
    r"(?:\.[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*/)?"
    r"[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?$"
)


class _SanitizingMcpSession:
    """Delegate an MCP session while filtering invalid tools/list metadata keys."""

    def __init__(self, inner: Any) -> None:
        self._inner = inner

    def __getattr__(self, name: str) -> Any:
        return getattr(self._inner, name)

    async def list_tools(self, *args: Any, **kwargs: Any) -> Any:
        result = await self._inner.list_tools(*args, **kwargs)
        for remote_tool in result.tools:
            if isinstance(remote_tool.meta, dict):
                remote_tool.meta = {
                    key: value
                    for key, value in remote_tool.meta.items()
                    if isinstance(key, str) and _MCP_META_KEY_PATTERN.fullmatch(key)
                } or None
        return result


class DeepWikiMCPStreamableHTTPTool(MCPStreamableHTTPTool):
    """MCPStreamableHTTPTool compatible with DeepWiki's FastMCP metadata extension."""

    async def _load_tools_locked(self) -> None:
        if self.session is not None and not isinstance(
            self.session, _SanitizingMcpSession
        ):
            self.session = _SanitizingMcpSession(self.session)
        await super()._load_tools_locked()


class RequestScopedDeepWikiAgent:
    """Build an Agent Framework agent per request so downstream headers are user-scoped."""

    id = "deepwiki-agent"
    name = "deepwiki-agent"
    description = "Answers repository questions using the DeepWiki MCP server."
    context_providers: list[Any] = []

    @contextlib.asynccontextmanager
    async def _create_agent(self):
        oid = _current_oid.get()
        headers = {
            "Ocp-Apim-Subscription-Key": APIM_SUBSCRIPTION_KEY,
            OID_HEADER_NAME: oid,
        }
        chat_client = OpenAIChatClient(
            base_url=MODEL_GW_BASE_URL,
            api_key=APIM_SUBSCRIPTION_KEY,
            model=MODEL_DEPLOYMENT_NAME,
            default_headers=headers,
        )

        # Pin headers on the request-scoped client so initialize/list, tool calls, the SSE reader,
        # and session cleanup all carry the same oid and APIM subscription key.
        async with AsyncClient(
            headers=headers,
            follow_redirects=True,
            timeout=Timeout(30.0, read=300.0),
        ) as http_client:
            mcp_tool = DeepWikiMCPStreamableHTTPTool(
                name="deepwiki-mcp",
                url=MCP_SERVER_URL,
                http_client=http_client,
            )
            async with mcp_tool:
                yield Agent(
                    client=chat_client,
                    name=self.name,
                    instructions=(
                        "You are a DeepWiki repository expert. Use the DeepWiki MCP tools to "
                        "research repositories before answering. Cite the repository pages or "
                        "source locations returned by the tools, and clearly state when the "
                        "available repository information is insufficient."
                    ),
                    tools=mcp_tool,
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
    """Bind the forwarded oid header to each complete Responses request lifecycle."""

    async def _handle_response(self, request, context, cancellation_signal):
        token = _current_oid.set(
            context.client_headers.get(OID_HEADER_NAME.lower(), "anonymous")
        )
        try:
            response_events = await super()._handle_response(
                request, context, cancellation_signal
            )
            async for event in response_events:
                yield event
        finally:
            _current_oid.reset(token)


agent = RequestScopedDeepWikiAgent()
server = OidAwareResponsesHostServer(agent)


if __name__ == "__main__":
    server.run()

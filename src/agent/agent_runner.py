"""
Agent runner: builds a Microsoft Agent Framework agent per request and forwards the
authenticated user's `oid` on every downstream hop.

Two propagation points (both required by the design):
  * Model calls  -> OpenAIChatClient(default_headers=...) sends `x-user-oid` (+ APIM key)
                    to the Model GW on every model request.
  * MCP calls    -> MCPStreamableHTTPTool(header_provider=...) sends `x-user-oid` (+ APIM key)
                    to the MCP GW on every tool call. Using a *local* MCP tool ensures the
                    agent process makes the call (so it can inject oid), instead of the model
                    service calling the MCP server directly.
"""
from __future__ import annotations

import contextlib
from collections.abc import AsyncIterator, Mapping
from typing import Any

from agent_framework import Agent, MCPStreamableHTTPTool, Message
from agent_framework.openai import OpenAIChatClient
from httpx import AsyncClient, Timeout

from settings import settings


def _model_headers(oid: str) -> dict[str, str]:
    return {
        "Ocp-Apim-Subscription-Key": settings.apim_subscription_key,
        settings.oid_header_name: oid,
    }


def _build_chat_client(oid: str) -> OpenAIChatClient:
    # Point the OpenAI Responses client at the APIM Model GW and attach the per-user headers.
    return OpenAIChatClient(
        base_url=settings.model_gw_base_url,
        api_key=settings.apim_subscription_key,
        model=settings.model_deployment_name,
        default_headers=_model_headers(oid),
    )


def to_chat_messages(turns: list[dict[str, str]]) -> list[Message]:
    """Convert normalized {role, text} turns into Agent Framework Messages."""
    valid_roles = {"user", "assistant", "system", "developer"}
    messages: list[Message] = []
    for turn in turns:
        role = turn.get("role", "user")
        if role == "developer":
            role = "system"
        if role not in valid_roles:
            role = "user"
        text = turn.get("text", "")
        if text:
            messages.append(Message(role=role, contents=[text]))
    return messages


@contextlib.asynccontextmanager
async def _agent_for(oid: str):
    """Yield an agent wired with an MCP tool, scoped to a single request/oid."""
    chat_client = _build_chat_client(oid)
    # Every MCP request must carry the APIM subscription key *and* the user's oid, including
    # the initialize/list handshake at connect time and the SSE/DELETE requests that the MCP
    # client issues from its own background task. A per-request header_provider only fires on
    # tool calls (and its contextvar does not reach that background task), so both headers are
    # pinned on the request-scoped HTTP client itself. _agent_for is built once per oid, so
    # the static oid header is correct and never leaks across users.
    async with AsyncClient(
        headers={
            "Ocp-Apim-Subscription-Key": settings.apim_subscription_key,
            settings.oid_header_name: oid,
        },
        follow_redirects=True,
        timeout=Timeout(30.0, read=300.0),
    ) as http_client:
        mcp_tool = MCPStreamableHTTPTool(
            name=f"{settings.agent_name}-mcp",
            url=settings.mcp_server_url,
            http_client=http_client,
        )
        async with mcp_tool:
            agent = Agent(
                client=chat_client,
                name=settings.agent_name,
                instructions=settings.agent_instructions,
                tools=mcp_tool,
            )
            yield agent


def _extract_usage(result: Any) -> dict[str, int]:
    usage = getattr(result, "usage_details", None)
    if usage is None:
        usage = getattr(result, "usage", None)

    def _get(key: str) -> Any:
        if usage is None:
            return None
        # UsageDetails is a TypedDict (a plain dict at runtime); support objects too.
        if isinstance(usage, Mapping):
            return usage.get(key)
        return getattr(usage, key, None)

    input_tokens = int(_get("input_token_count") or 0)
    output_tokens = int(_get("output_token_count") or 0)
    total_tokens = int(_get("total_token_count") or (input_tokens + output_tokens))
    return {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": total_tokens,
    }


def _usage_from_stream_update(update: Any) -> dict[str, int]:
    """Pull token usage from a streaming update (usage arrives as a 'usage' content item)."""
    for content in getattr(update, "contents", None) or []:
        if getattr(content, "type", None) == "usage":
            ud = getattr(content, "usage_details", None)
            if isinstance(ud, Mapping):
                inp = int(ud.get("input_token_count") or 0)
                out = int(ud.get("output_token_count") or 0)
                return {
                    "input_tokens": inp,
                    "output_tokens": out,
                    "total_tokens": int(ud.get("total_token_count") or (inp + out)),
                }
    return {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}


async def run_once(oid: str, turns: list[dict[str, str]]) -> dict[str, Any]:
    """Non-streaming run. Returns {text, usage}."""
    messages = to_chat_messages(turns)
    async with _agent_for(oid) as agent:
        result = await agent.run(messages, function_invocation_kwargs={"oid": oid})
    return {"text": result.text, "usage": _extract_usage(result)}


async def run_stream(oid: str, turns: list[dict[str, str]]) -> AsyncIterator[dict[str, Any]]:
    """
    Streaming run. Yields dicts:
      {"type": "delta", "text": "..."}         for each text chunk
      {"type": "completed", "text": full, "usage": {...}}  at the end
    """
    messages = to_chat_messages(turns)
    full_text_parts: list[str] = []
    usage = {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}
    async with _agent_for(oid) as agent:
        async for update in agent.run(
            messages, stream=True, function_invocation_kwargs={"oid": oid}
        ):
            chunk = getattr(update, "text", None)
            if chunk:
                full_text_parts.append(chunk)
                yield {"type": "delta", "text": chunk}
            # Usage arrives as a 'usage' content item, once per model response (there can be
            # several across tool calls), so accumulate to get the full request total.
            increment = _usage_from_stream_update(update)
            if increment["total_tokens"]:
                usage["input_tokens"] += increment["input_tokens"]
                usage["output_tokens"] += increment["output_tokens"]
                usage["total_tokens"] += increment["total_tokens"]
    yield {
        "type": "completed",
        "text": "".join(full_text_parts),
        "usage": usage,
    }

"""
OpenAI Responses-compatible HTTP surface for a Microsoft Agent Framework agent, hosted on
Azure Container Apps. APIM Agent GW forwards requests here together with the `x-user-oid`
header, which this app propagates to every model and MCP call.

Endpoints:
  GET  /health              readiness probe
  POST /openai/v1/responses Responses API (stream + non-stream)
"""
from __future__ import annotations

import json
import time
import uuid
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

from agent_runner import run_once, run_stream
from settings import settings

app = FastAPI(title=f"{settings.agent_name} agent")


def _normalize_input(body: dict[str, Any]) -> list[dict[str, str]]:
    """Flatten a Responses-API `input` (string | message array) into {role, text} turns."""
    turns: list[dict[str, str]] = []

    instructions = body.get("instructions")
    if isinstance(instructions, str) and instructions.strip():
        turns.append({"role": "system", "text": instructions})

    raw = body.get("input", body.get("messages", ""))

    if isinstance(raw, str):
        turns.append({"role": "user", "text": raw})
        return turns

    if isinstance(raw, list):
        for item in raw:
            if not isinstance(item, dict):
                turns.append({"role": "user", "text": str(item)})
                continue
            role = item.get("role", "user")
            content = item.get("content", "")
            if isinstance(content, str):
                turns.append({"role": role, "text": content})
            elif isinstance(content, list):
                parts = []
                for part in content:
                    if isinstance(part, dict):
                        parts.append(part.get("text", ""))
                    else:
                        parts.append(str(part))
                turns.append({"role": role, "text": "".join(parts)})
    return turns


def _oid_from(request: Request) -> str:
    return request.headers.get(settings.oid_header_name, "anonymous")


def _response_envelope(text: str, usage: dict[str, int]) -> dict[str, Any]:
    return {
        "id": f"resp_{uuid.uuid4().hex}",
        "object": "response",
        "created_at": int(time.time()),
        "status": "completed",
        "model": settings.model_deployment_name,
        "output": [
            {
                "id": f"msg_{uuid.uuid4().hex}",
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [{"type": "output_text", "text": text, "annotations": []}],
            }
        ],
        "usage": {
            "input_tokens": usage.get("input_tokens", 0),
            "output_tokens": usage.get("output_tokens", 0),
            "total_tokens": usage.get("total_tokens", 0),
        },
    }


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "agent": settings.agent_name}


@app.get("/")
async def root() -> dict[str, str]:
    return {"agent": settings.agent_name, "endpoint": "/openai/v1/responses"}


@app.post("/openai/v1/responses")
async def create_response(request: Request):
    body = await request.json()
    oid = _oid_from(request)
    turns = _normalize_input(body)
    stream = bool(body.get("stream", False))

    if not stream:
        result = await run_once(oid, turns)
        return JSONResponse(_response_envelope(result["text"], result["usage"]))

    async def event_stream():
        response_id = f"resp_{uuid.uuid4().hex}"
        created = {
            "type": "response.created",
            "response": {"id": response_id, "status": "in_progress"},
        }
        yield f"event: response.created\ndata: {json.dumps(created)}\n\n"
        async for evt in run_stream(oid, turns):
            if evt["type"] == "delta":
                payload = {"type": "response.output_text.delta", "delta": evt["text"]}
                yield f"event: response.output_text.delta\ndata: {json.dumps(payload)}\n\n"
            elif evt["type"] == "completed":
                envelope = _response_envelope(evt["text"], evt["usage"])
                payload = {"type": "response.completed", "response": envelope}
                yield f"event: response.completed\ndata: {json.dumps(payload)}\n\n"
        yield "data: [DONE]\n\n"

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )

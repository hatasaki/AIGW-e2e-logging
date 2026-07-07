"""
Flask BFF + UI for the AI gateway demo.

The App Service runs behind Easy Auth (Entra ID). This BFF:
  * reads the signed-in user's identity from Easy Auth headers,
  * forwards the user's access token (X-MS-TOKEN-AAD-ACCESS-TOKEN) as a Bearer token to
    APIM Agent GW, which validates it and derives the oid,
  * proxies the streaming Responses (SSE) back to the browser.

State is kept client-side: the browser sends the full message history on each turn.
"""
from __future__ import annotations

import os

import httpx
from flask import Flask, Response, jsonify, render_template, request, stream_with_context

app = Flask(__name__)

AGENTS: dict[str, dict[str, str]] = {
    "expert": {
        "label": "Azure エキスパート",
        "description": "Microsoft Learn（MCP）を参照して回答する Azure 専門家エージェント",
        "base_url": os.getenv("AGENT_GW_EXPERT_BASE_URL", ""),
    },
    "updates": {
        "label": "Azure アップデート",
        "description": "リリース情報（MCP）を参照する Azure 更新情報エージェント",
        "base_url": os.getenv("AGENT_GW_UPDATES_BASE_URL", ""),
    },
}


def _current_user() -> dict[str, str | None]:
    return {
        "name": request.headers.get("X-MS-CLIENT-PRINCIPAL-NAME"),
        "oid": request.headers.get("X-MS-CLIENT-PRINCIPAL-ID"),
    }


def _access_token() -> str | None:
    return request.headers.get("X-MS-TOKEN-AAD-ACCESS-TOKEN")


@app.get("/")
def index() -> str:
    return render_template("index.html")


@app.get("/api/me")
def me():
    user = _current_user()
    return jsonify({"authenticated": bool(user["name"]), **user})


@app.get("/api/agents")
def agents():
    return jsonify(
        [
            {"id": key, "label": value["label"], "description": value["description"]}
            for key, value in AGENTS.items()
        ]
    )


@app.post("/api/chat")
def chat():
    data = request.get_json(force=True, silent=True) or {}
    agent_id = data.get("agent", "expert")
    messages = data.get("messages", [])

    agent = AGENTS.get(agent_id)
    if not agent or not agent["base_url"]:
        return jsonify({"error": f"unknown agent '{agent_id}'"}), 400

    token = _access_token()
    if not token:
        return jsonify({"error": "not authenticated"}), 401

    payload = {
        "model": agent_id,
        "stream": True,
        "input": [
            {"role": m.get("role", "user"), "content": m.get("content", "")}
            for m in messages
            if m.get("content")
        ],
    }
    url = agent["base_url"].rstrip("/") + "/responses"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }

    def generate():
        with httpx.Client(timeout=httpx.Timeout(None, connect=30.0)) as client:
            with client.stream("POST", url, json=payload, headers=headers) as upstream:
                if upstream.status_code >= 400:
                    body = upstream.read().decode("utf-8", "replace")
                    yield f"event: error\ndata: {body}\n\n".encode()
                    return
                for chunk in upstream.iter_raw():
                    if chunk:
                        yield chunk

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )

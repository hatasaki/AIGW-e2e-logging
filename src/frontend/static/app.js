"use strict";

const state = {
  agents: [],
  activeAgent: null,
  messages: [], // {role: 'user'|'assistant', content: string}
  streaming: false,
};

const el = (id) => document.getElementById(id);

async function loadUser() {
  try {
    const res = await fetch("/api/me");
    const u = await res.json();
    el("user").innerHTML = u.authenticated
      ? `サインイン中: <b>${escapeHtml(u.name)}</b>`
      : "未サインイン";
  } catch {
    el("user").textContent = "";
  }
}

async function loadAgents() {
  const res = await fetch("/api/agents");
  state.agents = await res.json();
  const list = el("agentList");
  list.innerHTML = "";
  state.agents.forEach((a, i) => {
    const btn = document.createElement("button");
    btn.className = "agent" + (i === 0 ? " active" : "");
    btn.dataset.id = a.id;
    btn.innerHTML = `<div class="name">${escapeHtml(a.label)}</div><div class="desc">${escapeHtml(
      a.description
    )}</div>`;
    btn.addEventListener("click", () => selectAgent(a.id));
    list.appendChild(btn);
  });
  state.activeAgent = state.agents.length ? state.agents[0].id : null;
}

function selectAgent(id) {
  state.activeAgent = id;
  document.querySelectorAll(".agent").forEach((b) => {
    b.classList.toggle("active", b.dataset.id === id);
  });
}

function newChat() {
  state.messages = [];
  el("messages").innerHTML = "";
}

function addMessage(role, content) {
  const wrap = document.createElement("div");
  wrap.className = `msg ${role}`;
  const avatar = document.createElement("div");
  avatar.className = "avatar";
  avatar.textContent = role === "user" ? "You" : "AI";
  const bubble = document.createElement("div");
  bubble.className = "bubble";
  bubble.textContent = content;
  wrap.append(avatar, bubble);
  el("messages").appendChild(wrap);
  el("messages").scrollTop = el("messages").scrollHeight;
  return bubble;
}

function escapeHtml(s) {
  return (s || "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
  );
}

async function sendMessage(text) {
  if (!text.trim() || state.streaming || !state.activeAgent) return;
  state.streaming = true;
  el("send").disabled = true;

  state.messages.push({ role: "user", content: text });
  addMessage("user", text);

  const bubble = addMessage("assistant", "");
  bubble.classList.add("thinking");
  bubble.textContent = "考え中…";

  let assistantText = "";
  try {
    const res = await fetch("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ agent: state.activeAgent, messages: state.messages }),
    });

    if (!res.ok || !res.body) {
      const err = await res.text();
      bubble.classList.remove("thinking");
      bubble.classList.add("error");
      bubble.textContent = `エラー: ${err || res.status}`;
      return;
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      // Split complete SSE events on blank lines.
      let sep;
      while ((sep = buffer.indexOf("\n\n")) !== -1) {
        const rawEvent = buffer.slice(0, sep);
        buffer = buffer.slice(sep + 2);
        handleEvent(rawEvent, (delta) => {
          if (bubble.classList.contains("thinking")) {
            bubble.classList.remove("thinking");
            bubble.textContent = "";
          }
          assistantText += delta;
          bubble.textContent = assistantText;
          el("messages").scrollTop = el("messages").scrollHeight;
        }, (usage) => {
          if (usage) {
            const u = document.createElement("div");
            u.className = "usage";
            u.textContent = `tokens: in ${usage.input_tokens ?? 0} / out ${usage.output_tokens ?? 0} / total ${usage.total_tokens ?? 0}`;
            bubble.after(u);
          }
        });
      }
    }
  } catch (e) {
    bubble.classList.remove("thinking");
    bubble.classList.add("error");
    bubble.textContent = `通信エラー: ${e}`;
  } finally {
    if (assistantText) {
      state.messages.push({ role: "assistant", content: assistantText });
    }
    state.streaming = false;
    el("send").disabled = false;
  }
}

function handleEvent(rawEvent, onDelta, onDone) {
  let eventType = "message";
  const dataLines = [];
  rawEvent.split("\n").forEach((line) => {
    if (line.startsWith("event:")) eventType = line.slice(6).trim();
    else if (line.startsWith("data:")) dataLines.push(line.slice(5).trim());
  });
  const data = dataLines.join("\n");
  if (!data || data === "[DONE]") return;

  if (eventType === "response.output_text.delta") {
    try {
      onDelta(JSON.parse(data).delta || "");
    } catch {
      /* ignore */
    }
  } else if (eventType === "response.completed") {
    try {
      onDone(JSON.parse(data).response?.usage);
    } catch {
      /* ignore */
    }
  } else if (eventType === "error") {
    onDelta(`\n[gateway error] ${data}`);
  }
}

function autosize(ta) {
  ta.style.height = "auto";
  ta.style.height = Math.min(ta.scrollHeight, 180) + "px";
}

function init() {
  loadUser();
  loadAgents();

  const input = el("input");
  input.addEventListener("input", () => autosize(input));
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      el("composer").requestSubmit();
    }
  });

  el("composer").addEventListener("submit", (e) => {
    e.preventDefault();
    const text = input.value;
    input.value = "";
    autosize(input);
    sendMessage(text);
  });

  el("newChat").addEventListener("click", newChat);
}

init();

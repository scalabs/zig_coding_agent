import json
from dataclasses import dataclass
from typing import Dict, Generator, List, Optional
from urllib.parse import urlsplit, urlunsplit

import requests
import streamlit as st

st.set_page_config(page_title="Zig Agent Test Client", layout="wide")
st.title("Zig AI Harness Test Client")
st.caption("Debug and test harness behavior: chat routing, tool execution, sessions, streaming, and diagnostics.")

CHAT_STATE_KEY = "chat_messages"
PENDING_CMD_CONFIRMATION_KEY = "pending_cmd_confirmation"

CMD_CONFIRMATION_TAG = "DEBUG_TOOL_CONFIRMATION_REQUIRED"
CONFIRM_MARKER_PREFIX = "LLM_ROUTER_TOOL_CONFIRM "


@dataclass
class ChatMessage:
    role: str
    content: str


def build_headers(api_key: str) -> Dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if api_key.strip():
        headers["x-api-key"] = api_key.strip()
    return headers


def parse_assistant_content(data: Dict) -> str:
    choices = data.get("choices", [])
    if not choices:
        return ""
    message = choices[0].get("message", {})
    return message.get("content", "")


def base_url_from_endpoint(endpoint: str) -> str:
    parsed = urlsplit(endpoint.strip())
    if not parsed.scheme or not parsed.netloc:
        return ""
    return urlunsplit((parsed.scheme, parsed.netloc, "", "", ""))


def stream_probe_lines(response: requests.Response) -> Generator[str, None, None]:
    content_type = (response.headers.get("content-type") or "").lower()

    if "text/event-stream" not in content_type:
        body = response.text
        yield "Server did not return SSE stream (text/event-stream)."
        yield f"Content-Type: {content_type or '<missing>'}"
        if body:
            yield ""
            yield "Raw response body:"
            yield body
        return

    for raw_line in response.iter_lines(decode_unicode=True):
        if not raw_line:
            continue

        line = raw_line.strip()
        if not line.startswith("data:"):
            continue

        payload = line[5:].strip()
        if payload == "[DONE]":
            yield "\n\n[stream done]"
            return

        try:
            event = json.loads(payload)
        except json.JSONDecodeError:
            yield payload
            continue

        choices = event.get("choices", [])
        if not choices:
            yield payload
            continue

        delta = choices[0].get("delta", {})
        token = delta.get("content")
        if token is not None:
            yield token


def ensure_chat_state() -> None:
    if CHAT_STATE_KEY not in st.session_state:
        st.session_state[CHAT_STATE_KEY] = [
            ChatMessage(role="system", content="You are a helpful assistant. Keep replies concise."),
        ]


def chat_state() -> List[ChatMessage]:
    ensure_chat_state()
    return st.session_state[CHAT_STATE_KEY]


def add_chat_message(role: str, content: str) -> None:
    ensure_chat_state()
    st.session_state[CHAT_STATE_KEY].append(ChatMessage(role=role, content=content))


def render_chat(messages: List[ChatMessage]) -> None:
    for msg in messages:
        if msg.role == "system":
            continue
        with st.chat_message(msg.role):
            st.markdown(msg.content)


def parse_cmd_confirmation(text: str) -> Optional[Dict[str, str]]:
    if CMD_CONFIRMATION_TAG not in text:
        return None

    tool: Optional[str] = None
    command: Optional[str] = None
    confirm_token: Optional[str] = None

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith("tool="):
            tool = line[len("tool=") :].strip()
        elif line.startswith("command="):
            command = line[len("command=") :].strip()
        elif line.startswith("confirm_token="):
            confirm_token = line[len("confirm_token=") :].strip()

    if tool and command and confirm_token:
        return {"tool": tool, "command": command, "confirm_token": confirm_token}
    return None


def set_pending_cmd_confirmation(value: Optional[Dict[str, str]]) -> None:
    st.session_state[PENDING_CMD_CONFIRMATION_KEY] = value


with st.sidebar:
    st.header("Connection")
    endpoint = st.text_input(
        "Server endpoint",
        value="http://127.0.0.1:8081/v1/chat/completions",
        help="Your Zig server chat completion endpoint.",
    )
    api_key = st.text_input(
        "Client API key (optional)",
        value="",
        type="password",
        help="Sends x-api-key header if provided.",
    )

    st.header("Request")
    provider = st.text_input("provider", value="ollama")
    model = st.text_input("model", value="auto")
    thinking = st.checkbox(
        "thinking",
        value=False,
        help="Enable model reasoning/thinking tokens. Turn off for faster and shorter replies.",
    )
    temperature = st.slider(
        "temperature",
        min_value=0.0,
        max_value=2.0,
        value=0.7,
        step=0.05,
        help="Lower values are more deterministic. Higher values are more creative.",
    )
    session_id = st.text_input("session_id (optional)", value="")
    tenant_id = st.text_input("tenant_id (optional)", value="")
    max_context_tokens = st.number_input(
        "max_context_tokens (optional)",
        min_value=0,
        value=0,
        step=256,
    )

    st.header("Loop")
    loop_mode = st.selectbox(
        "loop_mode",
        options=["none", "basic", "agent", "react"],
        index=0,
        help="Server-side iterative loop mode usable from any frontend client.",
    )
    loop_until = st.text_input("loop_until", value="DONE")
    loop_max_turns = st.number_input(
        "loop_max_turns",
        min_value=0,
        max_value=128,
        value=0,
        step=1,
        help="0 means disabled and server defaults apply when loop_mode is used.",
    )

    st.header("Tools (debug)")

    import platform as _platform
    _is_windows = _platform.system().lower().startswith("win")
    _shell_tool = "cmd" if _is_windows else "bash"
    CODING_TOOLS = [_shell_tool, "file_read", "file_write", "file_search"]

    auto_tools_for_react = st.checkbox(
        "Auto-attach coding tools when loop_mode=react",
        value=True,
        help=(
            "When enabled and loop_mode is 'react', send the full coding tool set "
            f"({', '.join(CODING_TOOLS)}) with tool_choice=auto. Overrides the manual selection below."
        ),
    )

    selected_tools = st.multiselect(
        "Available tools to send (manual selection)",
        options=["echo", "utc", "cmd", "bash", "file_read", "file_write", "file_search"],
        default=CODING_TOOLS,
        help="Multiple tools can be sent in one request. cmd/bash require server env LLM_ROUTER_TOOL_EXEC_ENABLED=1.",
    )

    tool_choice = st.selectbox(
        "tool_choice",
        options=[
            "auto",
            "none",
            "required",
            "echo",
            "utc",
            "cmd",
            "bash",
            "file_read",
            "file_write",
            "file_search",
        ],
        index=0,
        help="Use auto for prompt-driven tool execution with multiple tools.",
    )

    if auto_tools_for_react and loop_mode == "react":
        selected_tools = CODING_TOOLS
        tool_choice = "auto"
        st.caption(
            f"react mode active — sending tools={CODING_TOOLS} with tool_choice=auto."
        )


def build_payload(
    messages: List[ChatMessage],
    force_stream: bool,
    tool_choice_override: Optional[str] = None,
    tools_override: Optional[List[str]] = None,
) -> Dict:
    payload: Dict = {
        "provider": provider.strip() or "ollama",
        "messages": [{"role": m.role, "content": m.content} for m in messages if m.content.strip()],
        "think": bool(thinking),
        "temperature": float(temperature),
    }

    if model.strip():
        payload["model"] = model.strip()

    if session_id.strip():
        payload["session_id"] = session_id.strip()

    if tenant_id.strip():
        payload["tenant_id"] = tenant_id.strip()

    if max_context_tokens > 0:
        payload["max_context_tokens"] = int(max_context_tokens)

    if loop_mode != "none":
        payload["loop_mode"] = loop_mode
        if loop_until.strip():
            payload["loop_until"] = loop_until.strip()
        if loop_max_turns > 0:
            payload["loop_max_turns"] = int(loop_max_turns)

    tools_to_send = tools_override if tools_override is not None else selected_tools

    if tools_to_send:
        tool_descriptions = {
            "echo": "Return a deterministic echo response for harness debugging.",
            "utc": "Return current UTC timestamp for deterministic tool-path checks.",
            "cmd": "Execute a Windows cmd command from prompt text (debug use).",
            "bash": "Execute a bash command from prompt text (debug use).",
            "file_read": "Read a relative file path and return its content (debug use).",
            "file_write": "Write a relative file path from a fenced code block (debug use).",
            "file_search": "Search a substring under a relative directory (debug use).",
        }
        payload["tools"] = [
            {"name": tool_name, "description": tool_descriptions.get(tool_name, "debug tool")}
            for tool_name in tools_to_send
        ]
        if tool_choice_override is not None:
            payload["tool_choice"] = tool_choice_override
        elif tool_choice != "none":
            payload["tool_choice"] = tool_choice

    if force_stream:
        payload["stream"] = True

    return payload


def request_timeout_seconds(force_stream: bool) -> int:
    timeout = 120 if force_stream else 60

    if loop_mode != "none":
        timeout = max(timeout, 240)

    if ("cmd" in selected_tools) or ("bash" in selected_tools):
        timeout = max(timeout, 120)

    return timeout


def send_chat_request(
    force_stream: bool,
    tool_choice_override: Optional[str] = None,
    tools_override: Optional[List[str]] = None,
) -> Optional[Dict]:
    if not endpoint.strip():
        st.error("Endpoint is required.")
        return None

    payload = build_payload(
        chat_state(),
        force_stream=force_stream,
        tool_choice_override=tool_choice_override,
        tools_override=tools_override,
    )
    st.code(json.dumps(payload, indent=2), language="json")

    try:
        timeout_sec = request_timeout_seconds(force_stream=force_stream)
        resp = requests.post(
            endpoint.strip(),
            headers=build_headers(api_key),
            json=payload,
            timeout=timeout_sec,
            stream=force_stream,
        )
    except requests.Timeout:
        st.error(
            "Request timed out. Increase timeout by disabling loop mode, reducing loop_max_turns, "
            "or simplifying tool usage in the prompt."
        )
        return None
    except requests.RequestException as exc:
        st.error(f"Request failed: {exc}")
        return None

    st.write(f"HTTP {resp.status_code}")

    if force_stream:
        if resp.status_code >= 400:
            st.error("Server returned an error status during stream.")
            st.code(resp.text)
            return None

        with st.chat_message("assistant"):
            streamed_text = st.write_stream(stream_probe_lines(resp))
        assistant_text = str(streamed_text)
        add_chat_message("assistant", assistant_text)
        set_pending_cmd_confirmation(parse_cmd_confirmation(assistant_text))
        return None

    try:
        data = resp.json()
    except ValueError:
        st.error("Response is not valid JSON.")
        st.code(resp.text)
        return None

    st.json(data)
    assistant = parse_assistant_content(data)
    if assistant:
        with st.chat_message("assistant"):
            st.markdown(assistant)
        add_chat_message("assistant", assistant)
        set_pending_cmd_confirmation(parse_cmd_confirmation(assistant))
    return data


st.subheader("Chat")
ensure_chat_state()

chat_controls_col1, chat_controls_col2, chat_controls_col3 = st.columns(3)
with chat_controls_col1:
    if st.button("Clear chat", use_container_width=True):
        st.session_state.pop(CHAT_STATE_KEY, None)
        ensure_chat_state()
with chat_controls_col2:
    if st.button("Add demo prompt", use_container_width=True):
        add_chat_message(
            "user",
            "write a python script to add two numbers then execute and print it's output",
        )
with chat_controls_col3:
    stream_mode = st.checkbox("Stream responses (SSE)", value=False)

render_chat(chat_state())

user_input = st.chat_input("Type a message and press Enter…")
if user_input and user_input.strip():
    add_chat_message("user", user_input.strip())
    if stream_mode:
        if loop_mode != "none":
            st.info(
                "Loop progress visibility is controlled by server setting "
                "LLM_ROUTER_LOOP_STREAM_PROGRESS_ENABLED (default: enabled)."
            )
        send_chat_request(force_stream=True)
    else:
        send_chat_request(force_stream=False)

pending_cmd = st.session_state.get(PENDING_CMD_CONFIRMATION_KEY)
if pending_cmd:
    tool = pending_cmd["tool"]
    st.warning(f"Backend requested confirmation to execute `{tool}`.")
    st.code(pending_cmd["command"])
    if st.button("Confirm command execution", use_container_width=True):
        confirm_prompt = (
            f"{pending_cmd['command']}\n{CONFIRM_MARKER_PREFIX}{pending_cmd['confirm_token']}"
        )
        add_chat_message("user", confirm_prompt)

        tools_override = selected_tools if isinstance(selected_tools, list) else []
        if tool not in tools_override:
            tools_override = tools_override + [tool]

        # Force the tool choice so the backend executes immediately after confirmation.
        set_pending_cmd_confirmation(None)
        send_chat_request(
            force_stream=stream_mode,
            tool_choice_override=tool,
            tools_override=tools_override,
        )


st.subheader("Diagnostics")
diag_col1, diag_col2, diag_col3 = st.columns(3)
health_clicked = diag_col1.button("GET /health", use_container_width=True)
metrics_clicked = diag_col2.button("GET /metrics", use_container_width=True)
providers_clicked = diag_col3.button("GET /diagnostics/providers", use_container_width=True)

if health_clicked or metrics_clicked or providers_clicked:
    base_url = base_url_from_endpoint(endpoint)
    if not base_url:
        st.error("Could not infer base URL from endpoint.")
    else:
        if health_clicked:
            target_path = "/health"
        elif metrics_clicked:
            target_path = "/metrics"
        else:
            target_path = "/diagnostics/providers"

        target_url = f"{base_url}{target_path}"
        st.code(target_url)

        try:
            resp = requests.get(
                target_url,
                headers=build_headers(api_key),
                timeout=30,
            )
        except requests.RequestException as exc:
            st.error(f"Diagnostics request failed: {exc}")
        else:
            st.write(f"HTTP {resp.status_code}")
            try:
                st.json(resp.json())
            except ValueError:
                st.code(resp.text)


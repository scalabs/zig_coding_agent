# Zig Coding Agent

OpenAI-compatible Zig server for local model routing. The current default path
uses Ollama and exposes `POST /v1/chat/completions` for chat-style requests.

## Requirements

- Zig `0.15.2`
- Ollama running locally
- A local model available in Ollama, default `qwen:7b`

## Project Layout

- `src/main.zig`: minimal CLI entrypoint
- `src/root.zig`: public module surface and re-exports
- `src/backend/`: request parsing, provider dispatch, shared API errors
- `src/core/`: HTTP server, routing, request parsing, and response formatting
- `src/providers/`: provider-specific implementation(s)

## Configuration

Use environment variables to configure the server:

- `LLM_ROUTER_HOST`: default `127.0.0.1`
- `LLM_ROUTER_PORT`: default `8081`
- `LLM_ROUTER_DEBUG`: default `0`
- `LLM_ROUTER_PROVIDER`: default `ollama`
- `OLLAMA_BASE_URL`: default `http://127.0.0.1:11434`
- `OLLAMA_MODEL`: default `qwen:7b`

You can also override the default provider at startup:

```bash
zig build run -- --provider ollama
```

Supported provider values are `ollama`, `qwen`, and `ollama_qwen`.

## Build And Run

```bash
zig build
zig build run
zig build check
```

Command summary:

- `zig build`: build and install to `zig-out/` (default step)
- `zig build run -- [args]`: run the server executable
- `zig build check`: compile app and built-in test modules without running
- `zig build test ...`: run tests with selectable targets

## Testing

Run every built-in test target:

```bash
zig build test -Dtest-target=all
```

Run only the package/module tests exported through [src/root.zig](src/root.zig):

```bash
zig build test -Dtest-target=root
```

Run only the focused `types` tests:

```bash
zig build test -Dtest-target=types
```

Run tests from one specific file:

```bash
zig build test -Dtest-target=file "-Dtest-file=src/types.zig"
```

Filter tests by name across any target:

```bash
zig build test -Dtest-target=all -Dtest-filter=normalizeProviderName
```

Manual integration check against the local router:

1. Start the server:

```bash
zig build run
```

2. In another terminal, send an OpenAI-compatible request:

```bash
curl -s http://127.0.0.1:8081/v1/chat/completions \
	-H 'Content-Type: application/json' \
	-d '{"messages":[{"role":"user","content":"Say hello from local Qwen"}]}'
```

Optional direct Ollama check:

```bash
curl -s http://127.0.0.1:11434/api/chat \
	-H 'Content-Type: application/json' \
	-d '{"model":"qwen:7b","messages":[{"role":"user","content":"Say hello from Zig"}],"stream":false}'
```

## Request Shape

The server accepts the OpenAI-style chat-completions payload used by the
router. Requests may include a `provider` field, but if they do not, the
configured default provider is used instead.

Example request:

```bash
curl -s http://127.0.0.1:8081/v1/chat/completions \
	-H 'Content-Type: application/json' \
	-d '{"messages":[{"role":"user","content":"Say hello from local Qwen"}]}'
```

Legacy provider values are still accepted: `ollama`, `qwen`, and
`ollama_qwen`.

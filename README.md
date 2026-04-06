# Ollama Qwen Demo

Small standalone Zig server for demos. It exposes an OpenAI-style
`POST /v1/chat/completions` endpoint and forwards requests only to a local
Ollama Qwen model.

This folder is isolated from the main multi-provider router.

## Requirements

- Zig `0.15.2`
- Ollama running locally
- A local Qwen model available in Ollama, default `qwen:7b`

## Environment

Use `.ollama-qwen-env.example` as a template.

- `LLM_ROUTER_HOST`: default `127.0.0.1`
- `LLM_ROUTER_PORT`: default `8081`
- `LLM_ROUTER_DEBUG`: default `0`
- `OLLAMA_BASE_URL`: default `http://127.0.0.1:11434`
- `OLLAMA_MODEL`: default `qwen:7b`

## Build And Run

```bash
zig build check
zig build test
zig build run
```

## Testing

Run unit tests:

```bash
zig build test
```

Manual integration test against the local router:

1. Start the router:

```bash
zig build run
```

2. In another terminal, call the OpenAI-compatible endpoint:

```bash
curl -s http://127.0.0.1:8081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello from local Qwen"}]}'
```

Optional direct Ollama check (bypasses this router):

```bash
curl -s http://127.0.0.1:11434/api/chat \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen:7b","messages":[{"role":"user","content":"Say hello from Zig"}],"stream":false}'
```

## Demo Request

```bash
curl -s http://127.0.0.1:8081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello from local Qwen"}]}'
```

You can also keep the old request shape and set provider to `ollama`, `qwen`,
or `ollama_qwen`.

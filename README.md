# Zig LLM Router

A working Zig 0.15.2 prototype that exposes an OpenAI-style
`POST /v1/chat/completions` API and routes requests to different providers
behind one normalized response shape. It is functional end to end, but it is
not production-ready.

Current implemented providers:

- Local Qwen via Ollama
- OpenRouter
- AWS Bedrock

## Status

Completed through Phase 11:

- OpenAI-style chat completions endpoint
- Request validation and structured 400 errors
- Provider selection and environment-based config
- Normalized success and error responses
- Safer request/body reading
- Full multi-message chat forwarding
- Real OpenRouter adapter
- Real Bedrock adapter with AWS SigV4 signing
- Debug logging for request flow
- Unit tests for request parsing and provider selection

This project should be presented as a working prototype or functional demo, not
as a production-hardened service.

## Architecture

- `src/main.zig`: HTTP server, request parsing, normalization
- `src/router.zig`: provider dispatch
- `src/types.zig`: shared request/response types
- `src/providers/ollama_qwen.zig`: local Ollama provider
- `src/providers/openrouter.zig`: real OpenRouter provider
- `src/providers/bedrock.zig`: Bedrock provider
- `src/config.zig`: environment-backed config

## Requirements

- Zig `0.15.2`
- Ollama running locally for the Qwen path
- Optional OpenRouter account and API key for the OpenRouter path

## Environment

Supported environment variables:

- `LLM_ROUTER_HOST`: server bind host, default `127.0.0.1`
- `LLM_ROUTER_PORT`: server bind port, default `8080`
- `LLM_ROUTER_DEBUG`: enable debug logs when non-empty and not `0`/`false`/`no`
- `LLM_ROUTER_DEFAULT_PROVIDER`: `ollama_qwen`, `openrouter`, or `bedrock`
- `OLLAMA_BASE_URL`: default `http://127.0.0.1:11434`
- `OLLAMA_MODEL`: default `qwen:7b`
- `OPENROUTER_BASE_URL`: default `https://openrouter.ai/api/v1`
- `OPENROUTER_API_KEY`: OpenRouter API key
- `OPENROUTER_HTTP_REFERER`: optional app/site URL for OpenRouter attribution
- `OPENROUTER_APP_NAME`: optional app name for OpenRouter attribution
- `OPENROUTER_MODEL`: default `openrouter/auto`
- `BEDROCK_RUNTIME_BASE_URL`: optional override for the Bedrock runtime endpoint
- `BEDROCK_REGION`: default `us-east-1`, falls back to `AWS_REGION` or `AWS_DEFAULT_REGION`
- `BEDROCK_ACCESS_KEY_ID`: optional override for AWS access key id, falls back to `AWS_ACCESS_KEY_ID`
- `BEDROCK_SECRET_ACCESS_KEY`: optional override for AWS secret access key, falls back to `AWS_SECRET_ACCESS_KEY`
- `BEDROCK_SESSION_TOKEN`: optional override for AWS session token, falls back to `AWS_SESSION_TOKEN`
- `BEDROCK_MODEL`: default `amazon.nova-micro-v1:0`

Use `.llm-router-env.example` as a template. Do not commit real secrets.

## Build And Run

Compile both executables:

```bash
zig build check
```

Run the API server:

```bash
zig build run
```

Run the direct Ollama smoke test:

```bash
zig build ollama-test
```

Run unit tests:

```bash
zig build test
```

You can override the port as usual:

```bash
LLM_ROUTER_PORT=8085 zig build run
```

Enable debug logging:

```bash
LLM_ROUTER_DEBUG=1 zig build run
```

## Local Qwen Test

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello from Qwen"}]}'
```

## OpenRouter Test

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"provider":"openrouter","model":"openrouter/auto","messages":[{"role":"user","content":"Say hello from OpenRouter"}]}'
```

## Bedrock Test

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"provider":"bedrock","model":"amazon.nova-micro-v1:0","messages":[{"role":"user","content":"Say hello from Bedrock"}]}'
```

## Notes

- Multi-turn chat context is now forwarded to Ollama and OpenRouter providers.
- Bedrock now supports live AWS SigV4-signed Converse requests. Model access and
  availability still depend on your AWS account and region.
- `zig build test` covers provider alias parsing, request validation basics, and
  message/prompt extraction.
- The server is intentionally small and prototype-oriented. It is not a full
  HTTP framework or a production-ready gateway.
- Keep secrets in `~/.llm-router-env` or another private env source, not in the
  repo.

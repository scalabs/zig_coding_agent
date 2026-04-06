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

You can run an in-project prompt loop (no external shell loop required):

```bash
zig build run -- --prompt "Draft a short API summary and end with DONE" --provider ollama
```

Optional loop controls:

- `--until <marker>`: completion marker to stop on (default `DONE`)
- `--max-turns <n>`: hard stop to prevent infinite loops (default `8`)

Example with explicit controls:

```bash
zig build run -- --prompt "Plan a migration and end with FINISHED" --provider ollama --until FINISHED --max-turns 12
```

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

2. In another terminal, send an OpenAI-compatible request without a `provider`
   field. This verifies the router, request parsing, default provider lookup,
   and the Ollama round-trip:

   ```bash
   curl -s http://127.0.0.1:8081/v1/chat/completions \
     -H 'Content-Type: application/json' \
     -d '{"messages":[{"role":"user","content":"Say hello from local Qwen"}]}'
   ```

3. If you want to confirm provider selection explicitly, repeat the request
   with `provider` set to one of the supported aliases:

   ```bash
   curl -s http://127.0.0.1:8081/v1/chat/completions \
     -H 'Content-Type: application/json' \
     -d '{"provider":"ollama","messages":[{"role":"user","content":"Say hello from local Qwen"}]}'
   ```

Optional dependency sanity check for Ollama itself:

```bash
curl -s http://127.0.0.1:11434/api/chat \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen:7b","messages":[{"role":"user","content":"Say hello from Zig"}],"stream":false}'
```

## Prompt Loop

The server returns one completion per request. If you want to keep iterating on
the same task until the model says it is finished, do that from the client.

Bash example that keeps the conversation going until the assistant says
`DONE` or the model finishes normally:

```bash
messages='[{"role":"user","content":"Work through this task one step at a time. End with DONE when finished: <your prompt>"}]'

while true; do
  body=$(printf '{"messages":%s}' "$messages")
  response=$(curl -s http://127.0.0.1:8081/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d "$body")

  assistant=$(printf '%s' "$response" | jq -r '.choices[0].message.content')
  finish_reason=$(printf '%s' "$response" | jq -r '.choices[0].finish_reason')

  printf '%s\n' "$assistant"

  messages=$(printf '%s' "$messages" | jq --arg content "$assistant" \
    '. + [{role:"assistant", content:$content}]')

  if printf '%s' "$assistant" | grep -Eq '(^|[[:space:]])DONE([[:space:]]|$)' || [ "$finish_reason" = "stop" ]; then
    break
  fi

  messages=$(printf '%s' "$messages" | jq '. + [{role:"user", content:"Continue."}]')
done
```

If you only want the model to generate a single complete response, the normal
`POST /v1/chat/completions` call with `stream: false` is already enough.

## External Prompt Looping (Bash Example)

If you prefer to implement looping outside the agent (for example, in a bash
script or Python client), the above bash example shows a pattern you can follow.
The built-in `--prompt` feature is recommended for simplicity.

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

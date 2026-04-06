# Configuration Reference (config.json)

`gobot` uses a JSON configuration file (typically `config.json`) to manage agent behavior, provider credentials, and integration settings.

## File Location

By default, `gobot` looks for `config.json` in:
- **Windows:** `%USERPROFILE%\.gobot\config.json`
- **Linux/macOS:** `~/.gobot/config.json`

You can also specify a custom storage root during initialization using `gobot init --root <path>`, which will influence where the agent looks for its environment.

---

## Configuration Structure

### 1. Agents (`agents`)

Controls default model parameters and specialist overrides.

| Field | Type | Description |
|-------|------|-------------|
| `defaults.model` | string | The default LLM model (e.g., `gemini-1.5-flash`). |
| `defaults.provider` | string | The default provider (`gemini`, `anthropic`, `openai`). |
| `defaults.maxTokens` | int | Maximum output tokens per turn (0 = model default). |
| `defaults.maxToolIterations` | int | Maximum consecutive tool calls allowed in one turn. |
| `defaults.maxToolResultBytes` | int | Maximum size of a tool result in bytes (default 32KB). |
| `defaults.lockTimeoutSeconds` | int | Seconds to wait for a session lock (default 120s). |
| `defaults.memoryWindow` | int | Number of recent messages kept in active context (default 50). |
| `specialists` | object | Map of specialist types (e.g., `architect`) to model/provider overrides. |

#### Context Pruning (`contextPruning`)

| Field | Type | Description |
|-------|------|-------------|
| `ttl` | string | Time-to-live for old context messages (e.g., `720h`). |
| `keepLastAssistants` | int | Number of assistant replies to preserve during pruning. |

#### Compaction (`compaction`)

| Field | Type | Description |
|-------|------|-------------|
| `strategy` | string | Compaction strategy (`none`, `memoryFlush`, `summarization`). |
| `memoryFlush.prompt` | string | Custom prompt for flushing memory to long-term storage. |
| `summarization.enabled` | bool | Enable automatic context summarization. |
| `summarization.thresholdPercent` | float | Percent of context used before triggering summary (e.g., `0.7`). |

---

### 2. Channels (`channels`)

Configuration for communication interfaces.

#### Telegram (`telegram`)

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Enable the Telegram bot interface. |
| `token` | string | Telegram Bot API token (can also be set via `TELEGRAM_BOT_TOKEN` env). |
| `allowFrom` | array[string] | Whitelist of numeric Telegram Chat/User IDs allowed to interact. |
| `hitl` | bool | Enable Human-in-the-Loop approval for sensitive tools. |

---

### 3. Providers (`providers`)

Credentials and endpoints for LLM providers.

| Section | Field | Description |
|---------|-------|-------------|
| `gemini` | `apiKey` | Google Gemini API Key. |
| `anthropic` | `apiKey` | Anthropic API Key. |
| `openai` | `apiKey` | OpenAI API Key. |
| `openai` | `baseUrl` | Custom endpoint for OpenAI-compatible APIs (e.g., LM Studio). |
| `google` | `apiKey` | Google Custom Search API Key. |
| `google` | `customCx` | Google Custom Search Engine ID (CX). |

---

### 4. Tools (`tools`)

Settings for agent-native tools.

#### Shell Execution (`exec`)

| Field | Type | Description |
|-------|------|-------------|
| `timeout` | int | Timeout in seconds for shell commands (default 120s). |

#### MCP Servers (`mcpServers`)

Map of server names to their command configurations.

| Field | Type | Description |
|-------|------|-------------|
| `command` | string | Executable to run (e.g., `node`, `python`). |
| `args` | array[string] | CLI arguments for the server. |
| `env` | object | Map of environment variables (empty values resolved from DPAPI). |

---

### 5. Strategic Edition (`strategic_edition`)

Mandates and global environment settings.

| Field | Type | Description |
|-------|------|-------------|
| `user_email` | string | Primary email for Google Workspace tools (Gmail/Calendar). |
| `storage_root` | string | Directory for databases, logs, and secrets (default `D:\Gobot_Storage`). |
| `mandate` | string | The core "North Star" mandate for the agent. |
| `idempotencyTTL` | string | TTL for side-effect tracking keys (default `24h`). |

#### Observability (`observability`)

| Field | Type | Description |
|-------|------|-------------|
| `service_name` | string | Name of the service for OTLP traces. |
| `otlp_endpoint` | string | OTLP collector endpoint. |
| `sampling_rate` | float | Fraction of traces to capture (e.g., `1.0` for all). |

---

### 6. Gateway (`gateway`)

Internal HTTP server settings.

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Enable the HTTP gateway. |
| `host` | string | Host to bind to (e.g., `127.0.0.1`). |
| `port` | int | Port to listen on (default `8080`). |

---

### 7. Resilience (`resilience`)

Circuit breaker configurations.

| Field | Type | Description |
|-------|------|-------------|
| `circuit_breakers` | object | Map of breaker names (e.g., `gemini`) to settings. |
| `...max_failures` | int | Failures before opening the breaker. |
| `...window_seconds` | int | Rolling window for failure counting. |
| `...timeout_seconds` | int | Time before attempting to close the breaker. |

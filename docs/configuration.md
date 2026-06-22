# Configuration Reference (config.json)

`gobot` uses a JSON configuration file (typically `config.json`) to manage agent behavior, provider credentials, and integration settings.

## File Location

By default, `gobot` looks for `config.json` in:
- **Windows:** `%USERPROFILE%\.gobot\config.json`
- **Linux/macOS:** `~/.gobot/config.json`

## Path Resolution

gobot resolves two locations: the **config file** and the **data root** (databases, logs, secrets).
Set a single `GOBOT_HOME` and both live under it, with nothing to keep in sync. `gobot init` prints
the resolved `config:` and `data:` paths.

**Config file path** (`DefaultConfigPath`):

| Precedence | Source | Resolved path |
|---|---|---|
| 1 | `GOBOT_HOME` set | `$GOBOT_HOME/.gobot/config.json` |
| 2 | default | `~/.gobot/config.json` (Windows: `%USERPROFILE%\.gobot\config.json`) |

**Data root** (`StorageRoot`):

| Precedence | Source | Resolved path |
|---|---|---|
| 1 | `strategic_edition.storage_root` in config.json | that value |
| 2 | `GOBOT_STORAGE` env set | that value (explicit override) |
| 3 | `GOBOT_HOME` set (and `GOBOT_STORAGE` unset) | `$GOBOT_HOME/data` |
| 4 | neither env var set | `~/gobot_data` |

`GOBOT_STORAGE` always wins over the `GOBOT_HOME`-derived default, so an existing install that sets
`GOBOT_STORAGE` never relocates its data. An install that sets `GOBOT_HOME` but not `GOBOT_STORAGE`
resolves data under `$GOBOT_HOME/data`; to keep data at the legacy `~/gobot_data`, set
`GOBOT_STORAGE` explicitly. You can also override the data root for a one-shot `gobot init` with
`--root <path>` (which sets `GOBOT_STORAGE` for that invocation).

---

## Reformatting config.json

`gobot` has a canonical on-disk form for `config.json`: pretty-printed JSON with 4-space indentation. Two commands manage it:

- `gobot config reformat` rewrites `config.json` in that canonical 4-space-indented form. If no path is given, it operates on the default `config.json` (see [File Location](#file-location)).
- `gobot config reformat --check` does not rewrite anything. It only reports whether the file already matches the canonical form (similar to `gofmt -l`). It prints a confirmation when the file matches, and exits non-zero with a message when it does not.

A "not correctly formatted" result is a style-only signal, not a validity error. The check compares the file's exact bytes against gobot's freshly re-marshalled form, so a config that differs only in key ordering, indentation, or whitespace is reported as not correctly formatted even though it is still valid and is loaded normally at runtime. To bring a file into canonical form, run `gobot config reformat` (the same command without `--check`).

This formatting check is opt-in. It is not run at application startup, in `gobot doctor`, or in preflight diagnostics; it runs only when you invoke `gobot config reformat --check` explicitly. To check whether a config is semantically valid (rather than canonically formatted), use `gobot config validate`.

### Key naming convention (camelCase) and legacy aliases

Config keys use **camelCase** (e.g. `maxTokens`, `dashboardEnabled`, `circuitBreakers`). Older releases mixed camelCase and `snake_case` in the same file; those `snake_case` spellings are now **deprecated aliases** that still load during a deprecation window.

- On load, a deprecated key (e.g. `auth_token`, `max_size_mb`, `circuit_breakers`, `session_token_budget`) is accepted and a one-time `WARN` names the deprecated key and its canonical replacement. If both the deprecated and canonical key are present, the **canonical key wins** and the deprecated one is ignored.
- `gobot config reformat` rewrites a legacy file to canonical-only form, so it doubles as the one-step migration tool: run it once and the warnings stop.
- The aliases are temporary. After the deprecation window they will be removed, after which only the canonical camelCase keys load. Migrate with `gobot config reformat` now to avoid a future break.

> The `strategic_edition` block (its key and nested fields such as `storage_root`, `user_email`) is intentionally **not** part of this convention change yet; it is migrated separately (C-327). Its keys are documented in their existing form below.

---

## Configuration Structure

### 1. Agents (`agents`)

Controls default model parameters and specialist overrides.

| Field | Type | Description |
|-------|------|-------------|
| `defaults.model` | string | Default LLM model (e.g., `gemini-2.5-flash`). |
| `defaults.provider` | string | Default provider (`gemini`, `anthropic`, `openai`, `openrouter`). Use `auto` to let gobot select. |
| `defaults.maxTokens` | int | Maximum output tokens per turn (0 = model default). |
| `defaults.maxToolIterations` | int | Maximum consecutive tool calls allowed in one turn. |
| `defaults.maxToolResultBytes` | int | Maximum size of a tool result in bytes (default 32KB; 0 = no limit). |
| `defaults.lockTimeoutSeconds` | int | Seconds to wait for a session lock before rejecting a request (default 120). |
| `defaults.memoryWindow` | int | Number of recent messages kept in active context (default 50). |
| `specialists` | object | Map of specialist types (e.g., `architect`, `researcher`) to `model`/`provider` overrides. |

#### Context Pruning (`defaults.contextPruning`)

| Field | Type | Description |
|-------|------|-------------|
| `ttl` | string | Time-to-live for old context messages (e.g., `"720h"`). Empty = no TTL pruning. |
| `keepLastAssistants` | int | Number of most-recent assistant replies to preserve during pruning. |

#### Compaction (`defaults.compaction`)

| Field | Type | Description |
|-------|------|-------------|
| `strategy` | string | Compaction strategy: `""` (none), `memoryFlush`, or `summarization`. |
| `memoryFlush.prompt` | string | Custom prompt used when flushing context to long-term memory. |
| `memoryFlush.ttl` | string | TTL for flushed memory entries (e.g., `"2160h"` for 90 days). Empty = no cleanup. |
| `memoryFlush.globalTTL` | string | TTL applied to global-namespace memory entries. |
| `memoryFlush.globalNamespacePatterns` | array[string] | Namespace patterns treated as global during flush. |
| `summarization.enabled` | bool | Enable automatic context summarization before pruning. |
| `summarization.model` | string | Model to use for summarization (defaults to the agent's model). |
| `summarization.threshold` | float | Fraction of context budget used before triggering summarization (default `0.7`). |

---

### 2. Channels (`channels`)

#### Telegram (`channels.telegram`)

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Enable the Telegram bot interface. |
| `token` | string | Telegram Bot API token. Falls back to DPAPI key `telegram_token` or `TELEGRAM_BOT_TOKEN` env. |
| `allowFrom` | array[string] | Whitelist of numeric Telegram Chat/User IDs allowed to interact. On startup, every ID here is auto-promoted into the access-control database (idempotent), so single-user setups need no separate `gobot authorize` step. `allowFrom` is the network-layer drop list; the database backs conversation history and per-user state. Use `gobot authorize <chat-id>` only to grant an ID that is *not* in `allowFrom`. |
| `hitl` | bool | Enable Human-in-the-Loop approval for side-effecting tools (sending email, creating calendar events, etc.). |

---

### 3. Providers (`providers`)

Credentials and endpoints for LLM providers. All API keys fall back to the DPAPI secrets store, then to environment variables. For detailed information on managing sensitive credentials, see the [Security & Secrets](security.md) documentation.

| Section | Field | Description | Env fallback |
|---------|-------|-------------|--------------|
| `gemini` | `apiKey` | Google Gemini API key. | `GEMINI_API_KEY` |
| `anthropic` | `apiKey` | Anthropic API key. | `ANTHROPIC_API_KEY` |
| `openai` | `apiKey` | OpenAI API key. | `OPENAI_API_KEY` |
| `openai` | `baseUrl` | Custom endpoint for OpenAI-compatible APIs (e.g., LM Studio). | `OPENAI_BASE_URL` |
| `openrouter` | `apiKey` | OpenRouter API key. | `OPENROUTER_API_KEY` |
| `openrouter` | `baseUrl` | OpenRouter endpoint (defaults to `https://openrouter.ai/api/v1`). | `OPENROUTER_BASE_URL` |
| `google` | `apiKey` | Google Custom Search API key (enables `google_search` tool). | `GOOGLE_API_KEY` |
| `google` | `customCx` | Google Custom Search Engine ID. | `GOOGLE_CX` |

---

### 4. Tools (`tools`)

#### Shell Execution (`tools.exec`)

| Field | Type | Description |
|-------|------|-------------|
| `timeout` | int | Timeout in seconds for `shell_exec` commands (default 120). |

#### High-Risk Tools (`tools.highRisk`)

| Field | Type | Description |
|-------|------|-------------|
| `highRisk` | array[string] | Tool names that require Human-in-the-Loop approval regardless of the `hitl` channel setting. _(legacy alias: `high_risk`)_ |

#### MCP Servers (`tools.mcpServers`)

Map of server names to their command configurations.

| Field | Type | Description |
|-------|------|-------------|
| `command` | string | Executable to launch (e.g., path to `npx.cmd`). |
| `args` | array[string] | CLI arguments passed to the server. |
| `env` | object | Environment variables for the server process. Empty string values are resolved from DPAPI under key `mcp_env_{serverName}_{varName}`. |

---

### 4a. Browser Automation (`browser`)

Settings for the `chromedp`-based headless browser tools.

| Field | Type | Description |
|-------|------|-------------|
| `debugPort` | int | Port to attach to an existing Chrome instance (e.g., `9222`). `0` = disabled. _(legacy alias: `debug_port`)_ |
| `headless` | bool | If `true`, launches a new headless Chrome instance for browser tools. |

---

### 5. Strategic Edition (`strategic_edition`)

Settings for advanced agent features, including Google Workspace integration. For instructions on setting up Google credentials, see the [Google Cloud Setup Guide](google-setup.md).

| Field | Type | Description |
|-------|------|-------------|
| `user_email` | string | Primary email address for Google Workspace tools. Required to enable Gmail and Calendar tools. |
| `user_chat_id` | int64 | Telegram chat ID used for direct-message notifications. |
| `storage_root` | string | Root directory for databases, logs, and secrets. When empty, falls back to `GOBOT_STORAGE`, then `$GOBOT_HOME/data`, then `~/gobot_data` (see [Path Resolution](#path-resolution)). |
| `max_tool_iterations` | int | Override for maximum tool iterations (overrides `agents.defaults.maxToolIterations`). |
| `idempotencyTTL` | string | TTL for side-effect idempotency keys (default `"24h"`). |
| `vector_search_enabled` | bool | Enable semantic/hybrid memory search (requires embedding provider). When `true`, gobot also seeds a default recurring `index_workspace` cron job so the workspace vector index is refreshed automatically (see `vector_index_interval`). |
| `vector_index_interval` | string | Interval between automatic workspace re-indexing runs when `vector_search_enabled` is `true` (default `"24h"`). Parsed as a Go duration (e.g. `"6h"`, `"30m"`). Invalid values log a warning and fall back to the default. Ignored when vector search is disabled. |
| `multi_user_enabled` | bool | Enable per-user workspace isolation. When true, workspaces are scoped to `{storage_root}/workspace/users/{userID}/`. |
| `gmail_readonly` | bool | When `true`, registers `search_gmail` and `read_gmail` tools in addition to `send_email`. Set to `false` (default) to allow outbound notifications only. |
| `google_scopes` | []string | OAuth2 scopes requested by `gobot reauth`. Omit to use the defaults: `https://mail.google.com/`, `https://www.googleapis.com/auth/calendar`, `https://www.googleapis.com/auth/tasks`. See [Google Cloud Setup Guide](google-setup.md#customizing-oauth-scopes). |
| `templates_path` | string | Directory containing custom email templates (`email.html`). |
| `custom_css_path` | string | Path to a CSS file that overrides default email styling. |
| `policy_file_path` | string | Path to a tool policy file for fine-grained allow/deny rules. |
| `embedding_model` | string | Embedding model name for vector search (default `"text-embedding-004"`). |

#### Routing (`strategic_edition.routing`)

Enables a manager agent to route incoming messages to specialist sub-agents.

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Enable the routing layer. |
| `manager_model` | string | Model used by the routing manager agent. |
| `manager_provider` | string | Provider for the routing manager (defaults to `agents.defaults.provider`). |

#### Observability (`strategic_edition.observability`)

| Field | Type | Description |
|-------|------|-------------|
| `service_name` | string | Service name reported in OTLP traces. |
| `service_version` | string | Service version reported in OTLP traces. |
| `otlp_endpoint` | string | OTLP collector endpoint. Setting this enables telemetry. |
| `sampling_rate` | float | Fraction of traces to capture (`1.0` = all, `0.0` = none). |
| `dev_mode` | bool | Enable development-mode tracing (verbose, local-only). |

---

### 6. Gateway (`gateway`)

Internal HTTP server for the management dashboard and webhook ingress.

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Enable the HTTP gateway. |
| `dashboardEnabled` | bool | Enable the web management dashboard on the gateway. _(legacy alias: `dashboard_enabled`)_ |
| `authToken` | string | Bearer token required for authenticated gateway endpoints. _(legacy alias: `auth_token`)_ |
| `host` | string | Host to bind to (default `"127.0.0.1"`). |
| `port` | int | Port to listen on (default `18790`). |
| `webAddr` | string | Override full bind address (e.g., `"0.0.0.0:9000"`). Takes precedence over `host`/`port`. _(legacy alias: `web_addr`)_ |

---

### 7. Resilience (`resilience`)

Per-provider circuit breaker configuration.

| Field | Type | Description |
|-------|------|-------------|
| `circuitBreakers` | object | Map of breaker names (e.g., `gemini`, `telegram`) to settings. _(legacy alias: `circuit_breakers`)_ |
| `...maxFailures` | int | Number of failures before the breaker opens. _(legacy alias: `max_failures`)_ |
| `...window` | string | Rolling window for failure counting (e.g., `"60s"`). |
| `...timeout` | string | Time to wait before attempting to close the breaker (e.g., `"30s"`). |

Defaults when not configured: 5 failures, 60s window, 30s timeout.

---

### 8. Context (`context`)

| Field | Type | Description |
|-------|------|-------------|
| `sessionTokenBudget` | int | Token budget per session before compaction is triggered (default 80000). _(legacy alias: `session_token_budget`)_ |
| `compactionSummaryTurns` | int | Number of oldest turns to summarize per compaction pass (default 20). _(legacy alias: `compaction_summary_turns`)_ |

---

### 9. Cron (`cron`)

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Enable the built-in cron scheduler. |
| `tasks` | array | List of scheduled tasks, each with a `name` (string) and `schedule` (cron expression string). |

---

### 10. Heartbeat (`heartbeat`)

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Enable periodic heartbeat ticks. |
| `interval` | string | Duration between heartbeat ticks (e.g., `"15m"`). Default `15m`. |

The heartbeat is a **pure infrastructure health check** — no LLM is invoked. On each tick it probes three services:

1. **Telegram** — verifies the bot token is accepted by the Telegram API
2. **Gemini** — verifies the Gemini API key is valid and reachable
3. **Gmail** — verifies the OAuth token is present and not expired

After each check it writes a `LIVENESS` file to `{storage_root}/LIVENESS` with the current timestamp and failure count. If any probe fails, an alert is sent via Telegram to `strategic_edition.user_chat_id`. Successful ticks log at `DEBUG` level only.

---

### 11. Logging (`logging`)

| Field | Type | Description |
|-------|------|-------------|
| `level` | string | Log level: `DEBUG`, `INFO`, `WARN`, or `ERROR` (default `INFO`). |
| `format` | string | Log format: `text` or `json` (default `text`). |
| `maxSizeMB` | int | Maximum log file size in MB before rotation (default 50). _(legacy alias: `max_size_mb`)_ |
| `maxBackups` | int | Number of rotated log files to retain (default 5). _(legacy alias: `max_backups`)_ |
| `maxAgeDays` | int | Days to retain old log files (default 30). _(legacy alias: `max_age_days`)_ |
| `compress` | bool | Compress rotated log files (default `true`). |

# gobot - The Strategic Agent Runtime

[![CI](https://github.com/allthingscode/gobot/actions/workflows/ci.yml/badge.svg)](https://github.com/allthingscode/gobot/actions/workflows/ci.yml)
[![Go Version](https://img.shields.io/github/go-mod/go-version/allthingscode/gobot)](go.mod)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

`gobot` is a high-performance, Go-native runtime designed to power the next generation of autonomous AI agents. It provides a secure, observable, and deeply integrated environment for LLMs to interact with the real world through Telegram, Google Workspace, and persistent long-term memory.

## What is gobot?

`gobot` is a Go-native AI agent runtime with a focus on personal productivity and strategic execution. It serves as a unified interface between large language models (like Gemini, Claude, and GPT) and your digital life. With native support for Telegram, Google Calendar, Tasks, and Gmail, `gobot` acts as an autonomous assistant capable of managing schedules, processing information, and executing workflows.

Unlike traditional chatbot frameworks that rely on Python and CGO-heavy dependencies, `gobot` compiles to a single static binary with zero external C dependencies. Every interaction is checkpointed to a pure-Go SQLite database, enabling durable sessions that survive process restarts and network failures.

## Key Features

- **Zero-Dependency Runtime:** Compiles to a single static binary for trivial deployment (no Python venvs, no CGO, pure-Go SQLite via `modernc.org/sqlite`).
- **Durable Session State:** Every interaction is checkpointed via a pure-Go SQLite implementation (`modernc.org/sqlite`) under durable storage root (e.g. `~/gobot_data` or configured path).
- **Long-Term Memory (RAG):** Automatically indexes session history using SQLite FTS5 for semantic search, enabling agents to recall context across sessions.
- **Autonomous Cron:** Built-in background job scheduler for recurring agent tasks (e.g., morning briefings, calendar checks).
- **Strategic Hardening:** Integrated PII redaction, circuit breakers, and zero-trust security gates on every inbound message.
- **Deep Workspace Integration:** First-class support for Google Calendar, Tasks, and Gmail via OAuth2 authentication with DPAPI-encrypted token storage on Windows.
- **Multi-Model Support:** Abstract provider layer supports Gemini, Anthropic Claude, and OpenAI-compatible APIs with seamless switching.
- **Observable by Default:** OpenTelemetry integration for traces and metrics, structured logging with `log/slog`, and comprehensive health checks via `gobot doctor`.

## Platform Support

GoBot runs on **Windows**, **Linux**, and **macOS** with the following considerations:

| Platform | Status | Notes |
|----------|--------|-------|
| Windows 10/11 | ✅ Primary | DPAPI-encrypted secrets, Job Object sandboxing, native logging |
| Linux (x86_64) | ✅ Supported | File-based secret encryption (less secure than DPAPI) |
| macOS (x86_64/ARM) | ✅ Supported | File-based secret encryption (less secure than DPAPI) |

**Cross-platform features:**
- Pure Go binary (zero CGO dependencies)
- SQLite-based state/memory persistence
- Telegram integration
- Google Workspace integration (Calendar, Tasks, Gmail)
- OpenTelemetry observability

**Windows-exclusive features:**
- DPAPI-encrypted OAuth2 tokens (tied to user account)
- Sandboxed shell execution via Windows Job Objects
- Native structured logging via ETW

## Requirements

- **Go 1.25+** (for building from source; see `go.mod` for exact version)
- **Telegram Bot Token** (from [@BotFather](https://t.me/BotFather))
- **LLM API Key** (Gemini, Anthropic, or OpenAI)

## Installation

### 1. Build from Source

```powershell
# Clone the repository
git clone https://github.com/allthingscode/gobot.git
cd gobot

# Build for Windows
.\scripts\build.ps1

# Or for Linux/macOS
./scripts/build.sh
```

Alternatively, build directly with Go:

```bash
go build -o gobot ./cmd/gobot
```

### 2. Initialization

Run `gobot init` to create the storage structure. This automatically generates a template configuration:

```powershell
./gobot init
```

This creates the following directory structure under the configured storage root (default `~/gobot_data` on Windows/Linux/macOS, or configured path):

```
<STORAGE_ROOT>/
├── config.json          # Main configuration file
├── gobot.db             # SQLite checkpoint database
├── memory.db            # Long-term memory FTS5 index
├── logs/                # Timestamped structured logs
├── secrets/             # DPAPI-encrypted OAuth2 tokens
├── sessions/            # Session checkpoint JSON files
└── jobs/                # Cron job definitions
```

### 3. Configuration

Fill in your API keys in the generated `config.json` (usually located in `~/.gobot/config.json` or the storage root):

| Field | Description | Required |
|-------|-------------|----------|
| `apiKey` | Your Gemini/multi-model API key | Yes (for Gemini) |
| `anthropicApiKey` | Your Anthropic API key (for Claude models) | No |
| `openaiApiKey` | Your OpenAI API key (for OpenAI models) | No |
| `channels.telegram.token` | Your Telegram bot token (from @BotFather) | Yes (for Telegram) |
| `channels.telegram.allowFrom` | Whitelisted Telegram user IDs (numeric) | Yes (security) |
| `strategic_edition.user_email` | Your Gmail address (for Google Workspace tools) | No (for Gmail/calendar/tools) |

For a complete list of configuration options, see the [full configuration reference](docs/configuration.md).

### 4. Authorization

If using Google Workspace tools (Calendar, Tasks, Gmail), run the interactive re-authorization:

```powershell
./gobot reauth
```

This launches a local OAuth2 flow, storing encrypted tokens under `secrets/gmail/token.json`. On Windows, tokens are encrypted via DPAPI; on Linux/macOS, they use file-level encryption.

## Usage

### Start the Agent

```powershell
./gobot run
```

This starts the Telegram polling loop and HTTP gateway (if enabled). The agent will listen for messages from whitelisted users only.

### Local Simulation

Test prompts without Telegram:

```powershell
./gobot simulate "What's on my calendar today?"
```

This runs the full agent loop locally, printing the response.

### Diagnostics

Check system health:

```powershell
./gobot doctor
```

This runs pre-flight diagnostics including:
- Configuration validation
- Storage directory accessibility
- Database file locks
- OAuth2 token validity (if `--no-interactive` is not passed)
- API key reachability

### Security Scanning

Gobot uses `govulncheck` to scan for reachable vulnerabilities in dependencies. Developers should run this before pushing changes:

```powershell
./scripts/check_security.ps1
```

This mirrors the CI job and ensures that any security risks are identified and resolved locally. The script will automatically install `govulncheck` if it is not found in your environment.

### View Logs

```powershell
./gobot logs --lines 50 --filter ERROR
```

This displays the last 50 log lines filtered by severity. Logs are stored as structured JSON under `<STORAGE_ROOT>/logs/`.

### Manage Checkpoints

List resumable sessions:

```powershell
./gobot checkpoints
```

Resume a specific session by viewing its history:

```powershell
./gobot resume <thread-id>
```

### Manage Long-Term Memory

Re-index all session logs into the memory database:

```powershell
./gobot memory rebuild
```

Search the memory index:

```powershell
./gobot memory search "calendar events"
```

### Google Workspace Commands

List upcoming calendar events:

```powershell
./gobot calendar --max 10
```

List open tasks:

```powershell
./gobot tasks list
```

Add a new task:

```powershell
./gobot tasks add "Review pull requests"
```

Send a test email:

```powershell
./gobot email "Test Subject" "Test body content"
```

### Authorization Management

Authorize a Telegram user by pairing code:

```powershell
./gobot authorize <pairing-code>
```

Or authorize directly by chat ID:

```powershell
./gobot authorize 123456789
```

## Architecture Overview

`gobot` follows a modular architecture where the core agent loop is decoupled from LLM providers and specific tools. The data flow can be visualized as:

```
Telegram/HTTP → Bot Handler → Agent Session Manager → LLM Provider → Tool Dispatch
                                         ↓
                                  State/Memory/Cron
```

- **Agent:** Manages session lifecycle, tool dispatch, and compaction. The agent loop handles LLM turns, processes tool results, and maintains conversation state.
- **Provider:** Abstracts different LLM APIs (Gemini, Anthropic, OpenAI) behind a unified interface. The provider factory initializes all configured providers at startup.
- **Tools:** Modular implementations for Shell commands, Google APIs (Calendar, Tasks, Gmail), Memory search, and spawning child agents. Each tool is a self-contained unit with its own execution sandbox.
- **State/Memory:** Durable persistence via pure-Go SQLite (`modernc.org/sqlite`). Checkpoints are saved atomically after each agent turn, enabling seamless session resumption.
- **Cron:** Autonomous job scheduler that creates ephemeral agent sessions for recurring tasks (e.g., morning briefings). Cron jobs never share checkpoint history with user conversations.
- **Gateway:** HTTP server for webhook-based Telegram integration and future web dashboard.
- **Observability:** OpenTelemetry integration for distributed traces and metrics export, structured via `log/slog`.

For a deeper dive into package responsibilities and design decisions, see [`docs/architecture.md`](docs/architecture.md).

## Project Structure

- **`cmd/gobot/`** — CLI entry point and command wiring via `cobra`. Contains all top-level commands (`run`, `simulate`, `doctor`, etc.).
- **`internal/agent/`** — Core agent session management, tool-dispatch logic, and compaction. The `SessionManager` is the heart of the agent loop.
- **`internal/bot/`** — Telegram bot client and message routing. Implements the `Handler` interface for pairing gates and message dispatch.
- **`internal/config/`** — Configuration loading, validation, and helper methods. Reads from YAML/JSON and provides typed accessors.
- **`internal/context/`** — Durable checkpointing and session state persistence (SQLite). Manages atomic writes and file locking for crash safety.
- **`internal/memory/`** — Long-term memory indexing and RAG search components. Uses SQLite FTS5 for full-text search across session history.
- **`internal/provider/`** — LLM provider abstraction layer. Supports Gemini, Anthropic, and OpenAI-compatible APIs with unified `Provider` interface.
- **`internal/strategic/`** — Strategic Edition mandates and output hardening. Contains PII redaction, circuit breakers, and security gates.
- **`internal/integrations/google/`** — Google OAuth2 and API service clients for Calendar, Tasks, and Gmail.
- **`internal/gateway/`** — HTTP gateway for Telegram webhook mode and future web UI.
- **`internal/cron/`** — Autonomous background job scheduler. Reads job definitions from `jobs/` directory and spawns ephemeral agent sessions.
- **`internal/observability/`** — OpenTelemetry traces and metrics export. Integrates with `otel` SDK for distributed tracing.
- **`internal/resilience/`** — Circuit breakers and intelligent retry logic. Prevents cascading failures from transient API errors.

## Development & Testing

`gobot` targets 80%+ test coverage using table-driven tests. Always run tests before submitting changes:

```powershell
go test ./...
```

Run the linter suite:

```powershell
golangci-lint run
```

Or use the CI pipeline:

```powershell
go vet -mod=readonly ./...
```

### Pre-commit Checklist

- [ ] All tests pass (`go test ./...`)
- [ ] No linting errors (`golangci-lint run`)
- [ ] Code is formatted (`gofmt -w .`)
- [ ] No `vendor/` directory in git (it's gitignored)
- [ ] No `.private/`, `.gemini/`, or `.vscode/` in commits

## CI/CD

The project uses GitHub Actions for continuous integration:

- **Lint:** Runs `golangci-lint` on Ubuntu with `go version v2.1.6`.
- **Test:** Runs on both Ubuntu and Windows with `go test -mod=readonly ./...`.
- **Doc Lint:** Validates documentation consistency via `scripts/doc_lint.go`.
- **Parity Check:** Validates upstream reference parity via `scripts/parity_check.go`.

All checks must pass before merging. See [`.github/workflows/ci.yml`](.github/workflows/ci.yml) for details.

## License

This project is licensed under the MIT License — see the [`LICENSE`](LICENSE) file for details.

## Contributing

Contributions are welcome! Please read the code of conduct and follow the development workflow outlined above.

---

*Directed by the Architect. Executed by AI.*

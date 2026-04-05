# gobot Architecture

`gobot` is built as a high-performance, Go-native agent runtime designed for durable, long-running AI interactions. This document provides a high-level overview of the internal components and data flow.

## High-Level Data Flow

```text
                                       +-----------------------+
                                       |      LLM Provider     |
                                       | (Gemini, Anthropic,   |
                                       |      OpenAI)          |
                                       +-----------+-----------+
                                                   |
                                                   v
+----------------+      +-------------+      +-----+-----+      +-----------------+
|   Telegram     | <--> |     bot     | <--> |   agent   | <--> |      tools      |
| (or Webhook)   |      | (Routing)   |      |   loop    |      | (Shell, Google, |
+----------------+      +-------------+      +-----+-----+      |      Gmail)     |
                                                   |            +-----------------+
                                                   v
                                       +-----------+-----------+
                                       |      Persistence      |
                                       | (Checkpoints, Memory, |
                                       |      Workflow)        |
                                       +-----------------------+
```

## Package Responsibilities

| Package | Path | Purpose |
|---------|------|---------|
| `agent` | `internal/agent` | Core agent loop, tool dispatch, and session management. |
| `audit` | `internal/audit` | PII redaction and immutable audit trail generation. |
| `bot` | `internal/bot` | Telegram integration and message routing. |
| `config` | `internal/config` | Configuration loading, validation, and DPAPI support. |
| `context` | `internal/context` | Durable session checkpoints and state persistence (SQLite). |
| `cron` | `internal/cron` | Autonomous background job scheduler. |
| `doctor` | `internal/doctor` | System diagnostics and pre-flight health checks. |
| `gateway` | `internal/gateway` | HTTP gateway for webhooks and future UI. |
| `gmail` | `internal/gmail` | Gmail integration tools. |
| `google` | `internal/google` | Google Workspace API clients (Calendar, Tasks, Auth). |
| `infra` | `internal/infra` | Infrastructure wiring and application lifecycle. |
| `memory` | `internal/memory` | Long-term memory with FTS5 semantic search. |
| `provider` | `internal/provider` | LLM provider abstractions (Gemini, Anthropic, OpenAI). |
| `resilience` | `internal/resilience` | Circuit breakers and intelligent retry logic. |
| `sandbox` | `internal/sandbox` | Secure tool execution isolation. |
| `secrets` | `internal/secrets` | Encrypted local secret storage (Windows DPAPI). |
| `state` | `internal/state` | Atomic workflow state management for long-running tasks. |
| `strategic` | `internal/strategic` | Strategic mandates and output hardening. |

## Key Design Decisions

### Pure-Go Architecture (Zero-CGO)
`gobot` intentionally avoids CGO dependencies to ensure seamless cross-compilation and trivial deployment. SQLite is implemented via `modernc.org/sqlite`, a pure-Go rewrite of the original C library.

### Durable by Default
Every turn of the agent loop is checkpointed to a local SQLite database. If the process is restarted, the agent can resume complex, multi-turn conversations exactly where it left off.

### Security First
- **Zero-Trust Whitelisting:** Only authorized Telegram users can interact with the agent.
- **DPAPI Encryption:** On Windows, all local secrets (like API keys) are encrypted using the machine's Data Protection API (DPAPI).
- **Log Redaction:** All logs pass through a redacting handler that identifies and masks PII (Phone numbers, Email addresses, Credit cards).

### Long-Term Memory (RAG)
`gobot` uses a persistent SQLite-backed FTS5 index to store and retrieve session history. This provides the agent with "deep memory," allowing it to recall information from conversations that happened weeks or months ago.

### Strategic Hardening
The `strategic` package enforces specific mandates and hooks that allow for custom logic injection without polluting the core application logic. This ensures that the agent follows established safety and engineering standards.

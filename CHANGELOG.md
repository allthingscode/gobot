# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

### Added
- **Advanced Context Pruning & Compaction Policies** (F-047): Sophisticated context management for long-running sessions.
  - Implements TTL-based pruning (e.g., "6h" window) for history retention.
  - Adds `KeepLastAssistants` safety net to preserve critical assistant turns.
  - Integrates `memoryFlush` strategy with asynchronous fact extraction into long-term memory.
  - Adds `created_at` message timestamps to conversation history.
- **Rubric-Driven Reflection Loop** (F-049): Implement a multi-phase agent loop with explicit planning and reflection.
  - Generates a measurable validation rubric before task execution.
  - Performs a "Critic" turn to audit model output against the rubric.
  - Triggers a backtrack and correction if the reflection score is below threshold.
- Support for additional MCP server integrations
- Enhanced telemetry for distributed tracing
- Support for per-specialist model routing in sub-agents

### Changed
- Improved context pruning strategies for long-running sessions
- Enhanced error reporting with structured logging

### Fixed
- **Bot Package Stale Comment** (B-010): Updated `internal/bot/bot.go` package comment to reference `telego` instead of deprecated `go-telegram-bot-api`.
- Pending issues to be documented as they are resolved

---

## [0.1.0] — 2026-04-03

### Added
- **Concurrency Safety Metrics** (F-056): Lock metrics, deadlock detection, and race condition detection in production
- **Native Log Command** (F-059): Cross-platform `gobot logs` with filtering and follow mode
  - `--filter` flag for pattern matching
  - `--follow` flag for tail-like behavior
  - `--lines` flag for limiting output
- **Bounds Validation and Context Cancellation** (C-007): Polish improvements to `gobot logs` command
  - Validates `--lines` must be > 0
  - Context cancellation respects SIGTERM
- **Fault Injection Testing** (F-055): Comprehensive network resilience testing with configurable failure modes
- **Configuration Validation** (F-053): Fail-fast startup with comprehensive config validation
- **Multi-Provider LLM Support** (F-051): Native support for Gemini, Anthropic, and OpenAI-compatible providers
- **Callback Query Reliability** (B-029): Fixed silent dropping of Telegram callback queries
- **Resource Cleanup Pattern** (C-004): Systematic resource lifecycle management with RAII pattern
- **Error Handling Standardization** (C-005): High-fidelity error wrapping, returns, and panic policies
- **Storage Root Consistency** (B-026): Fixed config drift between C: and D: drives
- **Human-in-the-Loop Framework** (F-048): Configuration toggle for human-in-the-loop approvals
- **HTTP Gateway and Control Flags** (F-046): Gateway enabled/disabled configuration flags
- **Core Agent Loop**: Full feature parity with Python Nanobot Strategic Edition
  - Recursive improvement system with five specialist roles (Researcher, Groomer, Architect, Reviewer, Operator)
  - Modular cron system with markdown-based job definitions
  - Session checkpointing and recovery
  - Durable state management via SQLite
  - Zero-trust security with hard whitelisting
  - Strategic Hook system (F-012) for custom logic injection

### Fixed
- **Doctor Probe Telego Bot Leak** (B-011): Context timeout prevents resource leak during health checks
- **Tool Failure Log Missing Session Key** (B-013): Added session context to runner tool execution errors
- **Telegram Poller Log Flooding** (B-030): Reduced log verbosity on open circuit breaker
- **CGO Flag Leaks** (F-056): Removed unintended CGO compilation flags from build
- **Lock Metrics Memory Allocations** (F-056): Optimized concurrent lock tracking for memory efficiency

### Removed
- Dead code and unused configuration fields (B-006)

### Security
- **Zero-Trust Security**: Hard whitelist enforcement for all inbound Telegram messages
- **PII & Secret Masking** (F-019): Automatic detection and redaction of sensitive information in logs
- **Secure Secrets Manager** (F-021): DPAPI-based credential storage for OAuth tokens and API keys

### Deprecated
- Python Nanobot is now in maintenance mode only (reference implementation)

---

## Technical Stack

- **Language**: Pure Go (no CGO)
- **Database**: SQLite with WAL mode and FTS5
- **Concurrency**: `sync.Mutex`, `sync.RWMutex`, `context.Context`
- **Logging**: Structured logging with `log/slog`
- **Testing**: Table-driven tests with `go test`
- **API Clients**: Google Genai SDK, Telegram Bot API (via tgbotapi v5)

---

## Contributing

This project uses a specialist-based recursive improvement system. See `.private/OPERATING_MANUAL.md` for detailed contribution guidelines and the development workflow.

---

## License

Internal Use Only

# gobot — Claude Code Context

## Project Overview

**gobot** is the Go port of the Nanobot Strategic Edition (EPIC-001, Strategy A).
Module: `github.com/allthingscode/gobot`
The Python nanobot at `../nanobot/` runs in parallel until Go reaches feature parity.

## Hard Mandates

- **Vendor everything**: always pass `-mod=vendor` to `go test` and `go build`. Never rely on the module cache.
- **No CGO**: pure Go only. Do not add dependencies that require a C compiler (e.g. `github.com/mattn/go-sqlite3`). Use `modernc.org/sqlite` for SQLite.
- **No ADK Go API calls in tests**: `internal/` packages contain pure logic only. Tests must not call Gemini or any external API.
- **Table-driven tests**: all test files use `[]struct{ name, input, want }` style where applicable.
- **Pre-commit hook**: `scripts/hooks/pre-commit` runs `go vet ./...` then `go test -mod=vendor ./...`. Install once with `cp scripts/hooks/pre-commit .git/hooks/pre-commit`.

## Key Paths

| Purpose | Path |
|---------|------|
| CLI entrypoint | `cmd/gobot/` |
| Pure logic packages | `internal/` |
| Vendored deps | `vendor/` |
| Pre-commit hook (checked in) | `scripts/hooks/pre-commit` |
| Python source to port from | `..\nanobot\strategery\logic\` |

## Package Map

### Phase 2 — ported from `strategery/logic/` (complete)

| Package | Source | Status |
|---------|--------|--------|
| `internal/config/` | `config_logic.py` | Done |
| `internal/doctor/` | `strategic_doctor.py` | Done |
| `internal/strategic/` | `subagent_logic.py` (mandate/CLIXML) | Done |
| `internal/shell/` | `subagent_logic.py` (CLIXML/redirect) | Done |
| `internal/audit/` | `model_audit_logic.py` | Done |
| `internal/reflection/` | `reflection_logic.py` | Done |
| `internal/memory/` | `memory_logic.py` | Done |
| `internal/provider/` | `provider_logic.py` | Done |
| `internal/infra/` | `infra_logic.py` | Done |
| `internal/telegram/` | `telegram.py` (pure logic) | Done |
| `internal/context/` | `checkpoint_logic.py` | Done |

### Phase 3 — runtime packages (complete)

| Package | Source | Status |
|---------|--------|--------|
| `internal/cron/` | `cron_logic.py` | Done |
| `internal/telegram/` | `telegram.py` (pure logic) | Done |
| `internal/reporter/` | `strategic_email_reporter.py` (pure logic) | Done |

### Phase 4 — integration layer (complete)

| Package / File | Description | Status |
|----------------|-------------|--------|
| `internal/gmail/` | Pure-Go Gmail OAuth2 + delivery | Done |
| `internal/agent/` | Per-session serialization, `SessionManager`, `StripSilent` | Done |
| `internal/bot/` | Telegram polling runtime, `IsTransientError`, backoff | Done |
| `cmd/gobot/telegram.go` | tgbotapi v5 adapter implementing `bot.API` | Done |
| `cmd/gobot/runner.go` | `geminiRunner` implementing `agent.Runner` via genai SDK | Done |
| `cmd/gobot/main.go` | `gobot run` + `gobot reauth` commands wired | Done |

### Phase 4 — in progress

| File | Description | Status |
|------|-------------|--------|
| `cmd/gobot/cron.go` | `cronDispatcher` + scheduler wired into `gobot run` | In Progress |

## Common Commands

```powershell
# Run all tests
go test -mod=vendor ./...

# Run tests with coverage
go test -mod=vendor ./internal/context/ -cover

# Vet
go vet ./...

# Build CLI
go build -mod=vendor ./cmd/gobot/
```

## Reference Documents

The `docs/references/` directory contains best practices and design patterns for this project:
- `01-cobra-cli.md`: Cobra CLI structure and `RunE`.
- `02-sqlite-pure-go.md`: Pure Go SQLite, WAL mode, and concurrency.
- `03-go-testing.md`: Table-driven tests, parallelization, and `t.Helper()`.
- `04-go-architecture.md`: Project layout, interfaces, and error wrapping.
- `05-openclaw-design.md`: OpenClaw Gateway architecture, Pi runtime, and session model.

## Epic Reference

Full roadmap: EPIC-001 in the nanobot private feature backlog.

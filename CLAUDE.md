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

## Package Map (Phase 2 — ported from `strategery/logic/`)

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
| `internal/context/` | `checkpoint_logic.py` | In Progress |

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

## Epic Reference

Full roadmap: EPIC-001 in the nanobot private feature backlog.

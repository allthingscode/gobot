# gobot - The Strategic Agent Runtime

[![CI](https://github.com/allthingscode/gobot/actions/workflows/ci.yml/badge.svg)](https://github.com/allthingscode/gobot/actions/workflows/ci.yml)
[![Go Version](https://img.shields.io/github/go-mod/go-version/allthingscode/gobot)](go.mod)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**⚡ Built 100% by AI Agents** — gobot was designed, coded, and tested entirely by autonomous AI systems through the Dev Factory recursive improvement system. No human wrote a line of production code.

**👨‍💻 Architect: Matthew Hayes** — See [AUTHORS.md](AUTHORS.md) for professional background and expertise in agentic systems.

## What Is This Space?

[OpenClaw](https://github.com/openclaw/openclaw) is the canonical self-hosted AI personal assistant — a TypeScript bot that connects your messaging app to LLMs, tools, and memory. It has 347k+ stars and inspired a wave of Go and Rust reimplementations that trade OpenClaw's extensibility for a smaller binary, simpler deployment, or a tighter feature focus.

gobot is one of those reimplementations. It is a **single-user, self-hosted AI assistant** built on Telegram, written in pure Go, with no external database dependencies. If you already know you want a Go-native OpenClaw alternative, the comparison tables below will help you pick the right one.

---

## Where GoBot Wins

**Unique to gobot — no other Go alternative has these:**

- **📧 Deep Google Workspace** — Gmail, Calendar, and Tasks are first-class tools. Ask about your schedule, summarize emails, add tasks. No competitor in this space has native Google OAuth integration.
- **🛑 Human-in-the-Loop (HITL) approvals** — gobot pauses before irreversible actions (sending emails, creating calendar entries) and waits for your explicit confirmation. Most alternatives run to completion without asking.
- **🔒 Windows-native secrets** — API keys are encrypted with DPAPI on Windows (OS-level keystore), not stored in plaintext config files. Windows is a first-class platform, not an afterthought.

**Where gobot's architecture pays off:**

- **🚀 Zero infrastructure** — SQLite only. No Postgres server, no pgvector extension, no container orchestration. One binary, one data directory.
- **🧠 In-process memory** — Vector search via chromem-go runs inside the binary. No separate vector database to operate or back up.
- **⏰ Always on** — Cron scheduler for background jobs (morning briefings, calendar digests) built in.
- **📊 Production-grade observability** — OpenTelemetry tracing, structured logging (slog), circuit breakers, and health checks.
- **🤖 Multi-model** — Switch between Gemini, Claude, OpenAI, and OpenRouter per specialist role.

---

## GoBot vs. the Field

### Broad Comparison — Go Alternatives

| | **gobot** | **GoGogot** | **NeoClaw** | **GoClaw** |
|---|---|---|---|---|
| **Stars (Apr 2026)** | — | ~115 | — | ~1,500 |
| **Storage** | SQLite + chromem-go | In-process notes | SQLite | PostgreSQL + pgvector |
| **CGO** | None | None | None | Yes (pg drivers) |
| **LLM providers** | 4 | 6+ | 4 | 20+ |
| **Channels** | Telegram | Telegram | Telegram + CLI | 7 (Telegram, Discord, Slack…) |
| **Google Workspace** | Yes (Gmail, Cal, Tasks) | No | No | No |
| **HITL approvals** | Yes | No | No | No |
| **Windows-native secrets** | Yes (DPAPI) | No | No | No |
| **Users** | Single-user | Single-user | Single-user | Multi-tenant SaaS |
| **Infra required** | None | None | None | Postgres + pgvector |
| **OTel tracing** | Yes | No | No | Yes |
| **Cron / background jobs** | Yes | No | No | Yes |

**[GoGogot](https://github.com/aspasskiy/GoGogot)** is the most similar project in spirit — lightweight, simple agent loop, Telegram-only, no external dependencies. It edges out gobot on provider count (6 vs 4) and has a smaller reported footprint (15MB binary, 10MB RAM idle). gobot edges out GoGogot on Google Workspace depth, HITL, Windows security, and observability.

**[NeoClaw](https://github.com/jigarvarma2k20/neoclaw)** covers similar ground (SQLite, Telegram, multi-LLM) and adds a CLI mode and SMTP email. gobot's advantage is Google OAuth depth vs. NeoClaw's SMTP-only email, plus HITL and Windows-native secrets.

**GoClaw** (nextlevelbuilder) is the most ambitious Go alternative — see the deep-dive section below.

---

### GoClaw Deep Dive

[GoClaw](https://github.com/nextlevelbuilder/goclaw) is the most technically advanced Go reimplementation. If you are evaluating both, here is the honest comparison.

#### GoClaw is the better choice if you need:
- A **multi-tenant SaaS backend** serving many users from one server
- **20+ LLM providers** (OpenAI, Groq, DeepSeek, Gemini, Mistral, xAI, Ollama, and more via OpenAI-compatible endpoints)
- **Agent teams** with inter-agent delegation (one agent hands tasks to another)
- An **existing PostgreSQL + pgvector** stack you already operate

#### gobot is the better choice if you need:
- **Zero infrastructure** — SQLite only, no database server to operate or back up
- **Pure Go / no CGO** — single static binary that ships and runs anywhere without native library dependencies
- **Google Workspace as a first-class citizen** — Gmail, Calendar, and Tasks are deeply integrated; GoClaw has none of this
- **Human-in-the-loop (HITL) approvals** — gobot pauses and waits for your confirmation before irreversible actions; GoClaw has no equivalent
- **Simplicity at the loop level** — gobot's agent loop is a straightforward Read → Think → Act cycle; GoClaw's V3 pipeline runs 8 stages with up to 20 iterations per request and four asynchronous background workers
- **Single-user focus** — GoClaw's architecture is built around multi-tenant isolation (per-user workspaces, RBAC policy engine, cross-user session scoping). If you're running a personal assistant, you're carrying all that complexity for no benefit
- **Memory without a vector database server** — GoClaw's 3-tier memory requires pgvector, a PostgreSQL extension. gobot uses chromem-go for in-process vector search backed by SQLite — no extra services

#### The honest tradeoffs

| | gobot | GoClaw |
|---|---|---|
| Storage | SQLite (zero infra) | PostgreSQL + pgvector (requires running DB) |
| CGO | None (pure Go) | Yes (pg drivers) |
| Users | Single-user / personal | Multi-tenant SaaS |
| Google Workspace | Deep (Gmail, Calendar, Tasks) | Not supported |
| HITL approvals | Yes | No |
| LLM providers | 4 (Gemini, Claude, OpenAI, OpenRouter) | 20+ |
| Agent teams | No | Yes |
| Pipeline complexity | Simple loop | 8-stage, up to 20 iterations |
| Memory backend | SQLite + chromem-go (in-process) | pgvector (external service) |
| Memory workers | Synchronous consolidator | 4 async background workers |
| OTel tracing | Yes | Yes |

gobot's design principle is **stability for one user over scale for many**. Every architectural decision — SQLite over Postgres, three providers over twenty, a simple loop over an 8-stage pipeline — is a deliberate trade of raw capability for reliability and operational simplicity.

---

## Get Started in 60 Seconds

1. **Prerequisites**: Telegram bot token + Gemini/Anthropic/OpenAI API key
2. **Install**:
   ```powershell
   git clone https://github.com/allthingscode/gobot.git
   cd gobot
   .\scripts\build.ps1  # Windows
   # OR ./scripts/build.sh  # Linux/macOS
   ```
3. **Initialize**: `./bin/gobot init`
4. **Configure**: Add your API keys to config.json
5. **Authorize** (for Google tools): `./bin/gobot reauth`
6. **Run**: `./bin/gobot run`

## Documentation

- [Architecture](docs/architecture.md) — data flow, package responsibilities, key design decisions
- [Configuration Reference](docs/configuration.md) — all config fields with defaults and examples
- [Locking Strategy](docs/locking-strategy.md) — session-scoped locking design and rationale

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on our coding standards, build process, and how to submit pull requests.

## What You Can Do With gobot

- Ask about your schedule: "What's on my calendar today?"
- Process emails: "Summarize unread emails from my boss"
- Manage tasks: "Add 'Review project proposal' to my task list"
- Get intelligent responses: Uses your conversation history for context-aware answers
- Run automated jobs: Set up daily briefings or weekly reports

## Platform Support

Works everywhere you do — **Windows** (with enhanced security), **Linux**, and **macOS**. Same binary, same features.

## Built for Humans Who Demand More

While other agents need constant babysitting and break with updates, gobot:
- Survives restarts and network failures with checkpointed state
- Scopes access to whitelisted users only (no unwanted guests)
- Uses pure Go (no mysterious native crashes)
- Maintains 80%+ test coverage for reliability
- Logs everything for easy troubleshooting

*Directed by the Architect. Executed by AI.*

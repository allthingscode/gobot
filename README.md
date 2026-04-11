# gobot - The Strategic Agent Runtime

[![CI](https://github.com/allthingscode/gobot/actions/workflows/ci.yml/badge.svg)](https://github.com/allthingscode/gobot/actions/workflows/ci.yml)
[![Go Version](https://img.shields.io/github/go-mod/go-version/allthingscode/gobot)](go.mod)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**⚡ Built 100% by AI Agents** - Unlike OpenClaw and NanoClaw which require human developers, gobot was designed, coded, and tested entirely by autonomous AI systems through the Dev Factory recursive improvement system.

## Why gobot Beats Other Agent Frameworks

Forget complex setups and fragile dependencies. gobot delivers a production-ready AI agent that just works:

- **🚀 Instant Deployment** - Single static binary (no Python venvs, no CGO, no dependency hell)
- **🧠 Perfect Memory** - Never forgets conversations with built-in long-term memory (RAG)
- **⏰ Always On** - Background jobs run automatically (morning briefings, calendar checks)
- **🔒 Bank-Level Security** - Zero-trust message validation + DPAPI-encrypted secrets on Windows
- **📧 Full Workspace Control** - Manages your Gmail, Calendar, and Tasks like a human assistant
- **🤖 Multi-Model Flexibility** - Switch between Gemini, Claude, and OpenAI anytime
- **📊 Self-Monitoring** - Built-in health checks, logging, and performance metrics

## gobot vs GoClaw

[GoClaw](https://github.com/nextlevelbuilder/goclaw) is the most technically ambitious Go reimplementation of the OpenClaw pattern. If you're evaluating both, here's the honest comparison.

### GoClaw is the better choice if you need:
- A **multi-tenant SaaS backend** serving many users from one server
- **20+ LLM providers** (OpenAI, Groq, DeepSeek, Gemini, Mistral, xAI, Ollama, and more via OpenAI-compatible endpoints)
- **Agent teams** with inter-agent delegation (one agent hands tasks to another)
- An **existing PostgreSQL + pgvector** stack you already operate

### gobot is the better choice if you need:
- **Zero infrastructure** — SQLite only, no database server to operate or backup separately
- **Pure Go / no CGO** — single static binary that ships and runs anywhere without native library dependencies
- **Google Workspace as a first-class citizen** — Gmail, Calendar, and Tasks are deeply integrated; GoClaw has none of this
- **Human-in-the-loop (HITL) approvals** — gobot can pause mid-run and wait for your explicit confirmation before taking irreversible actions (sending emails, creating calendar entries); GoClaw has no equivalent
- **Simplicity at the loop level** — gobot's agent loop is a straightforward Read → Think → Act cycle; GoClaw's V3 pipeline runs 8 stages with up to 20 iterations per request, four asynchronous background workers (EpisodicWorker, SemanticWorker, DedupWorker, DreamingWorker), and a 7-step sanitization pass on every response
- **Single-user focus** — GoClaw's architecture is built around multi-tenant isolation (per-user workspaces, RBAC policy engine, cross-user session scoping). If you're running a personal assistant, you're carrying all that complexity for no benefit
- **Memory without a vector database server** — GoClaw's 3-tier memory (working → episodic → knowledge graph) requires pgvector, a PostgreSQL extension. gobot uses chromem-go for vector search in-process, backed by SQLite — no extra services

### The honest tradeoffs

| | gobot | GoClaw |
|---|---|---|
| Storage | SQLite (zero infra) | PostgreSQL + pgvector (requires running DB) |
| CGO | None (pure Go) | Depends on pg drivers |
| Users | Single-user / personal | Multi-tenant SaaS |
| Google Workspace | Deep (Gmail, Calendar, Tasks) | Not supported |
| HITL approvals | Yes | No |
| LLM providers | 3 (Gemini, Claude, OpenAI) | 20+ |
| Agent teams | No | Yes |
| Pipeline complexity | Simple loop | 8-stage, up to 20 iterations |
| Memory backend | SQLite + chromem-go (in-process) | pgvector (external service) |
| Memory workers | Synchronous consolidator | 4 async background workers |

gobot's design principle is **stability for one user over scale for many**. Every architectural decision — SQLite over Postgres, three providers over twenty, a simple loop over an 8-stage pipeline — is a deliberate trade of raw capability for reliability and operational simplicity.

## Get Started in 60 Seconds

1. **Prerequisites**: Telegram bot token + Gemini/Anthropic/OpenAI API key
2. **Install**: 
   ```powershell
   git clone https://github.com/allthingscode/gobot.git
   cd gobot
   .\scripts\build.ps1  # Windows
   # OR ./scripts/build.sh  # Linux/macOS
   ```
3. **Initialize**: `./gobot init`
4. **Configure**: Add your API keys to config.json
5. **Authorize** (for Google tools): `./gobot reauth`
6. **Run**: `./gobot run`

## What You Can Do With gobot

- Ask about your schedule: "What's on my calendar today?"
- Process emails: "Summarize unread emails from my boss"
- Manage tasks: "Add 'Review project proposal' to my task list"
- Get intelligent responses: Uses your conversation history for context-aware answers
- Run automated jobs: Set up daily briefings or weekly reports

## Platform Support

Works everywhere you do - **Windows** (with enhanced security), **Linux**, and **macOS**. Same binary, same features.

## Built for Humans Who Demand More

While other agents need constant babysitting and break with updates, gobot:
- Survives restarts and network failures with checkpointed state
- Scopes access to whitelisted users only (no unwanted guests)
- Uses pure Go (no mysterious native crashes)
- Maintains 80%+ test coverage for reliability
- Logs everything for easy troubleshooting

*Directed by the Architect. Executed by AI.*
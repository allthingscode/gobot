# gobot - The Agent Runtime

[![CI](https://github.com/allthingscode/gobot/actions/workflows/ci.yml/badge.svg)](https://github.com/allthingscode/gobot/actions/workflows/ci.yml)
[![Go Version](https://img.shields.io/github/go-mod/go-version/allthingscode/gobot)](go.mod)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**⚡ Built 100% by AI Agents** — gobot was designed, coded, and tested entirely by autonomous AI systems through the Crucible multi-specialist development framework. No human wrote a line of production code.

**👨‍💻 Architect: Matthew Hayes** — See [AUTHORS.md](AUTHORS.md) for professional background and expertise in agentic systems.

## What Is This Space?

[OpenClaw](https://github.com/openclaw/openclaw) is the canonical self-hosted AI personal assistant — a TypeScript bot that connects your messaging app to LLMs, tools, and memory. It has 347k+ stars and inspired a wave of Go and Rust reimplementations that trade OpenClaw's extensibility for a smaller binary, simpler deployment, or a tighter feature focus.

gobot is one of those reimplementations. It is a **single-user, self-hosted AI assistant** built on Telegram, written in pure Go, with no external database dependencies. If you already know you want a Go-native OpenClaw alternative, the comparison tables below will help you pick the right one.

---

## Where GoBot Wins

**Unique to gobot — no other Go alternative has these:**

- **📧 Deep Google Workspace** — Gmail, Calendar, and Tasks are first-class tools. Ask about your schedule, summarize emails, add tasks. No competitor in this space has native Google OAuth integration.
- **🌐 Headless Browser Automation** — Native integration with `chromedp` (pure Go, no CGO) allows the agent to navigate the web, extract text, and capture screenshots for vision models without external dependencies like Puppeteer.
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

| | **gobot** | **GoGogot** | **NeoClaw** | **PicoClaw** |
|---|---|---|---|---|
| **GitHub Stars** | pre-release | ~115 | — | 12,000+ |
| **Storage** | SQLite + chromem-go | In-process notes | SQLite | Not specified |
| **CGO** | None | None | None | None |
| **LLM providers** | 4 | 6+ | 4 | MCP |
| **Channels** | Telegram | Telegram | Telegram + CLI | 16+ (Slack, Discord…) |
| **Google Workspace** | Yes (Gmail, Cal, Tasks) | No | No | No |
| **HITL approvals** | Yes | No | No | No |
| **Windows-native secrets** | Yes (DPAPI) | No | No | No |
| **Users** | Single-user | Single-user | Single-user | Single-user |
| **Infra required** | None | None | None | None |
| **OTel tracing** | Yes | No | No | No |
| **Binary size** | ~30MB | 15MB | — | — (not published) |
| **Startup time** | <100ms | <100ms | — | <1s |

**[GoGogot](https://github.com/aspasskiy/GoGogot)** is the most similar project in spirit — lightweight, simple agent loop, Telegram-only, no external dependencies. It edges out gobot on provider count (6 vs 4) and has a smaller reported footprint (15MB binary, 10MB RAM idle). gobot edges out GoGogot on Google Workspace depth, HITL, Windows security, and observability.

**[NeoClaw](https://github.com/jigarvarma2k20/neoclaw)** covers similar ground (SQLite, Telegram, multi-LLM) and adds a CLI mode and SMTP email. gobot's advantage is Google OAuth depth vs. NeoClaw's SMTP-only email, plus HITL and Windows-native secrets.

**[PicoClaw](https://github.com/sipeed/picoclaw)** is the most popular Go alternative — see the deep-dive section below.

---

### PicoClaw Deep Dive

[PicoClaw](https://github.com/sipeed/picoclaw) is the most popular Go alternative, focusing on ultra-low footprint and MCP support. If you are evaluating both, here is the honest comparison.

#### PicoClaw is the better choice if you need:
- **Ultra-low footprint** — runs with <10MB RAM and starts up in under 1 second
- **Broad channel support** — 16+ messaging channels (Slack, Discord, Telegram, etc.) out of the box
- **Model Context Protocol (MCP)** — native support for the MCP tool ecosystem
- **A massive community** — over 12,000 stars on GitHub

#### gobot is the better choice if you need:
- **Deep Google Workspace Integration** — Gmail, Calendar, and Tasks are deeply integrated as first-class tools with automated OAuth flows
- **Human-in-the-loop (HITL) approvals** — gobot pauses and waits for your confirmation before executing irreversible actions
- **Strong Secrets Security** — OS-level encryption using Windows DPAPI instead of plaintext config files
- **Production-grade Observability** — built-in OpenTelemetry tracing, structured slog logging, and deep health diagnostics (`doctor` mode)

#### The honest tradeoffs

| | gobot | PicoClaw |
|---|---|---|
| RAM Footprint | ~23MB idle (cold) | <10MB idle |
| Startup Time | <100ms | <1s |
| Channels | Telegram | 16+ (Slack, Discord, Telegram, etc.) |
| Google Workspace | Deep (Gmail, Calendar, Tasks) | Not supported |
| HITL approvals | Yes | No |
| Secrets Security | Yes (Windows DPAPI) | No (Plaintext config / Env) |
| MCP Support | No | Yes |
| Observability | Full (OTel + slog + doctor) | Basic |

The RAM figure above is cold idle with an empty workspace (measured - see [Footprint](#footprint)). The comparison is partly apples-to-oranges: a stripped Go binary's mapped runtime baseline alone is ~15-20 MB resident, so sub-10 MB is not an architecture goal for gobot. That resident cost buys Google Workspace depth, HITL, in-process vector search, and full observability.

gobot's design principle is **stability and security for one user over scale for many**. Every architectural decision — SQLite over external servers, structured observability, and Windows-native security — is a deliberate trade of raw channel count for reliability, data security, and operational simplicity.

---

## Get Started

**What you need before you begin:**
- Go 1.26.3 or later
- A Telegram bot token — create one by messaging [@BotFather](https://t.me/botfather) and following the prompts
- Your numeric Telegram chat ID — message [@userinfobot](https://t.me/userinfobot) and it will reply with your ID (it looks like `123456789`)
- At least one LLM API key (Gemini, Anthropic, OpenAI, or OpenRouter)
- *(Optional)* Google OAuth2 "Desktop app" credentials for Gmail/Calendar/Tasks

**Fastest path — `gobot quickstart`:** After building (step 1 below), run `gobot quickstart`. It walks
you through the genuinely-required values (Telegram token, your chat ID, one LLM provider key), stores
secrets in the encrypted vault, writes the config for you, and finishes by verifying readiness — no
hand-editing JSON. When a value is wrong it prints a problem/fix/path message, not a raw error. It also
runs fully non-interactively for automation and never blocks on a non-TTY:

```bash
# interactive (prompts for each value; secrets are not echoed):
./bin/gobot quickstart
# non-interactive (scriptable — flags or matching env vars):
./bin/gobot quickstart --non-interactive \
  --telegram-token "$TELEGRAM_BOT_TOKEN" --allow-from 123456789 \
  --provider gemini --api-key "$GEMINI_API_KEY"
```

`quickstart` is idempotent — re-running it on a configured install is non-destructive — and it does not
start the agent (run `gobot run` when it reports "Ready"). Prefer to configure by hand? Follow the
manual steps below.

**Steps (manual configuration):**

1. **Build**:
   ```bash
   git clone https://github.com/allthingscode/gobot.git
   cd gobot
   # Windows (PowerShell) — produces bin/gobot.exe:
   .\scripts\build.ps1
   # Linux/macOS — produces bin/gobot:
   ./scripts/build.sh
   ```

2. **Initialize** — creates workspace directories and a starter config file:
   ```bash
   # Windows:
   .\bin\gobot.exe init
   # Linux/macOS:
   ./bin/gobot init
   ```

3. **Configure**: Edit `~/.gobot/config.json` (Windows: `%USERPROFILE%\.gobot\config.json`).

   Minimum working config — fill in the three `YOUR_*` placeholders:
   ```json
   {
     "agents": { "defaults": { "model": "gemini-2.5-flash", "provider": "gemini" } },
     "channels": {
       "telegram": {
         "enabled": true,
         "token": "YOUR_TELEGRAM_BOT_TOKEN",
         "allowFrom": ["YOUR_TELEGRAM_CHAT_ID"]
       }
     },
     "providers": { "gemini": { "apiKey": "YOUR_GEMINI_API_KEY" } },
     "runtime": { "storage_root": "" }
   }
   ```
   `allowFrom` is the whitelist — only chat IDs listed here can interact with the bot. Use the numeric ID from [@userinfobot](https://t.me/userinfobot). Adding your chat ID here is all that is needed: on startup gobot promotes every `allowFrom` ID into its access-control database automatically, so the single-user happy path does not need a separate `authorize` step.

   > **One location:** Set `GOBOT_HOME` and both the config file (`$GOBOT_HOME/.gobot/config.json`) and the data directory (`$GOBOT_HOME/data/`) live under it — nothing to keep in sync. `GOBOT_STORAGE` is an optional override only if you want data on a separate volume. See [docs/configuration.md](docs/configuration.md#path-resolution) for the precedence order.

4. **Google OAuth** *(skip if not using Gmail/Calendar/Tasks)*:
   - Follow the [Google Cloud Setup Guide](docs/google-setup.md) to create an OAuth2 "Desktop app" credential and enable the required APIs.
   - Save the downloaded JSON file to the `secrets/client_secrets.json` file under your data root (the `data:` path printed by `gobot init`; `$GOBOT_HOME/data/secrets/` by default).
   - Run:
     ```bash
     # Windows:
     .\bin\gobot.exe reauth
     # Linux/macOS:
     ./bin/gobot reauth
     ```

5. **Verify your setup**:
   ```bash
   # Windows:
   .\bin\gobot.exe doctor
   # Linux/macOS:
   ./bin/gobot doctor
   ```
   All critical checks should show `[OK]`. Warnings (`[WRN]`) are advisory only.

6. **Run**:
   ```bash
   # Windows:
   .\bin\gobot.exe run
   # Linux/macOS:
   ./bin/gobot run
   ```
   Send a message to your bot in Telegram — it should respond. Start with something simple like "Hello!" to confirm everything is working.

   > **Multi-user / escape hatch:** `gobot authorize <code-or-chat-id>` still authorizes a user that is not in `allowFrom` (e.g. someone pairing via a code). You only need it when granting access to an ID outside the `allowFrom` whitelist; the single-user happy path above does not.

## Documentation

- [Architecture](docs/architecture.md) — data flow, package responsibilities, key design decisions
- [Deployment & Persistence](docs/deployment.md) — guide for background service setup on Linux and Windows
- [Google Cloud Setup Guide](docs/google-setup.md) — step-by-step instructions for Gmail, Calendar, and Tasks integration
- [Security & Secrets](docs/security.md) — philosophy, secrets management, and encryption model
- [Configuration Reference](docs/configuration.md) — all config fields with defaults and examples
- [Locking Strategy](docs/locking-strategy.md) — session-scoped locking design and rationale
- [Verification](docs/verification.md) - local no-CGO checks and CI race-detector expectations


## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on our coding standards, build process, and how to submit pull requests.

### Coverage Gate

CI and Crucible full verification enforce an 80.0% minimum aggregate Go statement coverage floor over the scoped package set `./internal/... ./cmd/...`. To run the same check locally:

```powershell
New-Item -ItemType Directory -Force artifacts | Out-Null
go test -mod=readonly -coverprofile artifacts/coverage.out ./internal/... ./cmd/...
$coverageOutput = go tool cover -func artifacts/coverage.out
$coverageOutput
$coverage = [double](($coverageOutput | Select-String '^total:' | ForEach-Object { ($_ -split '\s+')[-1].TrimEnd('%') }))
$coverageText = $coverage.ToString("F1")
Write-Host ("Total coverage: {0}%" -f $coverageText)
if ($coverage -lt 80.0) { Write-Host ("Coverage {0}% is below 80.0% threshold" -f $coverageText); exit 1 }
```

### Race Detector

CI remains the required race-detector lane and runs `go test -race -mod=readonly ./...` on CGO-capable GitHub-hosted runners. Windows agents running with `CGO_ENABLED=0` should use the scoped non-race local verification path documented in [Verification](docs/verification.md); the pre-push hook warns when the race detector is unavailable for CGO reasons, then still fails on ordinary scoped test failures.

## What You Can Do With gobot

- Ask about your schedule: "What's on my calendar today?"
- Process emails: "Summarize unread emails from my boss"
- Manage tasks: "Add 'Review project proposal' to my task list"
- Get intelligent responses: Uses your conversation history for context-aware answers
- Run automated jobs: Set up daily briefings or weekly reports

## Platform Support

Works everywhere you do — **Windows** (with enhanced security), **Linux**, and **macOS**. Same binary, same features.

## Footprint

- **Binary size:** 28.98 MB, measured on April 26, 2026 with `go build -mod=readonly -trimpath -ldflags="-s -w" -o gobot-c191.exe ./cmd/gobot`.
- **Cold idle RSS:** ~23 MB Working Set (gateway only, Telegram off, empty workspace), measured 2026-06-24 via `Get-Process WorkingSet64` sampled to stability against an isolated empty `GOBOT_HOME`. Rises to ~24-25 MB with all in-process subsystems enabled (vector search, cron, heartbeat, headless browser, multi-user). The live Go heap is only ~3 MB; the rest is Go-runtime plus mapped binary baseline, so GC tuning is not a lever. Reproduce on any build from the boot DEBUG `gobot: boot memory` log or the `gobot doctor` memory line (both surface `runtime.ReadMemStats` heap/sys).
- **Warm/loaded RSS:** grows with the in-memory vector index (chromem-go holds embeddings resident). It is a function of corpus size, not a single number. Measured (R-015) against gobot's own vector store at the 768-dim embeddings it uses: **warm RSS ~= cold ~23 MB + (fact_count x ~3.6 KB) of live heap** - i.e. ~3.6 KB per stored fact (the 768 x 4 = 3,072 B embedding plus ~16% chromem document/map overhead). Worked points: ~27 MB at 1k facts, ~60 MB at 10k, ~170 MB of live index at 50k. Caveat: a full re-index transiently spikes process RSS to roughly 2-2.6x the live index size (chromem normalizes each embedding into a second slice) before the Go runtime returns the memory to the OS, so a bulk reindex of 50k facts can briefly show ~450 MB RSS. The figure is re-verifiable via `TestWarmFootprintPerVector` in `internal/memory/vector`. (An earlier unsourced "72.59 MB idle" figure reflected such a warm profile, not a cold start.)
- **Soft ceiling:** keep the stripped Windows binary under 40 MB; if it grows past that, investigate dependency or asset growth before shipping.

## Built for Humans Who Demand More

While other agents need constant babysitting and break with updates, gobot:
- Survives restarts and network failures with checkpointed state
- Scopes access to whitelisted users only (no unwanted guests)
- Uses pure Go (no mysterious native crashes)
- Maintains 80%+ test coverage for reliability
- Logs everything for easy troubleshooting

*Directed by the Architect. Executed by AI.*

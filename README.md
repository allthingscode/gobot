# gobot - The Strategic Agent Runtime

[![CI](https://github.com/allthingscode/gobot/actions/workflows/ci.yml/badge.svg)](https://github.com/allthingscode/gobot/actions/workflows/ci.yml)
[![Go Version](https://img.shields.io/github/go-mod/go-version/allthingscode/gobot)](go.mod)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

`gobot` is a high-performance, Go-native runtime designed to power the next generation of autonomous AI agents. It provides a secure, observable, and deeply integrated environment for LLMs to interact with the real world through Telegram, Google Workspace, and persistent long-term memory.

## What is gobot?

`gobot` is a Go-native AI agent runtime with a focus on personal productivity and strategic execution. It serves as a unified interface between large language models (like Gemini, Claude, and GPT) and your digital life. With native support for Telegram, Google Calendar, Tasks, and Gmail, `gobot` acts as an autonomous assistant capable of managing schedules, processing information, and executing workflows.

## Key Features

*   **Zero-Dependency Runtime:** Compiles to a single static binary for trivial deployment (no Python venvs, no CGO).
*   **Durable Session State:** Every interaction is checkpointed via a pure-Go SQLite implementation.
*   **Long-Term Memory (RAG):** Automatically indexes session history using SQLite FTS5 for semantic search.
*   **Autonomous Cron:** Built-in background job scheduler for recurring agent tasks.
*   **Strategic Hardening:** Integrated PII redaction, circuit breakers, and zero-trust security gates.
*   **Deep Workspace Integration:** First-class support for Google Calendar, Tasks, and Gmail.

## Requirements

- **Go 1.24+** (for building from source)
- **Windows** (recommended for DPAPI secret encryption) or Linux/macOS.
- **Telegram Bot Token**
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

### 2. Initialization
Run `gobot init` to create the storage structure. This automatically generates a template configuration.
```powershell
./gobot init
```

### 3. Configuration
Fill in your API keys in the generated `config.json` (usually located in `~/.gobot/config.json`).
- `apiKey`: Your Gemini/multi-model API key.
- `channels.telegram.token`: Your Telegram bot token.

### 4. Authorization
If using Google Workspace tools, run the interactive re-authorization:
```powershell
./gobot reauth
```

## Usage

*   **Start the Agent:** `./gobot run` (Starts the Telegram polling loop)
*   **Local Simulation:** `./gobot simulate "Your prompt here"`
*   **Diagnostics:** `./gobot doctor`
*   **View Logs:** `./gobot logs --lines 50 --filter ERROR`

## Architecture Overview

`gobot` follows a modular architecture where the core agent loop is decoupled from LLM providers and specific tools.

- **Agent:** Manages session lifecycle and tool dispatch.
- **Provider:** Abstracts different LLM APIs (Gemini, Anthropic, OpenAI).
- **Tools:** Modular implementations for Shell, Google APIs, and Memory.
- **State/Memory:** Durable persistence via pure-Go SQLite.

For a deeper dive, see [docs/architecture.md](docs/architecture.md).

## Project Structure

*   `cmd/gobot/`: CLI entry point and command wiring.
*   `internal/agent/`: Core agent session management and tool-dispatch logic.
*   `internal/context/`: Durable checkpointing and session state persistence (SQLite).
*   `internal/memory/`: Long-term memory indexing and RAG search components.
*   `internal/strategic/`: Strategic Edition mandates and output hardening.
*   `internal/google/`: Google OAuth2 and API service clients.

## Development & Testing

`gobot` targets 80%+ test coverage. Always run tests before submitting changes:
```powershell
go test ./...
```

---

*Directed by the Architect. Executed by AI.*

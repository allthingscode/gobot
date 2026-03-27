# Reference: OpenClaw Design for GoBot

## Objective
This document outlines key architectural patterns and features from the [OpenClaw](https://github.com/openclaw/openclaw) project that are relevant to the development of `gobot`. By aligning with these proven designs, `gobot` can ensure compatibility and leverage successful abstractions for AI agent orchestration.

---

## 1. Gateway Architecture (Control Plane)
The Gateway is a long-lived daemon that manages messaging surfaces and coordinates between clients and agents.

### Key Concepts:
*   **Single Source of Truth:** The Gateway owns all provider connections (WhatsApp, Telegram, etc.) and session state.
*   **WebSocket Protocol:** Clients (CLI, UI) and Nodes (device-local executors) connect via a typed WebSocket API.
*   **Role-Based Connections:**
    *   `operator`: Standard clients (CLI, Web UI).
    *   `node`: Devices (macOS, iOS, Android) that expose local capabilities like `camera.*` or `system.run`.
*   **Idempotency:** The wire protocol requires idempotency keys for side-effecting methods (`send`, `agent`) to handle retries safely.

### Relevance to GoBot:
*   `gobot` should aim for a similar "Gateway" mode (Phase 4) where it can run as a background service.
*   The Go implementation of the WebSocket server should use TypeBox-equivalent schemas (Go structs with JSON tags) for strict validation.

---

## 2. Pi Agent Runtime (The Loop)
The "Pi Agent" is the core runtime that executes the agentic loop: Intake → Context Assembly → Inference → Tool Execution → Persistence.

### Key Concepts:
*   **Serialized Execution:** Runs are serialized per session to prevent tool/state races.
*   **Embedded Runtime:** The Gateway calls an embedded agent loop (`runEmbeddedPiAgent`) which handles the actual model interaction.
*   **Streaming Lifecycle:** Events are streamed as `lifecycle` (start/end/error), `assistant` (text deltas), and `tool` (call/result).
*   **Hook System:** Extensive use of hooks (e.g., `before_prompt_build`, `after_tool_call`) allows plugins to intercept and modify behavior without changing core logic.

### Relevance to GoBot:
*   The `internal/strategic` and `internal/context` packages in `gobot` are the Go equivalents of this runtime.
*   GoBot's `run` command must implement a serialized queue per session.
*   The "Strategic Edition" mandates (CLIXML hardening, mandate injection) should be implemented as middleware/hooks in the Go loop.

---

## 3. Session & Memory Model
OpenClaw uses a sophisticated session management system to handle multi-user, multi-channel environments.

### Key Concepts:
*   **Session Keys:** Keys are formatted as `agent:<agentId>:<channel>:<type>:<id>`.
*   **DM Scoping:**
    *   `main`: All DMs share one context (best for single-user).
    *   `per-channel-peer`: Isolate context per user per channel (essential for privacy in shared bots).
*   **Durable Memory:** A "memory flush" turn reminds the model to write durable notes to the workspace before the context window is compacted.
*   **Auto-Compaction:** When the context window fills, the system automatically summarizes older turns to preserve the most relevant information.

### Relevance to GoBot:
*   `gobot/internal/context` (the SQLite store) must support these granular session keys.
*   GoBot should adopt the `per-channel-peer` isolation logic as a security standard for any non-CLI usage.
*   The checkpoint logic being ported should include "compaction" events to stay parity with OpenClaw/Nanobot.

---

## 4. Security & Sandboxing
OpenClaw prioritizes "strong defaults without killing capability."

### Key Concepts:
*   **Safe Defaults:** Dangerous tools (browser, system execution) are often restricted or run in sandboxes for non-main sessions.
*   **Docker Sandboxing:** Non-main sessions (groups/channels) can be forced to run bash/python inside isolated Docker containers.
*   **DM Pairing:** Unknown senders receive a pairing code and are blocked until manually approved via the CLI.

### Relevance to GoBot:
*   GoBot's `internal/doctor` should eventually check for risky security configurations (e.g., open DM policies).
*   The `internal/shell` package should support a "sandbox" mode, potentially leveraging Go's ability to interface with container runtimes.

# gobot - The Strategic Agent Runtime

`gobot` is a high-performance, Go-native runtime designed to power the next generation of autonomous AI agents. It provides a secure, observable, and deeply integrated environment for LLMs to interact with the real world through Telegram, Google Workspace, and persistent long-term memory.

## The Evolution: Why Go?

`gobot` represents a total architectural pivot from previous Python-based agent implementations (like the original `nanobot`). By moving to a Go-native stack, this project achieves a level of production stability and operational simplicity that interpreted languages cannot match.

### Why Go is Superior to Python for AI Runtimes:

*   **Zero-Dependency Deployment:** `gobot` compiles into a single, static binary. There are no virtual environments to manage, no `requirements.txt` version conflicts, and no "it works on my machine" packaging issues.
*   **True Concurrency:** Using Go's native `goroutines`, `gobot` seamlessly manages parallel tasks—polling Telegram, running cron-scheduled jobs, and executing background health heartbeats—without the complexity of Python's GIL or `asyncio` overhead.
*   **Strict Type Safety:** By enforcing types at compile-time, `gobot` eliminates entire classes of runtime errors (like the infamous Python `KeyError` or `AttributeError`) that frequently plague dynamic agentic loops.
*   **Resource Efficiency:** `gobot` starts instantly and operates with a fraction of the memory footprint required by a Python interpreter, making it ideal for long-running "always-on" agent services.

## Key Features

*   **Gemini-Native Intelligence:** Built directly on the `google.golang.org/genai` SDK, leveraging the full power of Gemini's reasoning and native tool-calling capabilities.
*   **Deep Workspace Integration:** Built-in, high-fidelity tools for managing Google Calendar, Google Tasks, and Gmail.
*   **Durable Session State:** Automated checkpointing via a pure-Go SQLite implementation, allowing agents to resume complex, multi-turn conversations across restarts.
*   **Retrieval-Augmented Generation (RAG):** A persistent long-term memory store that automatically indexes session history to provide agents with deep historical context.
*   **Operational Hardening:** Integrated "Strategic" features including log redaction for PII protection, circuit breakers for API resilience, and enforced system mandates.

## Designer’s Note: The AI-Driven Mandate

`gobot` is designed and directed by its sole architect, who serves as the project's designer and developer. 

**A defining characteristic of this project is that the designer has not written, and will never write, a single line of its code.**

`gobot` is an exercise in pure AI-driven software engineering. The architect provides the vision, the strategic direction, and the architectural constraints, while the implementation is executed entirely by AI agents. This ensures that the codebase remains perfectly idiomatic, consistently documented, and free from the "human-in-the-loop" inconsistencies of traditional development.

## Project Structure

*   `cmd/gobot/`: CLI entry point and command wiring.
*   `internal/agent/`: Core agent session management and tool-dispatch logic.
*   `internal/config/`: Configuration loading with BOM stripping and DPAPI support.
*   `internal/context/`: Durable checkpointing and session state persistence (SQLite).
*   `internal/memory/`: Long-term memory indexing and RAG search components.
*   `internal/strategic/`: Strategic Edition mandates and output hardening.
*   `internal/google/`: Google OAuth2 and API service clients.

## Getting Started

### Installation

Clone the repository and build the binary using the provided scripts:

```powershell
# On Windows
.\scripts\build.ps1

# On Linux/macOS
./scripts/build.sh
```

### Configuration

1.  **Initialize:** Run `./gobot init` to create the storage structure. This automatically generates a template at `~/.gobot/config.json`.
    *   The default storage root is now `~/gobot_data`.
    *   Use the `--root` flag to specify a custom path (e.g., `./gobot init --root D:\MyGobot`).
2.  **Configure:** Open `~/.gobot/config.json` and fill in your `apiKey` (Gemini) and `telegram.token`.
3.  **Authorize:** Link your Google Workspace account for Calendar, Tasks, and Gmail integration:
    *   Download your `client_secrets.json` from the Google Cloud Console.
    *   Place it in the `secrets` directory inside your storage root (e.g., `~/gobot_data/secrets/client_secrets.json`).
    *   Run `./gobot reauth` and follow the interactive prompts.

## Usage

*   **Run the Agent:** `./gobot run` (Starts the Telegram polling loop)
*   **Local Simulation:** `./gobot simulate "Your prompt here"`
*   **Diagnostics:** `./gobot doctor`
*   **Session Management:** `./gobot checkpoints` or `./gobot resume <thread-id>`

---

*Directed by the Architect. Executed by AI.*

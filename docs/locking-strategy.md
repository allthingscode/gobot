# Locking Strategy

## Overview

gobot handles many simultaneous workloads: Telegram direct messages from different users arrive concurrently, and cron jobs fire on independent schedules. Without explicit synchronization, concurrent writes to shared state (session history, message deduplication maps, scheduler counters) would produce data races and corrupted state. This document describes the synchronization primitives used throughout the codebase and the rationale for each choice.

## Per-Session Mutex (SessionManager)

`internal/agent/agent.go` maintains a `sync.Map` that maps each session key (a string identifying a user or chat) to a `*sync.Mutex`. When a new message arrives, `SessionManager` calls `loadOrStore` to retrieve an existing mutex or atomically create one. It then locks that mutex for the duration of the turn.

This design means different sessions run fully in parallel — the mutex for session A has no relationship to the mutex for session B. Within a single session, turns are serialized: the second message from a user waits until the first turn completes before executing. This prevents interleaved writes to per-session history and avoids out-of-order Gemini API calls for the same user.

## Singleton Initialization (sync.Once)

`internal/context/manager.go` exposes `GetCheckpointManager`, which opens the SQLite checkpoint database. A `sync.Once` ensures the database is opened exactly once per process lifetime, regardless of how many goroutines call `GetCheckpointManager` concurrently at startup. Subsequent calls return the same initialized instance without any lock overhead.

## Concurrent-Safe Message Deduplication (sync.Map)

`cmd/gobot/telegram.go` stores recently seen Telegram message IDs in `tgAPI.seenMsgs`, a `sync.Map`. The Telegram polling loop processes updates in a single goroutine, but cron dispatches and alert dispatches can call into the same deduplication check from different goroutines. `sync.Map` handles concurrent reads and writes without an explicit mutex and avoids false sharing on the common read-heavy path.

## Cron Scheduler Fan-Out

`internal/cron/scheduler.go` iterates over due jobs in its `poll` loop and dispatches each via `Dispatcher.Dispatch`. When multiple cron jobs are due at the same tick, they are dispatched concurrently using a `sync.WaitGroup`: each job is launched in its own goroutine and the scheduler waits for all goroutines to complete before updating `RunCount`, `SuccessCount`, and `FailureCount`. Keeping state updates after the `WaitGroup.Wait()` call means no inter-goroutine writes race on the job slice during dispatch.

## Read-Only Config

`internal/config/config.go` provides `config.Load()`, which reads configuration from disk and returns a `*Config` value. The config is loaded once at startup in `main` and passed to all subsystems as a read-only pointer. Because no code modifies the config struct after initialization, no mutex is required. The contract is enforced by convention: callers treat `*Config` as immutable.

## Rules for New Code

- Use per-resource locks, not a single global mutex. Locking the entire application to protect one field creates unnecessary contention.
- Prefer `sync.Map` for concurrent key-to-value maps where keys are added and read by multiple goroutines and deletions are rare.
- Use `sync.Once` for process-wide singletons (database handles, loaded configs, initialized caches).
- Never share a mutable slice across goroutines without explicit protection. Either protect with a `sync.Mutex`, copy the slice before passing it, or use a channel to transfer ownership.
- When spawning goroutines in a loop (fan-out), always use a `sync.WaitGroup` and update shared state only after `Wait()` returns.

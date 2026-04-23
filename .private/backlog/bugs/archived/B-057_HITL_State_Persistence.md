---
item_id: "B-057"
title: "HITL Pending Approvals Lost on Restart"
type: "Bug"
priority: "P2"
status: "Resolved"
target_specialist: "Architect"
created_at: "2026-04-22"
file_affinity: ["internal/agent/", "internal/context/"]
depends_on: ["B-056"]
---

## Overview
- **Objective:** Persist pending HITL approval requests across bot restarts so no approval is silently lost.
- **Problem Statement:** `HITLManager.pending` is an in-memory `map[string]chan bool`. If the bot restarts while a high-risk tool is awaiting user approval, the channel disappears. The Telegram approval button becomes a dead link; the tool either times out silently or never re-prompts. Identified in R-006 Gap 3.

## Root Cause
`internal/agent/hitl.go` — `pending` map is never flushed to disk. On `NewHITLManager()`, it initializes empty with no recovery of prior state.

## Context Files
- `internal/agent/hitl.go` — `HITLManager`, `RequestApproval`, `pending` map
- `internal/context/db.go` — SQLite layer for persistence reference
- `R-006_GoBot_Quality_Audit_20260421.md` — Gap 3 detail

## Proposed Fix
On restart, scan for unacknowledged HITL approval messages in the Telegram chat and either:
- Re-issue the approval request with a fresh button, OR
- Send a "this approval expired — please re-trigger the action" notice.

**Preferred approach:** Write pending approval requests to SQLite at creation time (`hitl_pending` table: `request_id`, `session_key`, `tool_name`, `created_at`, `expires_at`). On `NewHITLManager()`, query for unexpired rows and re-send approval prompts via Telegram.

## Acceptance Criteria
- [ ] Pending HITL requests survive a bot restart
- [ ] On restart, user receives a re-issued approval prompt for any unexpired pending request
- [ ] Expired requests (past `expires_at`) are cleaned up silently with a log entry
- [ ] `internal/agent` coverage ≥ 80% (currently unverified — add tests)
- [ ] No CGO; SQLite via `modernc.org/sqlite`

## Constraints
- No CGO
- SQLite schema changes must be additive (no breaking migrations)
- `-mod=readonly` for all commands

## Verification Command
```powershell
go test -mod=readonly ./internal/agent/... -cover
```

---

**Next Step** (filled by Groomer — post-deployment routing only):
gemini "[Role]: [Action] [ID/Subject]"

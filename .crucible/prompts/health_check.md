<!-- prompt_version: health_check-v1 -->
# Health check

```
"Health check"
```

**What it does**: Quick system health scan:
1. Git state (clean/dirty)
2. Go tooling (`go vet`, `go build`)
3. Lock file scan (stale locks?)
4. Handoff validation (handoff.json valid?)
5. Session state check
6. Backlog index scan
7. Minor issues count

**When to use**:
- Daily check
- Before starting work
- After major changes
- When system seems unstable

**Sample output**:
```
Health check results:
  Git: clean
  Go vet: clean
  Go build: clean
  Stale locks: none
  Handoff: missing (no active task)
  Session state: valid
  Issues: none
```


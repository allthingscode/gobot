---
item_id: "F-001"
title: "Add Health Endpoint"
status: "Ready"
priority: "P1"
# target_specialist: The first specialist to receive the task (typically Groomer or Researcher)
target_specialist: "Groomer"
# budget_tier: The token budget category (low, medium, high)
budget_tier: "low"
---

## Summary

Add a `GET /health` endpoint that returns `{ status: "ok", version: "<semver>" }`.

## Acceptance Criteria

- [ ] `GET /health` returns HTTP 200
- [ ] Response body matches `{ status: "ok", version: string }`
- [ ] Endpoint is covered by an integration test
- [ ] No authentication required

## Notes

Version should be read from `package.json` at startup.

<!-- prompt_version: doc_lint-v1 -->
# Doc lint

```
"Doc lint"
```

**What it does**:
1. Runs `go run scripts/doc_lint.go`
2. Parses output for failures
3. Categorizes: code hygiene, backlog hygiene, protocol issues
4. Deduplicates (one chore per category, not per instance)
5. Files backlog items for real issues
6. Logs trivial issues to `.crucible/session/global/minor_issues.log`

**When to use**:
- On push (CI)
- Weekly documentation audit
- Before releases

**What happens**: Doc lint runs automatically, creates C-XXX chores for code/documentation issues, doesn't require human intervention unless issues found


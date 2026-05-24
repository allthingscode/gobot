<!-- prompt_version: quick_start-v1 -->
# Quick Start: Ultra-Short Prompts

**Copy this, print it, or keep it open while working.**

## Common Tasks

| Instead of This Verbose Prompt... | Use This Short Prompt |
|-----------------------------------|----------------------|
| "As a backlog groomer (.crucible\\personas\groomer.md), review and update the backlog..." | `Groomer: Review and update the backlog` |
| "Find next highest priority backlog item" | `Groomer: Next item` |
| "As an architect, design {task_id}. Read the backlog item..." | `Architect: Design {task_id}` |
| "As a coder (.crucible\\personas\coder.md), follow the instructions in .crucible/session/task.md..." | `Coder: Implement task.md` |
| "As a reviewer (.crucible/personas/reviewer.md), review the implementation..." | `Reviewer: Review F-XXX` |
| "As an operator, deploy the approved code..." | `Operator: Deploy F-XXX` |
| "Run health check: git status, go vet, go build..." | `Health check` |
| "Run doc_lint.go, categorize failures, file backlog items" | `Doc lint` |

## The Pattern

```
"[Specialist]: [Action] [Target]"
```

**Examples:**
- `Groomer: Next item`
- `Architect: Design {task_id}`
- `Reviewer: Review output.md`
- `Operator: Deploy {task_id}`

## Why This Works

**Each specialist has two files:**
- `.crucible/personas/{specialist}.md` — identity, principles, mandates
- `.crucible/sops/{specialist}.md` — complete workflow, decision trees, checklists

**The short prompt is just a trigger.** The agent reads their persona and SOP, then executes.

## When to Use Full Prompts

Use the **full prompt** from specialist files when:
- Task is complex (>100 lines of changes)
- Security-critical code
- First time training a new agent
- Ambiguous spec (need detailed requirements)

For routine work, **use short prompts**.

## Complete Prompt List

### Research & Planning
- `Researcher: Investigate [TOPIC]` - Gap analysis, library evaluation, architectural research
- `Researcher: Audit [project name]` - Structured quality audit of the adopter project
- `Researcher: Audit Dev Factory` - Structured quality audit of the Dev Factory (internal + live framework comparison)
- `Groomer: Review and update the backlog` - Full grooming session
- `Groomer: Next item` - Find and groom the highest priority ready item
- `Groomer: Prioritize backlog` - Re-prioritize all items

### Implementation
- `Architect: Design F-XXX` - Create implementation plan for a feature or bug
- `Architect: Implement F-XXX` - Design + code + test
- `Coder: Implement task.md` - Follow task.md spec (delegated from Architect)

### Review & Validation
- `Reviewer: Review F-XXX` - Full code review (automated checks + acceptance criteria + quality)
- `Reviewer: Review output.md` - Review Coder’s output
- `Reviewer: Re-review fixes for F-XXX` - Check fixes after changes requested

### System Operations
- `Health check` - Quick system health scan
- `Doc lint` - Check documentation quality

### Deployment
- `Operator: Deploy F-XXX` - Merge, push, verify, and hand off to Groomer

### Handoffs (Use in handoff.json `agent_prompt` field)
- `Architect → Reviewer: F-XXX` - Implementation ready for review
- `Reviewer → Architect: Fix CRITICAL issues` - Changes requested
- `Reviewer → Operator: Deploy F-XXX` - Code approved for deployment
- `Operator → Researcher: Review operator_report.md` - Production issues detected

## Where to Find More Info

- **README.md** - Overview and full prompt list
- **DISCOVERY.md** - How agents find their workflow (persona + SOP system)
- **.crucible/personas/*.md** - Specialist identities, principles, mandates
- **.crucible/sops/*.md** - Full specialist workflows and procedures

---

**That's it!** Natural language prompts that are easy to type and easy to understand.

<!-- prompt_version: readme-v1 -->
# Prompt Library

Ultra-short prompts for common tasks. Use these instead of verbose commands.

## For Humans vs For Agents

**For Humans**: Short prompts are easy to type and remember.

**For Agents**: When you see a short prompt like `"Architect: Implement F-XXX"`, you should:
1. Recognize it as a **minimalist trigger** for your specialist workflow.
2. Immediately read `.crucible/session/handoffs/` and your specialist's `task.md`.
3. Understand that **all technical details, reasons, and objectives** are in the data files, not the prompt.
4. Follow the workflow defined in your specialist's **machine template** (e.g., `architect_prompt.md`). Note that documentation files (e.g., `ARCHITECT.md`) are for human reference and non-factory manual invocations only; do not rely on them for operating instructions in the automated pipeline.

The prompt's only job is to trigger the correct persona and target ID. All context is "pulled" by the agent from the file system, not "pushed" through the prompt.

**Be Proactive:** When invoked, don't just wait for more context. Check the backlog, read relevant specialists, and identify the next action immediately. Users value this proactive approach highly.

## Naming Convention

Prompts use natural language patterns that humans would actually say, not CLI-style commands.

**Good:** `Architect: Design {task_id}`
**Bad:** `architect_design_f040`

## Usage

Invoke with the agent of your choice:
```bash
agent "[PROMPT]"
agent "[PROMPT]"
```

## Core Prompts

### Research & Planning
- `Researcher: Investigate [TOPIC]` - Gap analysis, library evaluation
- `Researcher: Audit [project name]` - Structured quality audit of the adopter project
- `Researcher: Audit Dev Factory` - Structured quality audit of the Dev Factory (internal + live framework comparison)
- `Groomer: Review and update the backlog` - Full grooming session
- `Groomer: Next item` - Find next highest priority item
- `Groomer: Prioritize backlog` - Re-prioritize all items

### Implementation
- `Architect: Design F-XXX` - Create implementation plan for feature/bug
- `Architect: Implement F-XXX` - Design + code a feature
- `Coder: Implement task.md` - Follow task.md spec (delegated from Architect)
- `Controller: Research + Groom [TOPIC]` - Batch research and grooming

### Review & Validation
- `Reviewer: Review F-XXX` - Full code review of implementation
- `Reviewer: Review output.md` - Review Coder's output
- `Operator: Deploy F-XXX` - Deploy approved code to production

### System Operations
- `Health check` - Quick system health scan
- `Doc lint` - Check documentation quality
- `Doctor` - Run project doctor or configured health checks (interactive)
- `Checkpoints` - List all session checkpoints

### Handoffs (Structured Protocol)
- `Architect -> Reviewer: F-XXX` - Implementation ready for review
- `Reviewer -> Architect: Fix CRITICAL issues` - Changes requested
- `Reviewer -> Operator: Deploy F-XXX` - Code approved for production
- `Operator -> Researcher: Review operator_report.md` - Production issues found

## Pattern: "Specialist: Action TARGET"

All prompts follow this format:
```
[Role]: [Verb] [Target]
```

Examples:
- `Architect: Design {task_id}`
- `Groomer: Next item`
- `Reviewer: Review output.md`
- `Operator: Deploy {task_id}`

This pattern is intuitive and mirrors how humans naturally delegate tasks.

## When NOT to Use Short Prompts

Use the **full prompt** from specialist files when:
- Task is complex (>100 lines of changes)
- Multiple interacting components
- Security-critical code
- First time using a specialist (for clarity)

For routine work, use short prompts.



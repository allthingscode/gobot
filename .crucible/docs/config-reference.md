# Config Reference — `.crucible/config.yaml`

This is the authoritative reference for every key in `.crucible/config.yaml`. The machine-readable schema is at [`schemas/config.schema.json`](../schemas/config.schema.json). Validation is run by `powershell/validate-config.ps1`.

For a step-by-step setup guide see [GET_STARTED.md](GET_STARTED.md). For a worked example see [`examples/gobot/.crucible/config.yaml`](../examples/gobot/.crucible/config.yaml).

---

## Full annotated example

```yaml
# Installed Crucible root for this project. Must point inside this project.
# The orchestrator invokes <crucible_root>/powershell/factory.ps1.
crucible_root: ".crucible"

project:
  name: My API                            # required
  description: A Node/TypeScript REST API # required
  default_branch: main                    # required

paths:                                    # all required; all must start with .crucible/
  backlog:    .crucible/backlog
  session:    .crucible/session
  workspaces: .crucible/.agent-workspaces
  prompts:    .crucible/prompts
  personas:   .crucible/personas
  sops:       .crucible/sops

roles:                                    # all five roles required
  researcher:  { model_tier: fast }
  groomer:     { model_tier: fast }
  architect:   { model_tier: high-capability }
  reviewer:    { model_tier: high-capability }
  operator:    { model_tier: fast }

verification:
  quick:                                  # run after every Architect commit
    - name: test
      command: npm test
  full:                                   # run by Reviewer before approval
    - name: lint
      command: npm run lint
    - name: typecheck
      command: npx tsc --noEmit
    - name: test
      command: npm test

project_mandates:                         # required; at least one rule
  - No direct database access outside the repository layer.
  - All public functions must have JSDoc.
  - No console.log in production code; use the logger module.

file_affinity_examples:                   # optional; illustrative only
  - src/api/
  - src/services/
```

---

## Key reference

### `crucible_root` (required)

Path to the installed Crucible bundle for this project. In a typical install this is `.crucible`.

This value must point to the project's own `.crucible` framework folder. Applications that use Crucible must use their own installed `.crucible/` directory, rather than referencing absolute or external directories.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `crucible_root` | string | yes | Path to this project's installed Crucible bundle. The orchestrator invokes `<crucible_root>/powershell/factory.ps1` from the project directory to run the pipeline. |

**Examples**:

```yaml
# Standard install
crucible_root: ".crucible"
```

---

### `project` (required)

Identity and metadata for the target project.

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `name` | string | yes | Short display name. Appears in factory output and agent prompts. |
| `description` | string | yes | One sentence describing what the project does. |
| `default_branch` | string | yes | Branch the Operator merges to. Typically `main` or `master`. |

---

### `paths` (required)

All paths are relative to the project root and must begin with `.crucible/`. The defaults shown are the standard layout; change only if you have a structural reason to.

| Key | Default | Description |
|-----|---------|-------------|
| `backlog` | `.crucible/backlog` | Contains `BACKLOG.md`, `features/`, `bugs/`, `chores/`, `blocked/`. |
| `session` | `.crucible/session` | Runtime state: handoffs, scratchpads, event logs, global session state. Gitignored. |
| `workspaces` | `.crucible/.agent-workspaces` | Root for Architect git worktrees — one per in-flight task. Gitignored. |
| `prompts` | `.crucible/prompts` | Installed prompt templates for this project. Edit deliberately when the project needs customized behavior. |
| `personas` | `.crucible/personas` | Installed specialist persona definitions for this project. Edit deliberately when the project needs customized behavior. |
| `sops` | `.crucible/sops` | Installed standard operating procedures for this project. Edit deliberately when the project needs customized behavior. |

The installed files are the active runtime files.

---

### `roles` (required)

Assigns a model tier to each specialist. All five roles are required.

| Role | Recommended tier | Rationale |
|------|-----------------|-----------|
| `researcher` | `fast` | Broad coverage over deep reasoning; cost-sensitive. |
| `groomer` | `fast` | Structured output from clear instructions. |
| `architect` | `high-capability` | Multi-file reasoning, architectural decisions. |
| `reviewer` | `high-capability` | Deep code review, spec validation, regression detection. |
| `operator` | `fast` | Deterministic deployment steps; low ambiguity. |

**`model_tier` values:**

| Value | Maps to |
|-------|---------|
| `fast` | Cost-effective models (e.g. Haiku, Gemini Flash) |
| `high-capability` | High-reasoning models (e.g. Opus, Gemini Pro) |

The factory translates these tiers to CLI-specific model flags when assembling the next session command. Both values must be used at least once across the five roles — `validate-config.ps1` warns if either is absent.

---

### `verification` (required)

Shell commands the Reviewer runs to verify Architect work. These must match your project's language and toolchain exactly. The factory does not supply defaults — every project configures its own commands.

#### `verification.quick`

Run after every Architect commit. Kept fast — typically just the test suite.

```yaml
verification:
  quick:
    - name: test
      command: npm test
```

#### `verification.full`

Run by the Reviewer before approval. Should mirror your CI pipeline exactly. A change that passes `full` locally should also pass CI.

```yaml
verification:
  full:
    - name: lint
      command: npm run lint
    - name: typecheck
      command: npx tsc --noEmit
    - name: test
      command: npm test
```

Each step:

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `name` | string | yes | Label shown in factory output and Reviewer reports. |
| `command` | string | yes | Shell command to run. Must not contain scaffold placeholder values (`replace-with-...`). |

**Language examples:**

```yaml
# Go
verification:
  quick:
    - { name: test, command: "go test ./..." }
  full:
    - { name: vet,  command: "go vet ./..." }
    - { name: lint, command: "golangci-lint run ./..." }
    - { name: test, command: "gotestsum ./..." }

# Python
verification:
  quick:
    - { name: test, command: pytest }
  full:
    - { name: lint,     command: "ruff check ." }
    - { name: typecheck, command: "mypy ." }
    - { name: test,     command: pytest }

# Rust
verification:
  quick:
    - { name: test, command: "cargo test" }
  full:
    - { name: fmt,    command: "cargo fmt --check" }
    - { name: clippy, command: "cargo clippy --all-targets" }
    - { name: test,   command: "cargo test" }

# TypeScript / Node
verification:
  quick:
    - { name: test, command: "npm test" }
  full:
    - { name: lint,      command: "npm run lint" }
    - { name: typecheck, command: "npx tsc --noEmit" }
    - { name: test,      command: "npm test" }
```

---

### `project_mandates` (required)

A list of project-specific engineering rules that every specialist must respect. The Reviewer checks these during scope validation (checklist step 6). At least one entry is required.

```yaml
project_mandates:
  - No direct database access outside the repository layer.
  - All public functions must have JSDoc.
  - No console.log in production code; use the logger module.
```

Write mandates as declarative constraints, not instructions. The Architect reads them to understand what is forbidden; the Reviewer reads them to verify nothing was violated.

---

### `file_affinity_examples` (optional)

Illustrative examples of package paths or glob patterns used in `file_affinity` declarations. These are documentation for the Groomer, not enforcement — they show what path scopes look like in this project.

```yaml
file_affinity_examples:
  - src/api/
  - src/services/
  - tests/integration/
```

The Groomer declares actual `file_affinity` per task in the spec frontmatter. This field just provides examples to make those declarations consistent.

---

## Validation

Run before starting any pipeline work:

```powershell
powershell\validate-config.ps1 -ConfigPath .crucible\config.yaml
```

**Errors** (exit 2 — pipeline will not start):
- Any required section or field is missing
- Any path under `paths` does not start with `.crucible/`
- Any `verification` command still contains a scaffold placeholder (`replace-with-...`)

**Warnings** (exit 0 — pipeline starts, but check these):
- Neither `fast` nor `high-capability` is used by any role
- `project_mandates` still contains the scaffold placeholder text

---

## What to commit vs. ignore

The project-local `.crucible/.gitignore` (created by `init-project.ps1`) handles this automatically. See [git-policy.md](git-policy.md) for the full rationale.

**Principle**: configuration in, data out. Treat `.crucible/` like an app directory — commit how the system is set up, ignore its operational data.

| Path | Commit | Why |
|------|--------|-----|
| `.crucible/config.yaml` | Yes | Configuration |
| `.crucible/.gitignore` | Yes | The policy file itself |
| `.crucible/docs/` | Yes | Installed manuals, policies, and runbooks |
| `.crucible/personas/` | Yes | Installed specialist behavior |
| `.crucible/sops/` | Yes | Installed specialist workflows |
| `.crucible/prompts/` | Yes | Installed prompt templates |
| `.crucible/schemas/` | Yes | Installed validation schemas |
| `.crucible/powershell/` | Yes | Installed runtime scripts |
| `.crucible/backlog/` | No | Backlog items are data (tickets), not structure |
| `.crucible/session/` | No | Runtime state; regenerated each session |
| `.crucible/.agent-workspaces/` | No | Git worktrees; created and deleted by factory |
| `.crucible/locks/` | No | Ephemeral file locks |
| `.crucible/research/` | No | Generated artifacts |
| `.crucible/dev-logs/` | No | Generated artifacts |

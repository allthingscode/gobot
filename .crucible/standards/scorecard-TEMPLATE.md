# {Project} Quality Audit Scorecard

The standard `.crucible/sops/research-audit-project.md` measures your project against. The
SOP describes the process; this file describes the content.

**Copy this file to `.crucible/standards/scorecard-{project}.md` and edit the copy.** Leave
this template alone so bundle updates can refresh it. Commit your copy: a standard that is
not in review drifts silently, and one that is not in git disappears on the next clone with
nothing left to say what it used to require.

Delete any category that does not apply to your project and add the ones that do. Six
generic lenses are listed below as a starting point, not as a required set.

## Ratings

| Rating | Meaning |
|---|---|
| green | Meets the standard. |
| yellow | Partial gap. Works, but requires knowledge not written down anywhere. |
| red | Significant gap. Someone following the documentation gets a wrong or blocked result. |

Every yellow and red needs a specific gap narrative: what a person was told, what actually
happened, and what it cost them. "Documentation could be clearer" is not a gap narrative.

## Categories

Each category needs three things. Without them the auditor rates on taste rather than on
your standard, and two audits of the same code disagree.

- **Reads** - the files, commands or artifacts the auditor must look at.
- **Standard** - the condition that makes this category green, stated so that a reader can
  tell whether it holds.
- **Signals** - the concrete things that indicate it does not.

### 1. Correctness and reliability

**Reads:**

**Standard:**

**Signals:**

### 2. Security and secret handling

**Reads:**

**Standard:**

**Signals:**

### 3. Maintainability and architecture

**Reads:**

**Standard:**

**Signals:**

### 4. Test and verification quality

**Reads:**

**Standard:**

**Signals:**

### 5. Operational readiness

**Reads:**

**Standard:**

**Signals:**

### 6. User-facing or domain-specific quality

**Reads:**

**Standard:**

**Signals:**

## External research

By default the audit runs offline. Name here any category that requires current external
comparison - competitors, ecosystem, security advisories, dependency health, standards -
and the exact questions to answer for each source. The SOP will not go outside without
this section.

## Report template

The auditor writes to `.crucible/research/R-NNN_{project}_Quality_Audit_<YYYYMMDD>.md`.
Reports are output and stay in the ignored `research/` directory; this scorecard is the
input and belongs in git.

Required sections:

- Scope and project context, including the commit audited
- Verification commands run, with exit codes and results
- Summary table with every category rated
- Top gaps in priority order, each with its gap narrative
- What is holding up well
- Recommended backlog items with R-NNN IDs
- External sources consulted, if any
- Any missing project standards that made a category hard to evaluate

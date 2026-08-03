# Pipeline State Machine

The pipeline has five active phases plus one terminal state:

- `research`
- `grooming`
- `implementation`
- `verification`
- `deployment`
- `done`

## Transition Table

This table is the machine-parseable baseline transition topology:

```text
grooming -> implementation, research, verification, done
implementation -> verification
verification -> deployment, implementation
deployment -> grooming, done
research -> grooming
```

`deployment -> implementation` is a conditional edge. It is enabled only for
rework re-entry: either the newest non-pending gate decision for the task has
`outcome = rejected` and `rework_requested = true`, or the handoff has
`rebase_count >= 1`.

The topology source is [pipeline-dag.ps1](../powershell/lib/pipeline-dag.ps1).
The drift test keeps this document and the code in agreement.

## Per-Edge Requirements

The DAG only defines which target phases are topologically valid. Individual
transitions also enforce extra gates and data requirements. Examples include
scope requirements on `implementation -> verification`, isolated checks and
reviewer verification on `verification -> deployment`, commit hash and BACKLOG
integrity checks on `deployment -> done`, and `human_decisions` requirements on
`research -> grooming`.

Those guards currently live as scattered checks inside `Resolve-FactoryTransition`
in [factory-gates.ps1](../powershell/lib/factory-gates.ps1). They are not yet
centralized in the DAG library.

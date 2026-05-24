# Schemas

JSON schemas used by Crucible runtime validation.

| Schema | Validates | Used by |
|--------|-----------|---------|
| [`handoff.schema.json`](handoff.schema.json) | `.crucible/session/handoffs/{task_id}-{ts}.json` | `factory.ps1`, `validate-handoff.ps1` |
| [`config.schema.json`](config.schema.json) | `.crucible/config.yaml` | `validate-config.ps1` |

Human-readable reference: [`docs/config-reference.md`](../docs/config-reference.md)

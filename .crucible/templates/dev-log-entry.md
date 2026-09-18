# Dev Log Entry Template

The dev log is the public narrative of what shipped. It is written for someone outside
the project: name what changed and what it means for them, not which files moved.

Copy the block between the rules below, fill it in, and prepend it to
`UNPUBLISHED_LOGS.md` in your dev-logs directory. Newest entry first, with the `---`
separator kept between entries.

Do not include local filesystem paths, usernames, tokens, or internal tooling
directories. `validate-dev-log.ps1` rejects an entry that does, and it runs before you
publish.

---

## TASK-ID - One line naming the change, in the past tense

- What changed, and the behaviour a user or operator would actually notice.
- What was wrong before, stated concretely enough that the fix reads as the obvious fix.
- What was deliberately left out of scope, so nobody assumes it was covered.
- How it was verified, and the commit it landed on.

---

Three to six bullets is the usual length. If the task was strictly internal and has no
public-facing change, the entry is a heading, the date, and a single line saying so.

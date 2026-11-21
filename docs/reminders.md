# Telegram reminders

Ask Gobot to save a one-time reminder, for example: "Remind me to call Alex at
9 AM on January 2, 2027, UTC-06:00." Gobot uses `create_reminder`, then confirms
the saved ID and time with its explicit offset after the database commit. Ask
"List my reminders" to see IDs, saved times, delivery states, attempt counts and
failure codes. Ask "Cancel reminder <ID>" to cancel a pending reminder.

Provide a resolved future time and timezone offset. If a local time is ambiguous
at a daylight-saving transition, nonexistent during a clock jump, or missing its
timezone, Gobot must ask for clarification before saving it. The tool accepts
RFC3339 timestamps such as `2027-01-02T09:00:00-06:00` or
`2027-01-02T15:00:00Z`; it rejects local-only times, unknown `-00:00` offsets,
invalid dates, past times and unresolved phrases such as "tomorrow morning."
An explicit offset denotes an instant; it does not track later timezone changes.

Each reminder belongs to the authenticated sender in the original chat. Another
sender or another chat cannot list or cancel it. Within the same chat, an owner
can manage their reminders across topics; delivery always targets the topic in
which the reminder was created. Owner and destination come from trusted inbound
Telegram metadata. Gateway, cron and subagent requests cannot use reminder tools,
even if they supply a Telegram-looking session key or destination arguments.

Creation and cancellation use the usual tool policy, Telegram approval setting
and lifecycle hooks. Text must be nonempty, valid UTF-8 and at most 4096 bytes.
Stored text is sent literally without Markdown or HTML parsing. It cannot invoke
a model, dispatch a tool or execute instructions. Recurrence and snoozing are not
supported.

## Delivery and failures

Reminders use a dedicated pure-Go SQLite database at
`<storage_root>/reminders/reminders.db`. Keep this directory in durable storage
and include it in backups. Initialization failures stop application startup
visibly. The worker starts and stops with the app and joins its active send before
closing storage. It is independent of the cron scheduler and its `jobs.json`.
Run one Gobot runtime against a storage root; startup recovery assumes the prior
runtime has stopped.

Pending reminders survive restarts. Overdue work is picked up immediately on
startup, then polled approximately once per second. Each send rechecks the current
configured hard whitelist and database pairing. Revocation or a failed lookup
marks the reminder `failed` without sending it. Existing startup reconciliation
of configured whitelist entries into pairing still applies; removing access
durably requires updating the whitelist too.

States are `pending`, `dispatching`, `delivered`, `cancelled` and `failed`.
Cancellation that commits before the worker claims a reminder prevents delivery.
After a claim, cancellation reports "Delivery in progress" and cannot promise to
prevent the send. Terminal records remain visible to the owner for 30 days and
are then pruned. Pending and dispatching records never expire through retention.

Network timeouts, connection failures, Telegram rate limits and server errors
receive at most three total attempts, with one-minute and five-minute backoffs.
Attempts and the next attempt time are stored across restarts. Sends have a
20-second deadline; shutdown cancels an active send. Abandoned dispatches retain
their consumed attempt and saved backoff when recovered. Authorization failures,
permanent delivery errors and exhausted attempts become `failed`. List reminders
to inspect failure codes such as `authorization_failed`, `delivery_failed` and
`attempts_exhausted`; no automatic success is claimed for failed deliveries.
Structured worker outcome logs include ID, state, attempts and a safe failure
code, excluding reminder content and raw remote error bodies.

Telegram sends and SQLite commits are separate operations. A crash after Telegram
accepts a message but before the delivered state commits, or a timeout after
acceptance, can cause a duplicate on recovery or retry. Delivery is not exactly
once. Check the reminder ID and delivery history before recreating uncertain
work.

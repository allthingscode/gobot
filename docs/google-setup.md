# Google Cloud Setup Guide

Gobot integrates with Google Workspace to manage your Gmail, Calendar, and Tasks. This requires setting up OAuth 2.0 credentials in the Google Cloud Console (GCP).

## 1. Create a Google Cloud Project

1.  Go to the [Google Cloud Console](https://console.cloud.google.com/).
2.  Click the project dropdown at the top (next to "Google Cloud") and select **New Project**.
3.  Give it a name (e.g., `Gobot Assistant`) and click **Create**.
4.  Ensure your new project is selected in the project dropdown.

## 2. Enable APIs

You must enable the specific APIs for each service you want Gobot to use:

1.  Navigate to **APIs & Services > Library**.
2.  Search for and enable the following APIs:
    *   **Gmail API**
    *   **Google Calendar API**
    *   **Google Tasks API**

## 3. Configure OAuth Consent Screen

1.  Go to **APIs & Services > OAuth consent screen**.
2.  Select **User Type**:
    *   **Internal**: Recommended if you have a Google Workspace organization. This allows you to use the app without verification.
    *   **External**: Use this if you are using a personal `@gmail.com` account.
3.  Click **Create**.
4.  Fill in the **App information**:
    *   **App name**: `Gobot`
    *   **User support email**: Your email address.
    *   **Developer contact info**: Your email address.
5.  Click **Save and Continue**.
6.  **Scopes**: Click **Add or Remove Scopes** and manually add the scopes matching your `google_scopes` config (see [Customizing OAuth Scopes](#customizing-oauth-scopes)). The defaults are:
    *   `https://mail.google.com/` (full Gmail access)
    *   `https://www.googleapis.com/auth/calendar` (full Calendar access)
    *   `https://www.googleapis.com/auth/tasks` (full Tasks access)
7.  Click **Save and Continue**.
8.  **Test Users**: If you selected "External", you **must** add your own email address as a test user, or the authorization will fail.
9.  Click **Save and Continue**, then click **Back to Dashboard**.

## 4. Create OAuth 2.0 Client ID

1.  Go to **APIs & Services > Credentials**.
2.  Click **Create Credentials > OAuth client ID**.
3.  Select **Application type**: **Desktop app**.
    *   **Note**: "Desktop app" is the only supported application type for Gobot. Do not select "Web application" or other types.
4.  Name it `Gobot Desktop` and click **Create**.
5.  A dialog will appear showing your Client ID and Client Secret. Click **Download JSON** to save the file.

## 5. Install Credentials

1.  Rename the downloaded JSON file to `client_secrets.json`.
2.  Move it to the `secrets` directory under your resolved Gobot data root:
    *   **Path**: `{data root}/secrets/client_secrets.json`

    `gobot init` prints the resolved data root as `data:`. Gobot resolves that data root from
    `runtime.storage_root`, then `GOBOT_STORAGE`, then `$GOBOT_HOME/data`, then the fallback default
    `~/gobot_data`; see [Path Resolution](configuration.md#path-resolution). For example, the default
    fallback path is `~/gobot_data/secrets/client_secrets.json`, while a `GOBOT_HOME` install uses
    `$GOBOT_HOME/data/secrets/client_secrets.json`.
3.  Run the re-authorization command:
    ```bash
    # Windows:
    .\bin\gobot.exe reauth
    # Linux/macOS:
    ./bin/gobot reauth
    ```
4.  Follow the link in your terminal to authorize the app.

## Customizing OAuth Scopes

By default, `gobot reauth` requests full access to Gmail, Calendar, and Tasks. You can restrict the scopes by adding `google_scopes` to the `runtime` section of your `config.json`:

```json
"runtime": {
  "google_scopes": [
    "https://www.googleapis.com/auth/tasks",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/gmail.send"
  ]
}
```

The scopes you list here must also be added to your OAuth Consent Screen in the Google Cloud Console (Step 3.6 above). After changing this list, run `gobot reauth` to re-authorize with the new scopes.

**Default scopes** (when `google_scopes` is omitted):

| Scope | Access |
| :--- | :--- |
| `https://mail.google.com/` | Full Gmail |
| `https://www.googleapis.com/auth/calendar` | Full Calendar |
| `https://www.googleapis.com/auth/tasks` | Full Tasks |

## Troubleshooting & FAQ

### Rescheduling an existing event

Use `lookup_primary_calendar_events` to find identity-bearing matches, then
`reschedule_calendar_event` with `calendar_id: primary`, an exact `event_id`,
and explicit RFC3339 `start_time` and `end_time` (including offsets, such as
`2026-11-02T10:00:00-06:00`). End must be later than start as an instant.
Lookup returns up to 50 matches and can include unsupported events; use a more
specific query if needed. Titles alone never identify an event.

Rescheduling supports one non-recurring timed event on the authenticated primary
calendar. Shared calendars, recurring masters and instances, all-day events,
special event types, attendee changes and deletion are unsupported.

Enable `channels.telegram.hitl` and use an interactive Telegram session. The bot
fetches the exact event and displays its ID, primary calendar, title, location,
original offset-bearing times and proposed times. **Approve explicitly selects
that exact event and authorizes that time change**, including when several lookup
matches have the same title. Reject if the displayed event is not the one you
intended. Disabled or unavailable approval, unsupported channels, scheduled jobs,
policy denial, rejection and timeout prevent the write. Existing Telegram
whitelist and pairing requirements still apply.

Every reschedule sends update notifications to **all guests** (`sendUpdates=all`).
Only start and end are patched; other event fields are preserved. A concurrent
change causes an ETag conflict (HTTP 412): stop, fetch the event again and obtain
a new approval. There is no automatic retry. A transport error after dispatch
can leave the outcome unknown; inspect Calendar before attempting another
freshly approved change. Each operation needs its own approval.

Read-only or otherwise narrow OAuth grants and event permissions may deny lookup
or mutation (HTTP 401/403); the bot surfaces the failure without attempting to
reauthorize. The default Calendar scope allows writes, but custom grants may not.
A human must review scopes and run `gobot reauth` when appropriate; agents must
not run reauthorization or live smoke tests. Live testing, including checking
guest notification effects, is human-only.

The API's [patch contract](https://developers.google.com/workspace/calendar/api/v3/reference/events/patch)
and [conditional modification guide](https://developers.google.com/workspace/calendar/api/guides/version-resources)
describe field preservation, notifications and ETags.

### "Google hasn't verified this app" Warning
When you first authorize Gobot, you will likely see a warning screen from Google. Since you are running a private instance, this is expected.
1. Click **Advanced**.
2. Click **Go to Gobot (unsafe)**.
3. Grant the requested permissions.

### Why no Redirect URIs?
Gobot uses a "loopback flow" for authentication. When you select **Desktop app** in the Google Cloud Console, Google automatically allows redirects to `http://localhost`. You do not need to manually configure any redirect URIs in the console.

### 7-Day Token Expiration (External/Testing Mode)
If you are using a personal `@gmail.com` account (External User Type) and your app is in **Testing** mode:
*   **Expiration**: Your refresh token will expire every **7 days**. 
*   **Resolution**: You will need to run `gobot reauth` weekly to maintain the connection.
*   **Alternative**: If you have a Google Workspace organization, use the **Internal** user type to avoid this expiration.

### Refresh Token Revocation
If you need to force a full re-authorization, delete the Google OAuth token files under your resolved
data root before running `gobot reauth` again:

*   `{data root}/secrets/google_token.json`
*   `{data root}/secrets/gmail/token.json`

Use the `data:` path printed by `gobot init`, or resolve it from `runtime.storage_root`, `GOBOT_STORAGE`,
`$GOBOT_HOME/data`, then the fallback default `~/gobot_data` as described in
[Path Resolution](configuration.md#path-resolution).

## Internal vs. External Apps Summary

| Feature | Internal (Workspace) | External (Testing) |
| :--- | :--- | :--- |
| **User Base** | Organization users only | Any Google account (added as test user) |
| **Verification** | Not required | Not required (for up to 100 test users) |
| **Token Life** | Indefinite (until revoked) | **7 Days** |
| **Setup Complexity** | Low | Low |

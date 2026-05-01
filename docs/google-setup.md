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
6.  **Scopes**: Click **Add or Remove Scopes** and manually add these scopes:
    *   `https://www.googleapis.com/auth/gmail.readonly` (for reading and searching emails)
    *   `https://www.googleapis.com/auth/gmail.send` (for sending emails)
    *   `https://www.googleapis.com/auth/calendar.events` (for managing calendar events)
    *   `https://www.googleapis.com/auth/tasks` (for managing tasks)
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
2.  Move it to your Gobot secrets directory. By default, this is:
    *   **Windows**: `%USERPROFILE%\gobot_data\secrets\client_secrets.json`
    *   **Linux/macOS**: `~/gobot_data/secrets/client_secrets.json`
3.  Run the re-authorization command:
    ```bash
    # Windows:
    .\bin\gobot.exe reauth
    # Linux/macOS:
    ./bin/gobot reauth
    ```
4.  Follow the link in your terminal to authorize the app.

## Troubleshooting & FAQ

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
If you need to force a full re-authorization, delete the `token.json` file in your `gobot_data` directory before running `gobot reauth`.

## Internal vs. External Apps Summary

| Feature | Internal (Workspace) | External (Testing) |
| :--- | :--- | :--- |
| **User Base** | Organization users only | Any Google account (added as test user) |
| **Verification** | Not required | Not required (for up to 100 test users) |
| **Token Life** | Indefinite (until revoked) | **7 Days** |
| **Setup Complexity** | Low | Low |

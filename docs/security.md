# Security & Secrets Model

This document outlines the security philosophy and secrets management architecture of gobot.

## 1. Security Philosophy: Zero-Trust & Isolation

Gobot employs a defense-in-depth approach to security, ensuring that sensitive data is protected even if specific components are compromised.

### Core Principles
- **Hard Whitelisting:** Inbound Telegram messages are ignored unless the sender's Chat ID is explicitly listed in `channels.telegram.allowFrom`.
- **Pairing Gate:** Even whitelisted users must be "paired" in the local database to interact with the agent. Authorization is managed via `gobot authorize <code-or-id>`.
- **Human-in-the-Loop (HITL):** High-risk operations (e.g., executing shell commands, sending emails) require explicit user approval via Telegram before execution.
- **Pure-Go Architecture:** By avoiding CGO, the project eliminates many categories of memory-safety and injection vulnerabilities inherent in C libraries.
- **Isolated Storage:** Each user workspace (in multi-user mode) is isolated into separate directories and SQLite databases.

---

## 2. Secrets Management: The `secrets` Command

Gobot provides a dedicated CLI tool for managing sensitive keys (API tokens, OAuth credentials) using OS-level encryption. This removes the need to store plaintext secrets in `config.json`.

### CLI Commands
- `gobot secrets set <key> <value>`: Encrypts the value and stores it under the given key.
- `gobot secrets list`: Displays all stored secret keys (values are hidden).
- `gobot secrets get <key>`: Decrypts and prints the value for the specified key.
- `gobot secrets delete <key>`: Removes the secret from the store.

### Automated Fallback
The configuration system automatically looks for missing values in the secret store. For example, if `providers.gemini.apiKey` is empty in `config.json`, the agent will automatically try to fetch it from the secret store under the key `gemini_api_key`.

---

## 3. Storage & Encryption Mechanism

Secrets are stored in an encrypted JSON vault located at:
- **Default Path:** `{storageRoot}/workspace/dpapi_secrets.json`

### Platform Differences

Gobot adapts its encryption strategy based on the host operating system to maximize security without requiring manual key management where possible.

#### Windows (DPAPI)
- **Mechanism:** Uses `CryptProtectData` (Data Protection API).
- **Scope:** `CRYPTPROTECT_UI_FORBIDDEN` | `Current User`.
- **Pros:** Encryption is tied to the Windows User Account. No external key file is required; Windows handles the master key.
- **Cons:** Secrets cannot be decrypted if the file is moved to a different machine or user account.

#### Linux & macOS (AES-256-GCM)
- **Mechanism:** Authenticated AES-256-GCM encryption.
- **Master Key:** A unique 32-byte (256-bit) key is generated on first run.
- **Key Location:** `~/.config/gobot/encryption.key` (or `$GOBOT_ENCRYPTION_KEY_FILE`).
- **File Permissions:** Created with `0600` (read/write only by owner).
- **Pros:** Strong, industry-standard encryption for systems without a native DPAPI equivalent.

---

## 4. Criticality of `encryption.key` (Non-Windows)

On Linux and macOS, the `encryption.key` file is the **root of trust**.
- **Data Loss:** If this file is deleted, all stored secrets in `dpapi_secrets.json` become **permanently unrecoverable**.
- **Theft:** If an attacker gains access to this file, they can decrypt the entire secrets vault.
- **Migration:** To move Gobot to a new Linux/macOS machine, both `dpapi_secrets.json` AND `encryption.key` must be migrated together.

---

## 5. Backup & Restore (Linux/macOS)

On Linux and macOS the encryption key is stored separately from the encrypted vault. Backing up the data directory alone is **not enough** — without the key file, the vault cannot be decrypted.

### Default Locations
- **Linux:** `~/.config/gobot/encryption.key`
- **macOS:** `~/Library/Application Support/gobot/encryption.key`
- **Override:** Set `GOBOT_ENCRYPTION_KEY_FILE` to use a custom path (useful for tests, CI, or storing the key on removable media).
- **Vault:** `{storageRoot}/workspace/dpapi_secrets.json`

### What to Back Up
1. The encryption key file at the path above.
2. The encrypted vault at `{storageRoot}/workspace/dpapi_secrets.json`.

Store the two artifacts in separate locations whenever possible — keeping the key in a password manager and the vault in your normal data backup is a reasonable split.

### Restore on a New Machine
1. Install gobot and run `gobot init` to create the workspace skeleton.
2. Copy the backed-up `encryption.key` to the default location (or set `GOBOT_ENCRYPTION_KEY_FILE`).
3. Ensure file permissions are `0600` (owner read/write only): `chmod 600 ~/.config/gobot/encryption.key`.
4. Copy the backed-up `dpapi_secrets.json` into `{storageRoot}/workspace/`.
5. Run `gobot doctor` — the `encryption key` and `security store` checks should both report OK.
6. Run `gobot secrets list` to verify the vault decrypts successfully.

### Recovery if the Key is Lost
There is no recovery path. The 32-byte AES-256 key is the sole root of trust; without it the vault is permanently unrecoverable. The only remediation is to delete `dpapi_secrets.json`, run `gobot init` again to generate a fresh key, and re-set every secret with `gobot secrets set`.

---

## 6. Backup & Recovery (Windows DPAPI)

On Windows the secrets vault is encrypted with DPAPI (`CryptProtectData`) under **current-user scope** (see section 3). Unlike the Linux/macOS AES-256 design, there is **no portable key file** — the master key is held by Windows and bound to your user profile. This makes the Windows vault fundamentally non-portable, and backup/migration therefore works differently from the key-file model.

### DPAPI Scope & Limitations
- **Bound to the Windows user profile.** Secrets are encrypted with a master key derived from your Windows account credentials. Only the **same user, on the same machine** can decrypt `dpapi_secrets.json`.
- **Not portable.** Copying `dpapi_secrets.json` to a different machine, or to a different Windows account on the same machine, will fail to decrypt — `gobot secrets get` returns a `CryptUnprotectData` error. There is no key file you can carry over to fix this (contrast with the Linux/macOS `encryption.key`, which *is* portable if backed up — see sections 4–5).
- **Account name change vs. SID change.** DPAPI keys are tied to the user's security identifier (SID), not the display name. **Renaming** the Windows account (same SID, same profile) does **not** break decryption. **Creating a new account, migrating to a new profile/SID, or reinstalling Windows** generates a new SID and the vault becomes unrecoverable.
- **"Unrecoverable" means permanent.** Because Windows alone holds the master key and gobot keeps no escrow copy, a vault that can no longer be decrypted cannot be recovered by any gobot command or support path. The only remediation is to re-set every secret from your own offline record (below).

> Because the DPAPI vault cannot be carried to a new machine or account, the supported migration path is to **export the plaintext secrets before migrating and re-set them on the destination** — not to copy the encrypted file.

### Pre-Migration Backup
Before moving to a new machine or account, export every secret while you can still decrypt the current vault:

1. List the stored keys:
   ```powershell
   .\bin\gobot.exe secrets list
   ```
   ```
   gemini_api_key
   telegram_token
   ```
2. Export each value with `gobot secrets get <key>` and record it securely offline (a password manager entry or an encrypted note — **never** a plaintext file left on disk):
   ```powershell
   .\bin\gobot.exe secrets get gemini_api_key
   .\bin\gobot.exe secrets get telegram_token
   ```
   Each command prints the decrypted value on its own line.
3. Store the resulting key/value list in your secure offline location. This plaintext list — not the encrypted `dpapi_secrets.json` — is what you restore from.

**Windows backup checklist (what to retain):**
- [ ] The plaintext key/value list exported via `gobot secrets get` (store offline / in a password manager).
- [ ] Your Google OAuth client secrets (`{storageRoot}/secrets/client_secrets.json`) so you can re-run `gobot reauth`.
- [ ] Config: `~/.gobot/config.json` (or `$GOBOT_HOME`).
- [ ] Database files (`gobot.db`, `memory.db`) from your `GOBOT_STORAGE` directory if you want to preserve history.

> Do **not** rely on backing up `dpapi_secrets.json` itself — it cannot be decrypted on the new account or machine.

### Post-Migration Setup
On the destination machine, run gobot under the Windows account that will own it day-to-day (and that Task Scheduler will run as — see `docs/deployment.md`, "Security & DPAPI"):

1. Install gobot and run `gobot init` to create the workspace skeleton.
2. Re-set each secret from your offline list — this re-encrypts under the **new** account's DPAPI key:
   ```powershell
   .\bin\gobot.exe secrets set gemini_api_key <value-from-backup>
   .\bin\gobot.exe secrets set telegram_token <value-from-backup>
   ```
3. Verify the vault round-trips under the current account:
   ```powershell
   .\bin\gobot.exe secrets test
   ```
   A `Secrets pre-flight PASS for user "<you>" on windows.` line confirms encrypt/decrypt works in this user context.
4. Run `gobot doctor` — the `security store` check should report `using Windows DPAPI`.

### OAuth Re-Authorization (Telegram, Gmail, Gemini)
Two different credential types need attention after migration:

- **Gemini API key / Telegram bot token** are plain secrets — restoring them with `gobot secrets set` (above) is sufficient; no interactive re-auth is required.
- **Telegram user pairing** lives in the database, not the vault. If you did not migrate `gobot.db`, re-pair authorized users with `gobot authorize <code-or-chat-id>` (see section 1).
- **Google / Gmail OAuth tokens** are stored as separate token files (`{storageRoot}/secrets/google_token.json` and `secrets/gmail/token.json`), **not** in the DPAPI vault. These are user/consent-bound and must be regenerated on the new machine. With `client_secrets.json` in place, run:
  ```powershell
  .\bin\gobot.exe reauth
  ```
  This launches the interactive Google/Gmail authorization flow and writes fresh tokens. Confirm with `gobot doctor` — the `google token` and `gmail token` checks should report valid expiries.

### Failure Case: Secrets Lost or Account Deleted
If you skip the export step and only have the encrypted `dpapi_secrets.json`, or the original Windows account/profile is deleted or its SID changes (new account, profile migration, OS reinstall):
- `gobot secrets get` / `gobot secrets test` fail with a `CryptUnprotectData` error.
- There is **no recovery path** — the DPAPI master key is gone and gobot holds no backup of it.
- The only remediation is to start fresh: delete the now-undecryptable `dpapi_secrets.json`, run `gobot init`, and re-set every secret with `gobot secrets set` (and re-run `gobot reauth` for Google/Gmail). This is why the pre-migration export above is mandatory before any account or machine change.

---

## 7. Dependency & Vendoring Policy

**gobot does not vendor.** Do **not** run `go mod vendor`, and do not commit a
`vendor/` directory.

### Rationale
- There is no air-gapped, hermetic, or offline build requirement.
- `go.sum` already provides cryptographic supply-chain integrity for every
  dependency: it pins a verified hash per module version, so `go build` /
  `go test` / `govulncheck` resolve and verify deps straight from `go.mod`
  using the local module cache.
- CI builds with `-mod=readonly` directly from `go.mod`; it never checks out a
  `vendor/` directory.

### The footgun (B-001)
Go's default build mode is implicit `-mod=vendor` **whenever a `vendor/`
directory exists**. A leftover, stale `vendor/` tree therefore silently shadows
`go.mod`: a developer's plain `go build` / `go test` links the old pinned
versions in `vendor/` instead of the `go.mod`-resolved (and possibly patched)
ones, diverging from CI without any warning.

### Guards & remediation
- `gobot doctor` reports a **vendor policy** warning when a `vendor/` directory
  is present in the working tree.
- If you see that warning, **delete the local `vendor/` directory**. Because
  `vendor/` is gitignored, this is a local-only action — there is nothing to
  commit. Then rely on the module cache + `go.mod` as normal.
- Use `go mod verify` (and `govulncheck ./...`) to confirm cached modules match
  their `go.sum` hashes.

---

## 8. Security Best Practices Checklist
- [ ] **Avoid Plaintext:** Never store API keys or tokens directly in `config.json`. Use `gobot secrets set` instead.
- [ ] **Secure the Key (Linux/macOS):** Backup `~/.config/gobot/encryption.key` to a secure location (e.g., a password manager).
- [ ] **Minimize Whitelist:** Keep `channels.telegram.allowFrom` limited to only necessary users.
- [ ] **Enable HITL:** Keep `channels.telegram.hitl` enabled for any bot that has access to sensitive tools like `shell_exec`.
- [ ] **Regular Audits:** Use `gobot secrets list` periodically to review what secrets are stored and delete any that are no longer in use.
- [ ] **Environment Isolation:** Use different `storageRoot` directories for production and development to prevent secret leakage between environments.

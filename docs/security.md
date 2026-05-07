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

## 6. Security Best Practices Checklist
- [ ] **Avoid Plaintext:** Never store API keys or tokens directly in `config.json`. Use `gobot secrets set` instead.
- [ ] **Secure the Key (Linux/macOS):** Backup `~/.config/gobot/encryption.key` to a secure location (e.g., a password manager).
- [ ] **Minimize Whitelist:** Keep `channels.telegram.allowFrom` limited to only necessary users.
- [ ] **Enable HITL:** Keep `channels.telegram.hitl` enabled for any bot that has access to sensitive tools like `shell_exec`.
- [ ] **Regular Audits:** Use `gobot secrets list` periodically to review what secrets are stored and delete any that are no longer in use.
- [ ] **Environment Isolation:** Use different `storageRoot` directories for production and development to prevent secret leakage between environments.

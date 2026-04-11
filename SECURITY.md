# Security Policy

## Supported Versions

We currently only provide security updates and support for the **latest `master` branch**. Please ensure you are running the most recent code before reporting an issue.

| Version | Supported          |
| ------- | ------------------ |
| `master` | :white_check_mark: |
| Older   | :x:                |

## Reporting a Vulnerability

**DO NOT open a public issue for a security vulnerability.**

If you discover a security vulnerability in gobot, please report it via one of the following methods:
- Send a direct email to **admin@allthingscode.com**
- Create a [GitHub Private Advisory](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)

## Response SLA

This project is maintained on a best-effort basis. We will make every effort to acknowledge your report within **7 days**. Once the vulnerability is confirmed, we will work on a patch and notify you when it is resolved.

## Scope

### In Scope
- Authentication/Authorization bypasses
- Secret leakage (e.g., DPAPI bypass, exposed API keys)
- Injection vulnerabilities (e.g., SQL injection in SQLite memory store)
- Cross-user data leaks in multi-user setups

### Out of Scope
- Denial of Service (DoS) attacks on personal/self-hosted instances
- Issues requiring physical access to the host machine
- Theoretical issues without a reproducible proof of concept
- Vulnerabilities in third-party upstream services (e.g., Telegram, Google APIs), unless caused by our misuse

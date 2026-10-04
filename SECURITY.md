# Security policy

This is a small, independent local utility. The current release is the supported version; see [SECURITY_REVIEW.md](SECURITY_REVIEW.md) for the review scope and known limitations.

If you find a vulnerability, use this repository's **Security → Report a vulnerability** private reporting option. Include reproduction steps, the app/Codex/macOS versions and a minimal synthetic example. Do not put credentials, session logs, real task titles, usage snapshots or other private data in a public issue.

The app relies on your installed, trusted Codex CLI and local account environment. A process already running as your macOS user is outside its isolation boundary. The distributed app is ad-hoc signed and not notarized.

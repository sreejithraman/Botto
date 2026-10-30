# Security reporting

Use the repository's **Security → Report a vulnerability** action when private
vulnerability reporting is enabled. If that action is unavailable, open an
issue asking the maintainer for a private reporting channel. Include no
vulnerability details, credentials, or private chat content in that issue.

A useful private report includes the affected revision, reproduction steps,
expected and observed behavior, and a small proof using disposable data.
Sanitize logs and attachments before sharing them.

## Scope and support

Reports about connection authentication, credential storage, chat isolation,
untrusted previews, downloads, and approval handling are welcome. Include the
Hermes version when a report crosses the client/server boundary.

During 0.x development, security fixes target `main` and the latest release.
Include the affected app version or commit in your report.

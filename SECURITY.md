# Security Policy

## Supported Versions

Until the first stable release, only the latest revision on `main` is supported.

## Reporting

After publication, report vulnerabilities through GitHub private vulnerability
reporting when available. Do not include secrets, authentication files, or
private command lines in a public issue.

## Trust Boundary

This project is an output optimizer, not a command authorization system. Its
Hook intentionally fails open: malformed input, RTK failures, or unsupported
syntax leave the original command unchanged. Codex approval and sandbox policy
remain the enforcement boundary.

The installer writes only the selected Codex home, and the uninstaller removes
only this project's registration and installed script. Both preserve unrelated
hooks and create backups before replacement.

# Release Checklist

## Source

- [ ] Version is valid SemVer and `CHANGELOG.md` is updated.
- [ ] English and Chinese README, SPEC, compatibility, and upstream docs agree.
- [ ] No active Codex configuration, auth file, machine path, or generated fixture is tracked.

## Automated Verification

- [ ] `tests/run-all.ps1` passes on the release commit.
- [ ] PSScriptAnalyzer `1.25.0` passes with the checked-in settings.
- [ ] actionlint `1.7.12` validates both GitHub Actions workflows.
- [ ] CI passes on `windows-latest` with pinned RTK version and checksum.
- [ ] `scripts/package-release.ps1` produces the expected ZIP and matching SHA-256.

## Real Codex Gate

- [ ] Review the active model provider, then run `scripts/run-real-codex-e2e.ps1 -AllowProviderRequest`.
- [ ] Confirm the selected Codex home's original Hook files are hash-restored after the run.
- [ ] Raw `git status` executes through that exact path.
- [ ] `Get-Content` remains native.
- [ ] Mixed Preserve/HookRewrite/Delegate behavior is observed.
- [ ] Object pipeline causes zero RTK rewrite calls.
- [ ] Missing bound RTK fails open.
- [ ] Approval/sandbox behavior still applies after rewrite.
- [ ] Record Windows, PowerShell, RTK, Codex versions and date in compatibility docs.

## Remote Actions

- [ ] Review local Git status and commit history.
- [ ] Push the repository only after owner approval.
- [ ] Create upstream issues only after owner approval and a duplicate search.
- [ ] Push a `v*` tag only after every gate above passes.

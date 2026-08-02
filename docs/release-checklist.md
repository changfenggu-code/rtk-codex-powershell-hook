# Release Checklist

## Source

- [ ] Version is valid SemVer and `CHANGELOG.md` is updated.
- [ ] English and Chinese README, SPEC, compatibility, and upstream docs agree.
- [ ] No active Codex configuration, auth file, machine path, or generated fixture is tracked.
- [ ] Installer, uninstaller, and evaluator leave RTK configuration untouched.

## Automated Verification

- [ ] `tests/run-all.ps1` passes on the release commit.
- [ ] PSScriptAnalyzer `1.25.0` passes with the checked-in settings.
- [ ] actionlint `1.7.12` validates both GitHub Actions workflows.
- [ ] Native reads, mixed plans, object pipelines, and missing-RTK fail-open cases pass in the deterministic suites.
- [ ] Already-prefixed `rtk cat`, `rtk git`, explicit `rtk read`, and mixed commands bind correctly in absolute mode.
- [ ] A direct `AGENTS.md` include of `RTK.md` warns without modifying either instruction file.
- [ ] `scripts/evaluate-read.ps1` passes its safety and structured-output tests against the pinned RTK version.
- [ ] CI passes on `windows-latest` with pinned RTK version and checksum.
- [ ] `scripts/package-release.ps1` produces the expected ZIP and matching SHA-256.

## Real Codex Gate

- [ ] Run `scripts/run-real-codex-e2e.ps1` with Node.js available.
- [ ] Confirm the fixture bound only to `127.0.0.1` and the disposable Codex home was removed.
- [ ] Confirm the default install rewrote raw `git status --short` to bare `rtk git status --short`.
- [ ] Confirm deterministic tests cover explicit, PATH-collision, Cargo, and Scoop absolute bindings.
- [ ] Confirm the policy phase declined the rewritten command under `workspace-write`/`never`.
- [ ] Confirm the fixed-command execution phase completed and returned `function_call_output`.
- [ ] Record Windows, PowerShell, RTK, Codex versions and date in compatibility docs.
- [ ] Record the read sample hash and results without treating timings as portable thresholds.

## Remote Actions

- [ ] Review local Git status and commit history.
- [ ] Push the repository only after owner approval.
- [ ] Create upstream issues only after owner approval and a duplicate search.
- [ ] Push a `v*` tag only after every gate above passes.

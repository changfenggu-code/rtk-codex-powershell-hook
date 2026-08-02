# RTK Codex PowerShell Hook

A deterministic Windows/PowerShell adapter that rewrites Codex `Bash` tool
commands through [RTK](https://github.com/rtk-ai/rtk) before execution.

Codex now supports transparent `PreToolUse` rewrites through
`permissionDecision: "allow"` plus `updatedInput`. RTK 0.44.2 exposes the
rewrite registry through `rtk rewrite`, but its documented Codex integration is
still instruction based. This project connects those two surfaces without a
model retry and adds conservative PowerShell AST handling.

This is an independent community project. It is not affiliated with or
endorsed by OpenAI or the RTK maintainers.

[中文说明](README.zh-CN.md) | [Specification](docs/SPEC.md) |
[Compatibility](docs/compatibility.md) |
[Command evaluation](docs/command-evaluation.md) |
[Read evaluation](docs/read-evaluation.md) |
[Upstream roadmap](docs/upstream-roadmap.md)

## Scope

- Native Windows and PowerShell only.
- Codex `PreToolUse` calls whose canonical `tool_name` is `Bash`.
- Transparent command mutation, not deny-and-retry prompting.
- Output optimization only. Codex approval and sandbox checks still apply.

Linux, macOS, WSL, and other agent integrations belong in a native RTK Codex
hook upstream rather than in this PowerShell compatibility layer.

## Requirements

- Windows
- PowerShell 7 (`pwsh.exe`)
- RTK with `rtk rewrite` support; RTK `0.44.2` is the validated baseline
- Codex with `PreToolUse.updatedInput` support; Codex CLI `0.146.0` is the
  validated baseline

## Install

Preview every target without writing:

```powershell
.\install.cmd -WhatIf
```

Install with automatic RTK discovery:

```powershell
.\install.cmd
```

Without `-RtkPath`, the installer first checks applications named `rtk` in
PowerShell execution order. A compatible effective `PATH` command stays a bare
`rtk` invocation. If `PATH` has no compatible RTK, the installer checks bounded
Cargo locations, the official Windows local-bin convention
`%USERPROFILE%\.local\bin\rtk.exe`, and then bounded Scoop locations. The
validated fallback is bound by absolute path. It never recursively scans a
drive, invokes Homebrew or a Unix installer, or edits `PATH`.

Bind a specific RTK executable by absolute path:

```powershell
.\install.cmd -RtkPath 'C:\Tools\rtk.exe'
```

The installer validates `rtk --version` and `rtk rewrite --help`, copies the
Hook atomically, and structurally merges one registration into
`~/.codex/hooks.json`. It preserves unrelated hooks and creates timestamped
backups under `~/.codex/backups/rtk-codex-hook/`.

The installer does not edit `%APPDATA%\rtk\config.toml` or any other RTK
configuration. An optional RTK `exclude_commands = ["cat", "head", "tail"]`
setting can protect other integrations, but this Hook enforces its read boundary
independently.

The transparent Hook replaces RTK's instruction-only `Always prefix shell
commands with rtk` integration. If `~/.codex/AGENTS.md` includes `RTK.md`,
remove that include before restarting Codex so the Hook receives the original
command. The installer warns about a direct include but never edits `AGENTS.md`
or `RTK.md`.

Restart Codex after installation. With the normal `PATH` mode, a raw
`git status` tool call should become `rtk git status`. Explicit, collision, and
fallback installations use PowerShell's call operator with the validated
absolute path instead.

Use `-CodexHome <absolute-or-relative-directory>` to install into a disposable
or non-default Codex home. Volume roots are rejected.

## Uninstall

Preview:

```powershell
.\uninstall.cmd -WhatIf
```

Remove only this Hook script and registrations:

```powershell
.\uninstall.cmd
```

Uninstall also creates a timestamped backup and leaves all unrelated hooks,
configuration, RTK files, and Codex files untouched.

## Rewrite Model

The Hook parses the command with PowerShell's official AST and plans each
eligible top-level extent as one of three dispositions:

- `Preserve`: reads, redirections, variables, object pipelines, dynamic command
  resolution, and unsupported structures remain byte-for-byte unchanged.
- `HookRewrite`: proven PowerShell mappings such as `Select-String`,
  `Get-ChildItem`, and `Get-Content | Select-String` are converted locally.
- `DelegateToRtk`: native commands supported by RTK are sent to `rtk rewrite`.

Zero delegates start zero RTK processes. One delegate starts one process. If
all top-level commands are delegates, the complete source is rewritten in one
call. A mixed plan copies only delegate slots into one GUID-delimited batch,
validates RTK's returned AST, then maps each accepted slot back to its saved
source extent. One Hook invocation therefore starts RTK at most once.

Examples:

```powershell
git status; cargo check
# -> rtk git status; rtk cargo check

Get-Content Cargo.toml | Select-String workspace
# -> rtk rg -n -i -e 'workspace' -- 'Cargo.toml'

Get-ChildItem src -File | Select-Object Name,Length | Format-Table
# -> preserved; object semantics stay in PowerShell and RTK is not started

Get-Content -Raw Cargo.toml
# -> preserved; ordinary reads are outside automatic RTK rewriting
```

Generated `rtk read` candidates are rejected per slot. Explicit user-authored
`rtk read` commands remain available. In an absolute-bound installation, one
final AST pass also qualifies static `rtk` and `rtk.exe` commands that were
already present in the input; those commands do not need another registry
rewrite attempt.

The examples show the default bare `PATH` mode. An explicit or fallback-bound
installation replaces each generated `rtk` command with
`& '<validated-absolute-path>'`.

The planner is deterministic and stateless. It does not persist command text,
rewrite outcomes, or object-pipeline classifications, and it does not learn
future rewrites from speculative RTK results.

## Multiple Rewriting Hooks

Current Codex chooses the `updatedInput` from the Hook that completes last when
multiple matching `PreToolUse` handlers return rewrites. Completion order is a
race, not configuration order. The installer warns about other command Hooks
that may match `Bash`, but cannot prove whether they emit `updatedInput`.

Use one rewriting Hook per `Bash` tool path. Observability and policy Hooks that
do not return `updatedInput` can coexist. See
[the upstream roadmap](docs/upstream-roadmap.md) for the exact current behavior
and proposed deterministic alternatives.

## Test

Run the same suite used by CI:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\run-all.ps1
pwsh -NoLogo -NoProfile -NonInteractive -File .\scripts\run-lint.ps1 -Bootstrap
pwsh -NoLogo -NoProfile -NonInteractive -File .\scripts\run-actionlint.ps1 -Bootstrap
```

The suites cover AST rules, Codex JSON protocol, RTK invocation counts,
generated-command smoke tests, path quoting, missing-RTK fail-open behavior,
safe install/upgrade/uninstall, the isolated command and `rtk read` evaluators,
static safety checks, and release packaging.

Reproduce the project-wide RTK command inventory and output-savings matrix:

```powershell
pwsh -NoProfile -File .\scripts\evaluate-command-savings.ps1 `
  -EvaluationProfile Full -Iterations 3
```

The [command evaluation report](docs/command-evaluation.md) classifies all 79
commands exposed by RTK 0.44.2 and measures every command family applicable to
this repository. The selected task-equivalent command output saved 40.7% of
estimated tokens in the documented reference run. This is not a whole-session
rate: native reads and other preserved output dilute real tool-output savings,
and individual commands can be neutral or regress.

Reproduce the read-policy measurements without modifying the user RTK tracking
database or configuration:

```powershell
pwsh -NoProfile -File .\scripts\evaluate-read.ps1 -File .\rtk-codex-hook.ps1
```

See [the read evaluation report](docs/read-evaluation.md) for the RTK 0.44.2
results and interpretation.

Build a release archive and checksum:

```powershell
pwsh -NoProfile -File .\scripts\package-release.ps1 -Version 0.1.0
```

Run the real Codex runtime gate against a deterministic loopback provider:

```powershell
pwsh -NoProfile -File .\scripts\run-real-codex-e2e.ps1
```

The gate creates a disposable `CODEX_HOME` and starts a local Responses API
fixture bound only to `127.0.0.1`. It neither reads the active Codex provider or
authentication files nor sends data outside the machine. The first phase proves
that Codex policy still blocks the rewritten command; the second phase executes
only the fixed `git status --short` command and verifies that its output returns
through the real Codex runtime. Node.js is required for the local fixture.

## Security Model

The Hook never executes the input command. It only parses strings, calls the
installer-bound RTK executable with `rewrite`, validates the returned command,
and prints Codex protocol JSON. It does not write files, download code, start
background processes, or replace Codex's approval/sandbox policy.

All Hook failures exit `0` without stdout so Codex can execute the original
command. That fail-open behavior is appropriate for an output optimizer, not a
security boundary. Do not use this project to enforce command-denial policy.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [DISCLAIMER.md](DISCLAIMER.md).

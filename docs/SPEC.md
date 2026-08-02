# RTK Codex PowerShell Hook Specification

## 1. Normative Language

`MUST`, `SHOULD`, and `MAY` are normative. "Preserve" means the Hook exits `0`
without stdout so Codex executes the original input.

## 2. Purpose

The Hook reduces model-visible command output by transparently routing proven
Windows development commands through RTK. It is not a shell translator,
security sandbox, permission source, or generic PowerShell optimizer.

## 3. Codex Protocol

The Hook MUST process only `PreToolUse` payloads whose canonical `tool_name` is
`Bash` and whose `tool_input.command` is a non-empty string. Input larger than
`1 MiB`, malformed JSON, missing fields, and unsupported tools MUST fail open.

A rewrite MUST return:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "Accept RTK input rewrite; Codex still applies its own approval and sandbox policy",
    "updatedInput": {
      "command": "rewritten command"
    }
  }
}
```

All original `tool_input` fields other than `command` MUST be retained.
`permissionDecision: "allow"` accepts the mutation; it MUST NOT be described or
implemented as bypassing later Codex approval or sandbox evaluation.

No-op and failure responses MUST write nothing to stdout. The production Hook
MUST exit `0` on every internal failure.

## 4. Planner

The implementation MUST parse the complete source with
`System.Management.Automation.Language.Parser::ParseInput`. Eligible top-level
AST extents are classified before any RTK process starts:

- `Preserve`: no mutation and no RTK delegation.
- `HookRewrite`: a complete, locally proven PowerShell-to-RTK mapping.
- `DelegateToRtk`: an unchanged source extent passed to RTK's registry.

The planner MUST preserve malformed syntax, redirections, assignments,
subexpressions, background pipelines, runtime variables, unsupported
parameters, non-filesystem providers, and commands affected by function, alias,
or module-resolution mutation.

The planner MUST be stateless across Hook invocations. It MUST NOT persist input
commands, RTK results, normalized command shapes, or learned classifications.
New coverage requires an explicit source-controlled rule and corresponding
positive and rejection tests.

## 5. Local Mappings

Local rewrites MAY cover only statically proven forms of:

- `Select-String` to `rtk rg`, including explicit case, literal, context,
  list/quiet/negative, and supported PCRE2 forms;
- `Get-ChildItem` to `rtk ls` or `rtk find` where the result is direct
  model-facing text;
- complete `Get-Content <one file> | Select-String <static pattern>` pipelines.

Unknown parameters MUST reject the candidate. Paths and patterns MUST be
static. PowerShell arguments MUST use single-quote escaping. Known incompatible
.NET regular expressions, including balancing groups, MUST be preserved.

## 6. Object Semantics

PowerShell object pipelines MUST be preserved before RTK invocation unless the
complete pipeline has a proven one-command mapping. This includes pipelines
using `Select-Object`, `Where-Object`, `ForEach-Object`, `Sort-Object`,
`Group-Object`, `Measure-Object`, formatting commands, `Get-FileHash`, export
commands, and conversion commands.

For example, `Get-ChildItem | Get-FileHash` cannot become `rtk ls | Get-FileHash`
because `FileInfo` objects would become display text. A preserved object
pipeline MUST trigger zero RTK processes.

## 7. Read Boundary

Automatic rewriting MUST preserve `Get-Content`, `gc`, `cat`, `type`, `head`,
and `tail` as standalone reads. A normal `rtk read` does not preserve strict
PowerShell line-window semantics and does not necessarily reduce output.

Any RTK-generated candidate containing `rtk read` MUST be rejected per slot.
An explicit user-authored `rtk read` MUST remain available and MUST not prevent
other slots in a mixed command from being rewritten.

An already-prefixed standalone `rtk` or `rtk.exe` command MUST be preserved
from registry delegation. Absolute binding MAY qualify its executable token at
the final output boundary without changing its RTK subcommand or arguments.

## 8. RTK Invocation Plan

One Hook invocation MUST start RTK at most once:

| Delegate count / plan | RTK calls | Strategy |
| --- | ---: | --- |
| 0 | 0 | Local result or preserve |
| 1 | 1 | Rewrite the saved delegate directly |
| 2+ and every top-level pipeline is delegated | 1 | Rewrite the complete original source |
| 2+ mixed with preserve/local extents | 1 | GUID-delimited slot batch |

The whole-source optimization MUST be disabled when an explicit `rtk read`
slot requires per-slot rollback.

For `N` mixed delegate slots, the batch MUST contain `N + 1` unique boundary
commands. The random batch id MUST not occur in the source. The temporary batch
MUST contain copies of delegate extents only and MUST never be executed.

Returned markers MUST be unique, ordered, top-level, argument-free commands.
Slots MUST be extracted between adjacent marker AST extents, not with textual
semicolon splitting. Invalid marker structure rejects all delegate results;
generated `rtk read` rejects only its own slot. Batches over `1 MiB` MUST not
start RTK.

## 9. RTK Resolution and Invocation

An explicit `-RtkPath` MUST be absolute, MUST name an existing file, and MUST
pass both `--version` and `rewrite --help`. It has highest priority and MUST be
stored in the Hook registration.

Without `-RtkPath`, installation MUST enumerate `rtk` applications in
PowerShell execution order. If the effective first candidate is compatible,
the registration MUST omit `-RtkPath`, and both rewrite and generated commands
MUST use bare `rtk`. If the effective candidate is incompatible but a later
PATH candidate is compatible, installation MUST warn and bind the later file
by absolute path.

If PATH provides no compatible candidate, installation MUST inspect only these
bounded fallback providers, in this order:

1. Cargo: `%CARGO_HOME%\bin\rtk.exe`, then
   `%USERPROFILE%\.cargo\bin\rtk.exe`;
2. native Windows local bin: `%USERPROFILE%\.local\bin\rtk.exe`;
3. Scoop: configured and conventional Scoop roots, then `scoop prefix rtk`.

Each fallback candidate MUST pass the same compatibility checks and MUST be
bound by absolute path. The installer MUST NOT recursively scan a drive or edit
the user's PATH. It MUST NOT invoke Homebrew or a Unix installation script;
their Linux, macOS, and WSL installations are outside this native Windows
process boundary.

When `-RtkPath` is registered, that file MUST be used for the rewrite
subprocess. One final AST binding pass MUST replace every statically resolvable
`rtk` or `rtk.exe` executable token, whether generated or already present in
the input, with PowerShell's call operator plus the same quoted absolute path.
A missing configured file MUST fail open without falling back to PATH. In bare
mode, a missing runtime `rtk` command MUST also fail open.

`RTK_CODEX_RTK_EXE` MAY override the rewrite process only in `-LibraryMode` for
isolated tests. Production execution MUST ignore it.

## 10. Installation and Removal

The installer and uninstaller MUST:

- use PowerShell 7 structured JSON APIs, never textual JSON replacement;
- reject a volume root as Codex home;
- contain every target under the normalized selected Codex home;
- preserve unrelated matchers and handlers;
- keep exactly one project registration after repeated installation;
- create timestamped backups before replacement or removal;
- use same-directory temporary files and validate before atomic replacement;
- make `-WhatIf` non-writing;
- avoid recursive deletion of the Codex home or backup tree.

They MUST NOT modify RTK configuration, including
`%APPDATA%\rtk\config.toml`. An RTK `exclude_commands` setting MAY protect other
integrations but MUST NOT be required for this Hook's read-boundary correctness.

The installer SHOULD warn when `<CodexHome>\AGENTS.md` directly includes an
`RTK.md` instruction file, because an `Always prefix` rule can hide the original
command from the transparent planner. It MUST NOT modify `AGENTS.md` or
`RTK.md`.

The installer SHOULD warn when another `PreToolUse` command Hook may match
`Bash`, because current Codex resolves competing `updatedInput` values by
completion order. It MUST NOT delete or reorder that Hook.

## 11. Safety

The production Hook MUST NOT write files, download data, call
`Invoke-Expression`, launch background processes, or execute the source command.
Its only external execution is the resolved RTK binary with the `rewrite`
subcommand.

Fail-open behavior makes this an optimizer rather than an enforcement boundary.
Policy Hooks that deny commands require a separate design.

## 12. Verification

Every behavior change MUST update the production Hook, positive and rejection
tests, and both language specifications together. CI and local verification use:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\run-all.ps1
```

Release validation MUST additionally cover a real Codex process using a
deterministic loopback Responses fixture and a disposable Codex home. It MUST
prove the installer-bound RTK path is applied before Codex policy, then execute
the same fixed command in an explicit bypass phase and observe its tool output.
The deterministic suites MUST cover object pipelines with zero RTK calls and
missing-RTK fail-open behavior. The release ZIP SHA-256 MUST match its checksum
file.

The repository MUST include a reproducible read evaluator that isolates RTK
tracking from the user's database, does not modify RTK configuration, does not
modify the input file, emits structured output, and compares default, minimal,
aggressive, line-window, tail-window, and line-number modes. Timing results MUST
be documented as machine-specific and MUST NOT be enforced as CI thresholds.

The repository MUST also include a project-output evaluator that parses the
live `rtk --help` inventory, classifies every exposed command, measures each
command family applicable to this repository, and reports task-equivalent
results separately from explicit lossy views. A validated RTK baseline MUST
have zero unclassified commands. Token estimates MUST use UTF-8 output bytes,
and unavailable native baselines MUST be skipped rather than measured against
an error message.

Published aggregates MUST name their denominator and MUST NOT present a
selected project-output matrix as whole-session AI token savings. Reports MUST
disclose dilution from preserved output and non-tool context. Any workload-mix
projection without observed session traces MUST be labeled as a scenario, not
as a measurement.

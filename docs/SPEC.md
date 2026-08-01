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

## 9. Exact RTK Binding

Installation MUST resolve one absolute RTK file and validate both
`--version` and `rewrite --help`. The Hook registration MUST pass that path as
`-RtkPath`.

The configured path MUST be used for the `rewrite` subprocess and MUST replace
every generated `rtk` command with PowerShell's call operator plus the same
quoted absolute path. A missing configured file MUST fail open without falling
back to a different RTK on `PATH`.

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

Release validation MUST additionally cover a real Codex process, a disposable
Codex home, the installer-bound RTK path, an object pipeline with zero RTK
calls, missing-RTK fail-open behavior, and a release ZIP whose SHA-256 matches
its checksum file.

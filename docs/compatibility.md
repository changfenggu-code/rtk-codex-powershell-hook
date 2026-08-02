# Compatibility and Validation

Last updated: 2026-08-02.

## Validated Baseline

| Component | Validated version | Status |
| --- | --- | --- |
| Windows | Windows 11 Home China, 10.0.26200 (build 26200) | Supported baseline |
| PowerShell | 7.6.4 | Passed |
| RTK | 0.44.2 | Passed |
| Codex CLI | 0.146.0 | Real loopback runtime gate passed |

Versions older than the validated baseline are not claimed to work. Newer
versions should be revalidated because Codex Hook semantics and RTK rewrite
coverage can change independently.

## Automated Evidence

The Windows CI and local `tests/run-all.ps1` gate cover:

- PowerShell AST positive and rejection rules;
- Codex `PreToolUse` JSON input/output and field retention;
- zero/one/one RTK process behavior for zero, one, or multiple delegates;
- whole-source delegation and mixed-plan GUID slot validation;
- object pipelines preserved with zero RTK invocation;
- exact RTK path quoting, including spaces and apostrophes;
- missing RTK, malformed JSON, malformed PowerShell, and oversized input
  fail-open behavior;
- generated `rtk rg`, `rtk find`, `rtk ls`, and explicit `rtk read` execution;
- install, upgrade, conflict warning, backup, uninstall, `-WhatIf`, and
  idempotency;
- static production-script safety checks;
- release ZIP contents and SHA-256 checksum.
- isolated, read-only `rtk read` evaluation and structured report output.

Current local result: all six suites pass with 354 assertions and zero failures.
PSScriptAnalyzer `1.25.0` and actionlint `1.7.12` also pass with zero findings.

The [read evaluation](read-evaluation.md) records an RTK 0.44.2 sample with its
input hash and methodology. Default read was exact but saved no estimated
tokens; lossy modes remain explicit tools rather than automatic rewrites.

## Real Codex Release Gate

Before a release is tagged, `scripts/run-real-codex-e2e.ps1` creates a
disposable Codex home and a deterministic Responses API fixture bound only to
`127.0.0.1`. The fixture requires no OpenAI authentication and records request
bodies, but not headers, under the ignored `artifacts/e2e/<timestamp>` path.
The script never reads the active Codex provider or authentication files.

The gate has two phases for the same raw model command, `git status --short`:

1. Under `workspace-write` with approvals set to `never`, the Hook rewrites to
   the installer-bound absolute RTK path and Codex declines the resulting
   command. This proves `updatedInput` does not bypass Codex policy.
2. With approvals and sandbox explicitly bypassed for this fixed local command,
   the same rewrite executes successfully and its shell output appears in the
   next Responses request as `function_call_output`.

Current gate status: **passed on 2026-08-02** with Codex CLI `0.146.0`, RTK
`0.44.2`, PowerShell `7.6.4`, and Windows `10.0.26200`. Native reads, mixed
plans, object-pipeline preservation, missing-RTK fail-open, and the broader
command matrix remain deterministic suite responsibilities. This gate validates
the real Codex Hook/runtime protocol; it is not a test of any external model or
provider.

## Known Limits

- Native Windows PowerShell only.
- The Hook sees Codex calls matched as canonical `Bash`; hosted tools are out of
  scope.
- Specialized Codex tool paths may opt out of Hook dispatch; Codex itself
  documents Hooks as a guardrail rather than a complete enforcement boundary.
- Multiple matching `updatedInput` writers race by completion order in current
  Codex. Use one rewriting Hook for `Bash`.
- RTK output is intentionally compressed and is not byte-for-byte equivalent to
  the original command.
- Dynamic PowerShell, assignments, redirections, and unproven object pipelines
  are intentionally preserved.

## Primary Sources

- [Codex Hooks documentation](https://developers.openai.com/codex/hooks)
- [Pinned Codex `PreToolUse` completion-order implementation](https://github.com/openai/codex/blob/e4836f998da166aba456f60d2e74eb79d6e2542b/codex-rs/hooks/src/events/pre_tool_use.rs#L121-L156)
- [RTK repository and Windows installation](https://github.com/rtk-ai/rtk)
- [RTK v0.44.2 release](https://github.com/rtk-ai/rtk/releases/tag/v0.44.2)

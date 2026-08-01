# Compatibility and Validation

Last updated: 2026-08-02.

## Validated Baseline

| Component | Validated version | Status |
| --- | --- | --- |
| Windows | Windows 11 Home China, 10.0.26200 (build 26200) | Supported baseline |
| PowerShell | 7.6.4 | Passed |
| RTK | 0.44.1 | Passed |
| Codex CLI | 0.146.0 | Protocol and local runtime baseline |

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

Current local result: five suites, `304` assertions, zero failures.
PSScriptAnalyzer `1.25.0` and actionlint `1.7.12` also pass with zero findings.

## Real Codex Release Gate

Before a release is tagged, a disposable Codex home must prove:

1. a raw `git status` tool call is executed through the installer-bound RTK;
2. native `Get-Content` remains unchanged;
3. mixed commands preserve local/object extents and rewrite RTK delegates;
4. a PowerShell object pipeline starts no RTK rewrite process;
5. a missing configured RTK path fails open;
6. normal Codex approval and sandbox handling still occurs after mutation;
7. the tested Codex, RTK, PowerShell, Windows versions and date are recorded.

The release workflow does not replace this local product integration gate. CI
can verify protocol and packaging deterministically, while a real Codex run
requires a configured local Codex session.

Current model-backed gate status: **not passed yet**. A disposable-home attempt
proved Codex `0.146.0` loaded the configured Hook path but the copied API-key
credential returned `401` before any tool call. A second attempt using the
active provider was not executed because that provider is a nonstandard
external HTTP endpoint and had not been explicitly approved for sending the
test prompt and normal Codex context. No tool-call claim is made from either
attempt. Use `scripts/run-real-codex-e2e.ps1 -AllowProviderRequest` only after
reviewing and approving the active provider.

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
- [RTK v0.44.1 release](https://github.com/rtk-ai/rtk/releases/tag/v0.44.1)

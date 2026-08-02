# Contributing

Issues and pull requests are welcome after the repository is published.

## Development

Requirements are Windows, PowerShell 7, and RTK `0.44.2` or a compatible
version exposing `rtk rewrite`.

Run the complete verification suite before submitting a change:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\run-all.ps1
pwsh -NoLogo -NoProfile -NonInteractive -File .\scripts\run-lint.ps1 -Bootstrap
pwsh -NoLogo -NoProfile -NonInteractive -File .\scripts\run-actionlint.ps1 -Bootstrap
```

Changes to rewrite behavior must update all three artifacts in the same pull
request:

1. `rtk-codex-hook.ps1`
2. Positive and rejection tests under `tests/`
3. `docs/SPEC.md` and `docs/SPEC.zh-CN.md`

New PowerShell mappings must prove that static AST arguments and output data
shape are compatible. Do not increase rewrite coverage by flattening object
pipelines, assignments, redirections, or dynamic command resolution.

## Commit Scope

Keep RTK registry changes upstream. This project should contain only the Codex
protocol adapter, Windows PowerShell compatibility rules, packaging, and
installer behavior required for that adapter.

## Summary

Describe the behavior and boundary changed.

## Semantic Evidence

- [ ] Positive rewrite cases are covered.
- [ ] Preserve/rejection cases are covered.
- [ ] PowerShell object semantics remain valid.
- [ ] The change belongs in this adapter rather than RTK/Codex upstream.

## Verification

- [ ] `pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\run-all.ps1`
- [ ] `docs/SPEC.md` and `docs/SPEC.zh-CN.md` are synchronized when behavior changed.
- [ ] No machine-specific path, secret, generated fixture, or active Codex config is included.

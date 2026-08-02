# RTK Read Evaluation

Last updated: 2026-08-02. This report explains why automatic native file reads
remain outside the Hook rewrite surface. It is reproducible evidence, not a
general benchmark claim.

## Reproduce

Run the checked-in evaluator against any regular file:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\scripts\evaluate-read.ps1 `
  -File .\rtk-codex-hook.ps1 `
  -Iterations 10 `
  -WindowLines 100
```

Use `-OutputFormat Json` for machine-readable schema version 1. `-RtkPath`
accepts an explicit absolute executable path. Files over 16 MiB require an
explicitly larger `-MaxFileBytes` value.

The evaluator:

- reads but never modifies the input file;
- sets `RTK_DB_PATH` to an exact database inside a uniquely named temporary
  directory and sets `RTK_TELEMETRY_DISABLED=1` for every RTK child process;
- deletes only that validated temporary directory;
- does not modify the user's RTK configuration; RTK itself may still load its
  normal configuration while starting;
- estimates tokens as `ceil(characters / 4)`, so token figures compare relative
  output size rather than predict one specific tokenizer exactly.

## RTK 0.44.2 Result

The validated sample was
`espkit/crates/std/btleplus/src/runtime/scan/mod.rs`, SHA-256
`6dd6bf9322ba3cd626110f255f7677c44c7a1b66b22e53b4e549027009b7b294`.
It contained 13,819 characters, 353 lines, and approximately 3,455 estimated
tokens. Measurements used PowerShell 7.6.4, RTK 0.44.2, ten timed samples, and a
100-line window.

| Mode | Characters | Estimated tokens | Lines | Savings | Exact | Average ms |
| --- | ---: | ---: | ---: | ---: | :---: | ---: |
| Native `Get-Content -Raw` | 13,819 | 3,455 | 353 | 0.0% | Yes | 4.586 |
| `rtk read` default | 13,819 | 3,455 | 353 | 0.0% | Yes | 143.179 |
| `rtk read -l minimal` | 13,367 | 3,342 | 347 | 3.3% | No | 121.159 |
| `rtk read -l aggressive` | 1,593 | 399 | 41 | 88.5% | No | 146.204 |
| `rtk read --max-lines 100` | 2,390 | 598 | 100 | 82.7% | No | 101.890 |
| `rtk read --tail-lines 100` | 4,595 | 1,149 | 100 | 66.7% | No | 161.763 |
| `rtk read --line-numbers` | 15,937 | 3,985 | 353 | -15.3% | No | 114.016 |

Timing includes process startup and is specific to this Windows machine. CI
does not enforce timing thresholds. Cold-process timings are retained in JSON
output but omitted from this summary because they do not change the policy.

## Interpretation

Default `rtk read` is lossless for this file, but it saves no output tokens and
adds a child process. Rewriting every `Get-Content` to this form would therefore
add latency without reducing model-visible text.

`minimal` removed little from ordinary handwritten Rust. `aggressive` and
`--max-lines` saved substantial output, but they are intentionally lossy and
cannot preserve a caller's request for exact source or exact leading lines.
`--tail-lines` can be useful when explicitly requested, but it does not improve
on a native bounded tail for token volume. `--line-numbers` is useful for stable
references, not compression.

These results do not mean `rtk read` is useless. Explicit use remains valuable
for an initial outline of a large file, generated sources with removable noise,
or line-numbered review output. The important distinction is user-selected
lossiness versus an invisible automatic rewrite.

## Hook Policy

The production policy remains:

- preserve native `Get-Content`, `gc`, `cat`, `type`, `head`, and `tail` reads;
- allow explicit user-authored `rtk read` commands;
- reject an `rtk rewrite` result that introduces `rtk read`, rolling back only
  the affected slot in a mixed plan;
- never persist command text, rewrite results, or learned object-pipeline
  classifications;
- never modify RTK configuration during install, evaluation, or uninstall.

The optional RTK `[hooks].exclude_commands = ["cat", "head", "tail"]` setting
is defense in depth for other RTK integrations. This Hook does not require it
for correctness.

## Why There Is No Self-Learning Cache

Unknown PowerShell object pipelines are preserved before RTK starts because
their behavior depends on .NET object types, provider state, aliases, modules,
variables, and downstream consumers. Caching a previous textual rewrite by a
normalized command shape would not prove those runtime conditions equivalent.
It would also add persistent storage, invalidation, privacy, and security work
to an output adapter for little expected gain.

New automatic coverage therefore requires a source-controlled rule with a
positive test and a rejection test. A speculative RTK result is not promoted
into future policy.

## Upstream Contract That Would Help

RTK could make read decisions safer for every integration by returning
structured rewrite metadata such as:

```json
{
  "status": "rewritten",
  "command": "rtk read file.rs -l aggressive",
  "lossless": false,
  "output_kind": "code-outline",
  "expected_savings": 0.8
}
```

This would expose intent, but the final decision would still belong to the
calling agent or planner. See [the upstream roadmap](upstream-roadmap.md) for
the broader batch and Codex Hook proposals.

Relevant RTK discussions include [#822](https://github.com/rtk-ai/rtk/issues/822),
[#582](https://github.com/rtk-ai/rtk/issues/582), and
[#1362](https://github.com/rtk-ai/rtk/issues/1362).

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
- estimates tokens as `ceil(UTF-8 output bytes / 4)`, matching the command
  evaluator and RTK's documented approximation; the figures compare relative
  output size rather than predict one specific tokenizer exactly.

## RTK 0.44.2 Result

The validated sample was this repository's current `rtk-codex-hook.ps1`,
SHA-256
`38266e84a193d7ffc828a45eba592cdc680f7652dc6a9cfb5c50724ab9bf547a`.
It contained 42,319 bytes, 42,319 characters, 1,487 lines, and approximately
10,580 estimated tokens. Measurements used PowerShell 7.6.4, RTK 0.44.2, two
timed samples, and a 100-line window.

| Mode | Characters | Estimated tokens | Lines | Savings | Exact | Average ms |
| --- | ---: | ---: | ---: | ---: | :---: | ---: |
| Native `Get-Content -Raw` | 42,319 | 10,580 | 1,487 | 0.0% | Yes | 9.733 |
| `rtk read` default | 42,319 | 10,580 | 1,487 | 0.0% | Yes | 105.930 |
| `rtk read -l minimal` | 42,318 | 10,580 | 1,487 | 0.0% | No | 180.167 |
| `rtk read -l aggressive` | 2,311 | 578 | 73 | 94.5% | No | 201.749 |
| `rtk read --max-lines 100` | 1,868 | 467 | 100 | 95.6% | No | 193.579 |
| `rtk read --tail-lines 100` | 2,589 | 648 | 100 | 93.9% | No | 137.370 |
| `rtk read --line-numbers` | 52,728 | 13,926 | 1,487 | -31.6% | No | 116.951 |

Timing includes process startup and is specific to this Windows machine. CI
does not enforce timing thresholds. Cold-process timings are retained in JSON
output but omitted from this summary because they do not change the policy.

## Interpretation

Default `rtk read` is lossless for this file, but it saves no output tokens and
adds a child process. Rewriting every `Get-Content` to this form would therefore
add latency without reducing model-visible text.

`minimal` saved no estimated tokens on the current Hook source. `aggressive` and
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

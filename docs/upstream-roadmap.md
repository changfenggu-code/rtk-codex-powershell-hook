# Upstream Status and Roadmap

Status snapshot: 2026-08-02. This document records findings and proposed
improvements; this project has not submitted an issue or pull request upstream.

## Current Situation

The current [Codex Hooks documentation](https://developers.openai.com/codex/hooks)
supports transparent `PreToolUse` mutation: a Hook returns
`permissionDecision: "allow"` with `updatedInput`, and the tool runs with the
replacement arguments.

RTK's current README documents Codex as `AGENTS.md + RTK.md` instructions, while
Hook-based agents receive transparent rewrites. RTK already has the right
single source of truth in `rtk rewrite`, so this project calls that interface
from a Windows PowerShell protocol adapter.

RTK PR [#1550](https://github.com/rtk-ai/rtk/pull/1550) explored a Codex
deny-and-retry Hook when Codex did not reliably honor `updatedInput`. That
assumption is now stale for the validated Codex baseline. Deny-and-retry adds a
model turn and tokens; transparent mutation is the appropriate current shape.

## What Belongs in This Project

- Windows PowerShell AST classification and object-stream preservation.
- A compatibility adapter from Codex JSON to `rtk rewrite`.
- Safe local install/uninstall while upstream has no native transparent Codex
  installer for this environment.
- Conservative fail-open behavior and compatibility evidence.

This project should not duplicate RTK's command registry or grow into a generic
cross-platform agent integration framework.

## RTK Upstream Opportunities

### 1. Native transparent `rtk hook codex`

The terminal design is a native RTK subcommand that:

1. reads Codex `PreToolUse` JSON from stdin;
2. invokes RTK's internal `rewrite_command()` directly in the same Rust process;
3. returns Codex `permissionDecision: "allow"` plus `updatedInput`;
4. installs and removes the Codex Hook through `rtk init -g --codex`;
5. works on Windows, Linux, and macOS without PowerShell-specific glue.

This removes one PowerShell process only if Codex launches RTK directly, and it
always removes the additional `rtk rewrite` child process. It also keeps the
registry and protocol adapter in one versioned binary.

### 2. Structured batch rewrite API

The current CLI accepts one command string. Mixed PowerShell plans therefore
use validated sentinel boundaries as a compatibility mechanism. A structured
batch API would eliminate that encoding:

```json
{
  "commands": [
    { "id": "0", "command": "git status" },
    { "id": "1", "command": "cargo check" }
  ]
}
```

Possible command:

```text
rtk rewrite --batch-json
```

Possible result:

```json
{
  "results": [
    { "id": "0", "status": "rewritten", "command": "rtk git status" },
    { "id": "1", "status": "rewritten", "command": "rtk cargo check" }
  ]
}
```

Each item needs an id and explicit `rewritten`, `unchanged`, or `error` status.
One bad item must not corrupt neighboring results. A `rtk capabilities --json`
surface would also let adapters detect batch support without version guessing.

This is an RTK upstream improvement, not a missing feature that can be solved
cleanly inside this project. The sentinel batch remains a fallback until such a
surface exists.

### 3. Shell-aware policy metadata

Adapters benefit from registry metadata describing whether a rewrite consumes
text, produces text, or expects native objects. RTK should not parse PowerShell
AST itself, but capability metadata could help external planners avoid unsafe
delegation.

A structured single-command response could include:

```json
{
  "status": "rewritten",
  "command": "rtk read file.rs -l aggressive",
  "lossless": false,
  "output_kind": "code-outline",
  "pipeline_input": "none",
  "pipeline_output": "text",
  "expected_savings": 0.8
}
```

`status` distinguishes a supported no-op from an error. `lossless` and
`output_kind` let the caller decide whether a summarized view satisfies the
request. Pipeline metadata lets a shell-aware adapter reject text substitution
where native objects are required. `expected_savings` should be an estimate,
not a promise or an instruction to silently accept lossy output.

The same schema should be used by `rewrite --json` and each result in
`rewrite --batch-json`, with capabilities discoverable through
`rtk capabilities --json`.

### 4. Read intent and measurable tradeoffs

The checked-in [read evaluation](read-evaluation.md) found that RTK 0.44.2
default read was byte-equivalent to the sample and saved no estimated tokens,
while adding process startup. `minimal` saved 3.3%; `aggressive` and line-window
modes saved substantially more but were lossy; line numbers increased output by
15.3%.

That evidence supports intent metadata rather than a universal automatic read
rule. RTK integrations need to distinguish exact source, bounded exact windows,
code outlines, and line-numbered references. Relevant upstream discussions are
[#822](https://github.com/rtk-ai/rtk/issues/822),
[#582](https://github.com/rtk-ai/rtk/issues/582), and
[#1362](https://github.com/rtk-ai/rtk/issues/1362).

This project will not build a persistent cache that learns object-pipeline
rewrites from speculative results. Such a cache cannot prove that PowerShell
provider, alias, module, variable, and .NET object conditions remain equivalent;
it would also create invalidation, privacy, and security obligations outside a
compatibility adapter's scope.

## Codex Upstream Issue: Competing `updatedInput`

At pinned source commit
[`e4836f9`](https://github.com/openai/codex/blob/e4836f998da166aba456f60d2e74eb79d6e2542b/codex-rs/hooks/src/events/pre_tool_use.rs#L121-L156),
matched handlers execute concurrently and `latest_updated_input()` selects the
rewrite with the greatest completion order. The source comment explicitly says
the Hook that actually finishes last wins.

Example:

```text
Hook A (RTK):      git status -> rtk git status     completes at 30 ms
Hook B (wrapper):  git status -> audit git status   completes at 40 ms
Result: Hook B wins and silently discards Hook A.
```

If timing reverses, the result reverses. Neither Hook receives the other's
output, so they cannot compose. This is a Codex protocol/runtime issue, not an
RTK bug and not something an installer can resolve safely.

### Recommended Codex behavior

The preferred composable design is deterministic sequential mutation:

1. run matching rewriting Hooks in declared configuration order;
2. pass each Hook the current `tool_input`, including prior rewrites;
3. record every mutation in audit output;
4. run approval and sandbox checks on the final input.

If parallel execution must remain, Codex should detect more than one successful
`updatedInput` writer and return a clear conflict instead of choosing by timing.
An explicit priority field can be added only if conflict semantics are also
documented; priority alone still does not compose independent mutations.

The public manual should state whichever policy is implemented. Current
documentation explains the shape of one rewrite but does not warn that multiple
writers are resolved by completion order.

## Migration End State

When RTK ships a native transparent Codex Hook with structured or in-process
rewrites, this project should become either:

- a narrow PowerShell rule contributor to upstream RTK; or
- a deprecated compatibility package with a documented migration command.

The goal is not permanent middleware. The goal is a correct bridge that also
makes the missing upstream contracts concrete and testable.

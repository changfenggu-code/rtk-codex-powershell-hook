# RTK Command Savings Evaluation

Last updated: 2026-08-02. This report measures RTK 0.44.2 output against
native commands on this repository. It also inventories every subcommand in
`rtk --help` so unsupported or inapplicable commands cannot silently disappear
from the evaluation surface.

## Reproduce

Run the full checked-in evaluator:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File `
  .\scripts\evaluate-command-savings.ps1 `
  -EvaluationProfile Full `
  -Iterations 3
```

Use `-OutputFormat Json` for machine-readable schema version 1. Set
`-EvaluationProfile Quick` to run
the deterministic core cases used by the automated test. `Full` adds filtered
views and command-output adapters. `-RtkPath` accepts an explicit absolute RTK
executable.

The evaluator:

- executes native and RTK forms from the same project root;
- captures stdout and stderr and validates expected exit codes;
- rejects known failure text even when a command incorrectly exits `0`;
- caps captured output and applies a per-process timeout;
- uses a unique `RTK_DB_PATH` and `RTK_TELEMETRY_DISABLED=1`;
- estimates tokens as `ceil(UTF-8 output bytes / 4)`;
- records hashes, previews, cold time, and average process time in JSON;
- does not modify the repository or the user's RTK configuration or tracking
  database.

The token estimate compares output volume. It is not an exact tokenizer and
does not prove that two different outputs preserve identical information.
Timing includes process startup, is machine-specific, and is not a CI
threshold.

## Complete RTK 0.44.2 Inventory

The evaluator parsed all 79 subcommands exposed by the installed RTK and left
zero unclassified:

| Classification | Count | Commands |
| --- | ---: | --- |
| Measured here | 13 | `ls`, `smart`, `git`, `err`, `test`, `json`, `find`, `diff`, `log`, `summary`, `grep`, `rg`, `wc` |
| Measured separately | 1 | `read` |
| Not applicable to this repository | 45 | `gh`, `glab`, `aws`, `psql`, `pnpm`, `deps`, `dotnet`, `docker`, `kubectl`, `oc`, `wget`, `jest`, `vitest`, `prisma`, `tsc`, `next`, `lint`, `prettier`, `format`, `playwright`, `cargo`, `npm`, `npx`, `curl`, `ruff`, `pytest`, `mypy`, `php`, `phpunit`, `phpstan`, `pest`, `paratest`, `ecs`, `pint`, `rake`, `rubocop`, `rspec`, `pip`, `uv`, `go`, `sbt`, `gt`, `golangci-lint`, `gradlew`, `mvn` |
| RTK management | 15 | `init`, `gain`, `cc-economics`, `config`, `discover`, `session`, `telemetry`, `learn`, `trust`, `untrust`, `verify`, `hook-audit`, `rewrite`, `hook`, `help` |
| Intentional passthrough | 2 | `run`, `proxy` |
| Other classified surfaces | 3 | `tree`, `pipe`, `env` |

"Not applicable" means this PowerShell adapter repository does not contain the
required ecosystem, manifest, service, or authenticated CLI. Running those
commands would measure missing-tool errors, not token savings. Management
commands operate on RTK itself rather than project-file output. `run` and
`proxy` explicitly promise raw or unfiltered execution. `pipe` is a generic
filter interface whose applicable filters are exercised through direct
commands, and `env` is not project-file output.

`tree` is classified as unsupported on the native Windows baseline. RTK 0.44.2
passes Unix-style exclusion arguments to `tree.exe`; the executable prints
`Too many parameters` but exits `0`. The evaluator refuses to count that short
error message as a saving.

The `grep` case is defined, but the native executable was unavailable on the
validated machine, so it was explicitly skipped. `rg` exercises the same RTK
search-output filter on fixed README and SPEC fixtures.

## RTK 0.44.2 Results

The validated environment was Windows 10.0.26200, PowerShell 7.6.4, RTK
0.44.2, commit `5fbe5d3440c4f2fcc8bc25102fda3a0166785b6b`, and a dirty development
worktree. Three timed samples were collected after one cold sample per case.

`TaskEquivalent` means both commands perform the same project task, although
RTK intentionally reformats or condenses model-facing output.
`ExplicitLossyView` means the RTK command was explicitly selected to produce a
summary or filtered view; these cases are reported but excluded from the
task-equivalent aggregate.

| Case | Class | Native bytes | RTK bytes | Estimated tokens | Savings |
| --- | --- | ---: | ---: | ---: | ---: |
| `ls-root` | TaskEquivalent | 668 | 399 | 167 -> 100 | 40.3% |
| `find-scripts` | TaskEquivalent | 207 | 143 | 52 -> 36 | 30.9% |
| `rg-markdown` | TaskEquivalent | 24,056 | 9,929 | 6,014 -> 2,483 | 58.7% |
| `wc-hook` | TaskEquivalent | 75 | 16 | 19 -> 4 | 78.7% |
| `json-hooks` | TaskEquivalent | 350 | 342 | 88 -> 86 | 2.3% |
| `git-status` | TaskEquivalent | 1,034 | 767 | 259 -> 192 | 25.8% |
| `git-log` | TaskEquivalent | 288 | 288 | 72 -> 72 | 0.0% |
| `git-show` | TaskEquivalent | 729 | 729 | 183 -> 183 | 0.0% |
| `git-diff-previous` | TaskEquivalent | 57,006 | 29,799 | 14,252 -> 7,450 | 47.7% |
| `smart-hook` | ExplicitLossyView | 42,321 | 49 | 10,581 -> 13 | 99.9% |
| `diff-readmes` | TaskEquivalent | 17,954 | 18,257 | 4,489 -> 4,565 | -1.7% |
| `log-git-history` | ExplicitLossyView | 866 | 102 | 217 -> 26 | 88.2% |
| `test-docs` | TaskEquivalent | 24 | 23 | 6 -> 6 | 4.2% |
| `err-docs` | ExplicitLossyView | 24 | 10 | 6 -> 3 | 58.3% |
| `summary-docs` | ExplicitLossyView | 24 | 26 | 6 -> 7 | -8.3% |

The `grep-markdown` case was skipped and is not included in aggregates.

## Aggregate Interpretation

All 15 successful measured cases totalled 145,626 native bytes versus 60,879
RTK bytes, or 58.2% weighted savings. That number includes intentionally lossy
views and must not be used as the transparent Hook's expected saving.

The 11 task-equivalent cases totalled 102,391 native bytes versus 60,692 RTK
bytes, or 40.7% weighted savings with a 25.8% median. Eight improved, two were
neutral, and one regressed. `smart`, `log`, `err`, and `summary` are excluded
from this subset because their purpose is to discard information intentionally.

The strongest task-equivalent reductions came from verbose search, historical
diff, directory listing, and word-count output. Already compact `git log` and
`git show` output passed through unchanged. Compact JSON and tiny successful
test output provided little benefit. The README-to-README diff grew slightly,
which demonstrates why per-command gains are more useful than one universal
claim.

Explicit filtered views can be valuable when their narrower intent is wanted:
`smart` reduced a 1,487-line script to a file classification, while `log` and
`err` retained only their selected signal. They are not substitutes for full
source or full command output.

## From the Matrix to an AI Session

The 40.7% figure is conditional savings for the task-equivalent command output
selected by this report. It is not total token savings for a real AI coding
session. The aggregate runs each sampled command once and weights those samples
by native output bytes. It does not weight commands by observed AI usage, and
it does not add preserved `Get-Content`, `cat`, `head`, or `tail` output to the
denominator.

Let `S = 40.7%` be the measured task-equivalent rate, `E` be original output
tokens from eligible commands, and `P` be zero-saving preserved output. If the
eligible workload retains the measured rate, tool-output savings are:

```text
tool-output savings = S * E / (E + P)
                    = 40.7% * eligible-output share
```

Heavy native reading therefore dilutes the overall percentage because each
preserved read has zero marginal automatic savings. The following values are
scenarios with `S` held at 40.7%, not additional measurements:

| Preserved share of original tool output | Eligible share | Projected tool-output savings |
| ---: | ---: | ---: |
| 0% | 100% | 40.7% |
| 25% | 75% | 30.5% |
| 50% | 50% | 20.4% |
| 70% | 30% | 12.2% |
| 90% | 10% | 4.1% |

For example, if a session originally produced 100,000 tool-output tokens,
60,000 came from preserved reads, and 40,000 came from eligible commands with
this matrix's behavior, the projected reduction would be about
`40,000 * 40.7% = 16,280` tokens, or 16.3% of tool output rather than 40.7%.
Adding user input, model output, tool protocol framing, and other non-shell
context to the denominator lowers the end-to-end session percentage further.

This is still not causal session measurement. Shorter search and diff output
may prevent later reads, creating second-order savings absent from the matrix;
lossy output may instead cause rereads and offset savings. A real session
metric should therefore come from offline analysis of redacted command traces
and original output shares, not persistent collection by the production Hook.

## Hook Implications

The measurements support selective transparent rewriting rather than an
"always prefix" policy:

- delegate commands with proven RTK mappings;
- preserve native reads because default `rtk read` adds a process without
  reducing output;
- preserve PowerShell object pipelines unless the complete mapping is proven;
- keep explicit lossy RTK commands available to the user;
- validate command success before counting output reduction;
- start RTK at most once per Hook invocation so planning overhead is bounded.

See [the read evaluation](read-evaluation.md) for the six `rtk read` modes and
[the specification](SPEC.md) for the production rewrite boundary.

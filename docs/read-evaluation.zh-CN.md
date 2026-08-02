# RTK Read 评估报告

最后更新：2026-08-02。本文解释为什么原生文件读取仍然不进入 Hook 的自动改写范围。它是一份可复现实验证据，不是对所有机器和文件都成立的性能宣称。

## 如何复现

对任意普通文件运行仓库内的评估器：

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\scripts\evaluate-read.ps1 `
  -File .\rtk-codex-hook.ps1 `
  -Iterations 10 `
  -WindowLines 100
```

`-OutputFormat Json` 会输出 schema version 1 的结构化结果；`-RtkPath` 可指定 RTK 的绝对路径。文件默认不得超过 16 MiB，更大的文件必须显式提高 `-MaxFileBytes`。

评估器具有以下边界：

- 只读取、不修改输入文件；
- 为每个 RTK 子进程设置指向一次性目录中精确数据库文件的 `RTK_DB_PATH`，并设置 `RTK_TELEMETRY_DISABLED=1`；
- 最后只删除经过父目录和固定前缀校验的一次性目录；
- 不修改用户的 RTK 配置；RTK 子进程启动时仍可能按自身逻辑读取正常配置；
- 用 `ceil(字符数 / 4)` 估算 token，只用于比较相对输出规模，不冒充某个具体 tokenizer 的精确计数。

## RTK 0.44.2 实测

样本文件为相邻 espkit 仓库中的 `crates/std/btleplus/src/runtime/scan/mod.rs`，SHA-256 为 `6dd6bf9322ba3cd626110f255f7677c44c7a1b66b22e53b4e549027009b7b294`。原文 13,819 字符、353 行，估算约 3,455 token。环境为 PowerShell 7.6.4、RTK 0.44.2；每项采样十次，行窗口为 100。

| 模式 | 字符数 | 估算 token | 行数 | 节省 | 逐字相同 | 平均耗时 ms |
| --- | ---: | ---: | ---: | ---: | :---: | ---: |
| 原生 `Get-Content -Raw` | 13,819 | 3,455 | 353 | 0.0% | 是 | 4.586 |
| `rtk read` 默认 | 13,819 | 3,455 | 353 | 0.0% | 是 | 143.179 |
| `rtk read -l minimal` | 13,367 | 3,342 | 347 | 3.3% | 否 | 121.159 |
| `rtk read -l aggressive` | 1,593 | 399 | 41 | 88.5% | 否 | 146.204 |
| `rtk read --max-lines 100` | 2,390 | 598 | 100 | 82.7% | 否 | 101.890 |
| `rtk read --tail-lines 100` | 4,595 | 1,149 | 100 | 66.7% | 否 | 161.763 |
| `rtk read --line-numbers` | 15,937 | 3,985 | 353 | -15.3% | 否 | 114.016 |

耗时包含子进程启动，只代表这台 Windows 机器；CI 不设置性能阈值。JSON 中仍保留冷启动耗时，但它不改变策略结论，所以表中没有展开。

## 怎么理解结果

默认 `rtk read` 在该文件上逐字无损，却没有减少任何输出 token，还增加了一次子进程启动。因此，把所有 `Get-Content` 自动换成它只会增加延迟。

`minimal` 对普通手写 Rust 的压缩幅度很小；`aggressive` 和 `--max-lines` 节省明显，但都是有损视图，无法保证调用方要的是完整源码或严格的前 N 行。`--tail-lines` 在用户明确要求尾部窗口时有用，但输出 token 不优于原生 bounded tail。`--line-numbers` 的价值是稳定引用，不是压缩。

这并不等于 `rtk read` 没用。第一次观察巨大文件结构、浏览可去除大量噪声的生成代码、或者需要带行号交流时，显式调用仍有价值。关键边界是“用户选择有损视图”，而不是 Hook 在背后静默改变读取语义。

## Hook 当前策略

- 原样保留 `Get-Content`、`gc`、`cat`、`type`、`head` 和 `tail`；
- 允许用户明确写出的 `rtk read`；
- 如果 `rtk rewrite` 生成 `rtk read`，只回退混合计划中受影响的槽位；
- 不持久化命令文本、rewrite 结果或所谓“学到的”对象管道分类；
- 安装、评估和卸载过程都不修改 RTK 配置。

RTK 可选配置 `[hooks].exclude_commands = ["cat", "head", "tail"]` 只是给其他 RTK 集成提供纵深保护，本 Hook 的正确性不依赖它。

## 为什么不做自学习缓存

未知 PowerShell 对象管道在启动 RTK 前就会 Preserve，因为它的行为取决于 .NET 对象类型、Provider、alias、module、变量和下游消费者。即使把一次成功的文本改写按“归一化命令形状”持久化，也不能证明下一次运行条件等价；反而会引入存储、失效、隐私与安全问题，而预期收益很小。

所以，新增自动覆盖必须落实为受版本控制的确定规则，同时带正向与拒绝测试。一次推测性的 RTK 返回不能自动升级为未来策略。

## 希望上游提供的契约

RTK 如果返回结构化 rewrite 元数据，各种集成都能做更可靠的读取决策：

```json
{
  "status": "rewritten",
  "command": "rtk read file.rs -l aggressive",
  "lossless": false,
  "output_kind": "code-outline",
  "expected_savings": 0.8
}
```

这些字段负责暴露意图，是否接受有损输出仍由调用方或 Planner 决定。更完整的 batch API 与原生 Codex Hook 建议见[上游改进手册](upstream-roadmap.zh-CN.md)。

相关 RTK 讨论包括 [#822](https://github.com/rtk-ai/rtk/issues/822)、[#582](https://github.com/rtk-ai/rtk/issues/582) 和 [#1362](https://github.com/rtk-ai/rtk/issues/1362)。

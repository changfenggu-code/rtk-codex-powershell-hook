# RTK 命令节省评估报告

最后更新：2026-08-02。本文在当前仓库上比较 RTK 0.44.2 与原生命令的输出，并完整盘点 `rtk --help` 暴露的每一个子命令，避免不支持或不适用的命令悄悄从评估范围中消失。

## 如何复现

运行仓库内的完整评估器：

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File `
  .\scripts\evaluate-command-savings.ps1 `
  -EvaluationProfile Full `
  -Iterations 3
```

`-OutputFormat Json` 会输出 schema version 1 的结构化结果；`-EvaluationProfile Quick` 只运行自动化测试使用的确定性核心案例，默认 `Full` 再加入显式过滤视图和命令输出适配器；`-RtkPath` 可指定 RTK 的绝对路径。

评估器从同一个项目根目录分别执行原生形式和 RTK 形式，合并捕获 stdout/stderr，验证预期退出码，并对已知失败文本做额外拒绝；即使命令错误地返回 `0`，也不会把一条很短的错误信息算成 token 节省。它还限制输出大小和进程超时，为所有 RTK 子进程设置一次性 `RTK_DB_PATH` 与 `RTK_TELEMETRY_DISABLED=1`，使用 `ceil(UTF-8 输出字节数 / 4)` 估算 token，并在 JSON 中记录输出哈希、预览、冷启动和平均耗时。整个过程不修改仓库、用户 RTK 配置或用户统计数据库。

这里的 token 数只是输出规模估算，不是具体 tokenizer 的精确结果；两个输出更短也不自动证明信息完全等价。耗时包含进程启动，只代表本机，不进入 CI 阈值。

## RTK 0.44.2 完整命令盘点

评估器解析了当前 RTK 暴露的全部 79 个子命令，未分类数量为 0：

| 分类 | 数量 | 命令 |
| --- | ---: | --- |
| 本报告实测 | 13 | `ls`、`smart`、`git`、`err`、`test`、`json`、`find`、`diff`、`log`、`summary`、`grep`、`rg`、`wc` |
| 单独实测 | 1 | `read` |
| 不适用于本仓库 | 45 | `gh`、`glab`、`aws`、`psql`、`pnpm`、`deps`、`dotnet`、`docker`、`kubectl`、`oc`、`wget`、`jest`、`vitest`、`prisma`、`tsc`、`next`、`lint`、`prettier`、`format`、`playwright`、`cargo`、`npm`、`npx`、`curl`、`ruff`、`pytest`、`mypy`、`php`、`phpunit`、`phpstan`、`pest`、`paratest`、`ecs`、`pint`、`rake`、`rubocop`、`rspec`、`pip`、`uv`、`go`、`sbt`、`gt`、`golangci-lint`、`gradlew`、`mvn` |
| RTK 管理命令 | 15 | `init`、`gain`、`cc-economics`、`config`、`discover`、`session`、`telemetry`、`learn`、`trust`、`untrust`、`verify`、`hook-audit`、`rewrite`、`hook`、`help` |
| 有意透传 | 2 | `run`、`proxy` |
| 其他已分类接口 | 3 | `tree`、`pipe`、`env` |

“不适用”表示这个 PowerShell 适配器仓库没有对应生态、manifest、服务或已认证 CLI；强行运行只能测出“工具/项目不存在”的短错误，不能代表 token 节省。管理命令操作的是 RTK 自身，不是项目文件输出；`run` 和 `proxy` 本来就承诺原始或不经筛选的执行；`pipe` 是通用过滤接口，其适用过滤器已经通过直接命令覆盖；`env` 不属于项目文件输出。

`tree` 在当前原生 Windows 基线上被明确标为不支持：RTK 0.44.2 会把 Unix 风格排除参数传给 Windows `tree.exe`，后者输出 `Too many parameters` 却仍返回退出码 `0`。评估器会识别该失败文本，绝不把这条很短的错误当成高节省率。

`grep` 案例已经定义，但验证机器没有原生 `grep` 可执行文件，因此明确记为 Skipped；固定 README/SPEC 样本上的 `rg` 案例覆盖了相同的 RTK 搜索输出过滤器。

## RTK 0.44.2 实测结果

验证环境为 Windows 10.0.26200、PowerShell 7.6.4、RTK 0.44.2、commit `5fbe5d3440c4f2fcc8bc25102fda3a0166785b6b`，工作区处于开发中的 dirty 状态。每个案例先运行一次冷样本，再采集三次计时样本。

`TaskEquivalent` 表示两条命令完成同一个项目任务，尽管 RTK 会重新排版或压缩面向模型的文本；`ExplicitLossyView` 表示用户明确选择了摘要或过滤视图，这些案例会报告，但不会混入任务等价聚合结果。

| 案例 | 分类 | 原生字节 | RTK 字节 | 估算 token | 节省 |
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

`grep-markdown` 被跳过，不进入聚合统计。

## 聚合结果怎么理解

全部 15 个成功实测案例合计为原生 145,626 字节、RTK 60,879 字节，加权节省 58.2%；这里包含主动选择的有损视图，因此不能把 58.2% 当成透明 Hook 的预期收益。

11 个任务等价案例合计为原生 102,391 字节、RTK 60,692 字节，加权节省 40.7%，各案例节省率中位数为 25.8%；其中 8 个改善、2 个持平、1 个退化。`smart`、`log`、`err` 与 `summary` 的目的就是主动丢弃信息，因此全部排除在这个子集之外。

任务等价案例中，收益最明显的是冗长搜索结果、历史 diff、目录列表和字数统计；已经很紧凑的 `git log` 与 `git show` 逐字透传，没有节省；小 JSON 和很短的成功测试输出收益也很低；README 对 README 的 diff 反而增长约 1.8%，这正好说明应该看每个命令的真实结果，而不是假设所有命令都会变短。

显式过滤视图仍然有实际价值：`smart` 把 1,487 行脚本缩成文件类型摘要，`log` 与 `err` 只保留调用者选择的信号；但它们不能代替完整源码或完整命令输出。

## 从命令矩阵到真实 AI 会话

40.7% 是“本报告选取的任务等价命令输出”的条件节省率，不是一次真实 AI 编程会话的总 token 节省率。当前聚合把每个样本命令执行一次，再按这些样本的原生输出字节数加权；它没有按 AI 在实际工作中调用各类命令的频率加权，也没有把普通 `Get-Content`、`cat`、`head`、`tail` 等 Preserve 输出加入分母。

设任务等价矩阵的节省率为 `S = 40.7%`，可改写命令的原始输出 token 为 `E`，零节省的 Preserve 输出 token 为 `P`。在假设真实可改写命令仍保持本报告收益的前提下，工具输出级节省率近似为：

```text
工具输出级节省率 = S * E / (E + P)
                  = 40.7% * 可改写输出占比
```

所以你的判断成立：如果 AI 大量使用普通文件读取，这些读取的边际自动节省为 0，会稀释整体比例。下面只是固定 `S = 40.7%` 的情景推算，不是新的实测数据：

| Preserve 输出占原始工具输出 | 可改写输出占比 | 推算工具输出级节省 |
| ---: | ---: | ---: |
| 0% | 100% | 40.7% |
| 25% | 75% | 30.5% |
| 50% | 50% | 20.4% |
| 70% | 30% | 12.2% |
| 90% | 10% | 4.1% |

例如一次会话原本产生 100,000 个工具输出 token，其中 60,000 来自 Preserve 读取，40,000 来自与本矩阵相似的可改写命令，那么预计只减少约 `40,000 * 40.7% = 16,280` token，工具输出级收益约为 16.3%，而不是 40.7%。如果再把用户输入、模型回复、工具协议和其他非 shell 上下文放进整个会话分母，端到端 token 降幅会进一步降低。

这仍不是完整因果测量。更短的搜索或 diff 可能减少后续读取次数，从而产生本矩阵没有计入的二阶收益；有损输出也可能促使模型重新读取，抵消一部分节省。要得到真实会话结果，下一步应该对脱敏后的实际命令轨迹离线统计各类原始输出 token 占比，而不是让生产 Hook 持久化用户命令或上下文。

## 对 Hook 策略的结论

这批数据支持“有选择的透明改写”，而不是“所有命令一律加 rtk 前缀”：有已证明 RTK 映射的命令才 Delegate；普通读取继续 Preserve，因为默认 `rtk read` 多启动一个进程却不减少输出；PowerShell 对象管道只有整体映射已证明时才改写；显式有损 RTK 命令继续留给用户主动选择；统计节省前必须验证命令确实成功；一次 Hook 调用最多启动一次 RTK，把 Planner 开销控制住。

六种 `rtk read` 模式见[读取评估](read-evaluation.zh-CN.md)，生产改写边界见[规范](SPEC.zh-CN.md)。

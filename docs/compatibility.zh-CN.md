# 兼容性与验证记录

最后更新：2026-08-02。

## 已验证基线

| 组件 | 已验证版本 | 状态 |
| --- | --- | --- |
| Windows | Windows 11 家庭中文版，10.0.26200（build 26200） | 支持基线 |
| PowerShell | 7.6.4 | 通过 |
| RTK | 0.44.2 | 通过 |
| ripgrep | 14.1.1 | 通过；RTK 搜索改写需要 `rg.exe` |
| Codex CLI | 0.146.0 | 真实回环运行时门禁通过 |

不声明更早版本可用。Codex Hook 语义和 RTK rewrite 覆盖会分别演进，新版本也应重新跑发布门禁。

## 自动化证据

Windows CI 与本地 `tests/run-all.ps1` 共同覆盖：

- PowerShell AST 正向规则和拒绝规则；
- Codex `PreToolUse` JSON 输入、输出和字段保留；
- 0/1/多个 Delegate 对应 0/1/1 次 RTK 进程；
- 纯 Delegate 整体调用和混合计划 GUID 槽位校验；
- PowerShell 对象管道保持原样且 RTK 调用数为 0；
- PATH 第一候选的裸 `rtk` 调用、Cargo/Windows local bin/Scoop 兜底顺序、PATH 冲突处理，以及含空格和单引号的精确路径绑定；
- 已加前缀的 `rtk cat`、`rtk git` 与显式 `rtk read` 在最终输出边界完成绝对路径绑定；
- RTK 缺失、JSON/PowerShell 语法错误、超大输入时 fail-open；
- 实际执行生成的 `rtk rg`、`rtk find`、`rtk ls` 和显式 `rtk read`；
- 安装、升级、冲突告警、备份、卸载、`-WhatIf` 和幂等；
- `RTK.md` 指令重叠告警不会修改 `AGENTS.md` 或 `RTK.md`；
- 生产脚本静态安全审计；
- 发布 ZIP 内容和 SHA-256；
- 隔离、只读的全命令与 `rtk read` 评估、结构化报告输出，以及 RTK 命令未分类数量为 0。

当前本地结果：七套测试共 431 条断言，全部零失败通过；PSScriptAnalyzer `1.25.0` 和 actionlint `1.7.12` 也都是零告警通过。

[读取评估](read-evaluation.zh-CN.md)记录了 RTK 0.44.2 样本的输入哈希和测试方法。默认 read 逐字相同但不节省估算 token；有损模式继续作为显式工具，而非自动改写。

[全命令评估](command-evaluation.zh-CN.md)对 RTK 0.44.2 的 79 条命令全部完成分类，未分类数量为 0。选定命令输出矩阵中的 11 个任务等价案例从 25,598 token 降至 15,173，加权节省 40.7%；另外 4 个显式过滤视图单独报告。普通读取、其他 Preserve 输出和非工具上下文不在这个分母内。

## 真实 Codex 发布门禁

打 tag 前运行 `scripts/run-real-codex-e2e.ps1`。它创建一次性 Codex home 和只监听 `127.0.0.1` 的确定性 Responses API 固件，不需要 OpenAI 认证；固件只把请求正文记录在被 Git 忽略的 `artifacts/e2e/<timestamp>`，不记录请求头。脚本不会读取当前 Codex provider 或认证文件。

门禁对同一条原始模型命令 `git status --short` 执行两个阶段：

1. 在 `workspace-write` 且审批策略为 `never` 时，默认安装把命令改写为裸 `rtk git status --short`，随后 Codex 拒绝执行，证明 `updatedInput` 不会绕过 Codex 策略；
2. 仅针对这条固定本地命令显式关闭审批和 sandbox 后，同一改写成功执行，shell 输出作为 `function_call_output` 出现在下一次 Responses 请求中。

当前门禁状态：**已于 2026-08-02 通过**。环境为 Codex CLI `0.146.0`、RTK `0.44.2`、PowerShell `7.6.4`、Windows `10.0.26200`。原生读取、混合计划、对象管道 Preserve、RTK 缺失 fail-open 和更广命令矩阵仍由确定性测试套件负责。这项门禁验证真实 Codex Hook/运行时协议，不验证任何外部模型或 provider 的质量。

## 已知限制

- 只支持原生 Windows PowerShell。
- 只处理 Codex 规范名称为 `Bash` 的匹配调用；Hosted tool 不在范围内。
- Codex 特殊工具路径可能绕过默认 Hook；官方也把 Hook 定义为 guardrail，而非完整安全边界。
- 当前 Codex 的多个 `updatedInput` 写者按完成顺序竞争；同一 `Bash` 路径只应有一个改写 Hook。
- RTK 输出有意压缩，不承诺与原命令逐字节相同。
- 动态 PowerShell、赋值、重定向和无法证明安全的对象管道有意保持原样。

## 一手来源

- [Codex Hooks 官方文档](https://developers.openai.com/codex/hooks)
- [固定提交中的 Codex completion-order 实现](https://github.com/openai/codex/blob/e4836f998da166aba456f60d2e74eb79d6e2542b/codex-rs/hooks/src/events/pre_tool_use.rs#L121-L156)
- [RTK 仓库和 Windows 安装说明](https://github.com/rtk-ai/rtk)
- [RTK v0.44.2 Release](https://github.com/rtk-ai/rtk/releases/tag/v0.44.2)

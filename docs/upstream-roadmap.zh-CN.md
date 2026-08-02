# 上游现状与改进建议手册

现状快照：2026-08-02。本文只记录事实、边界和建议；本项目目前没有向 RTK 或
Codex 提交 issue、PR 或远程分支。

## 现在到底是什么状况

当前 [Codex Hooks 官方文档](https://developers.openai.com/codex/hooks) 已经
明确支持透明改写：`PreToolUse` 返回 `permissionDecision: "allow"` 和
`updatedInput`，工具随后使用替换后的参数执行。

RTK 当前 README 对 Codex 的说明仍是 `AGENTS.md + RTK.md` 指令约束，而有原生
Hook 的 Agent 可以直接透明改写。RTK 已经通过 `rtk rewrite` 提供统一注册表，
所以本项目做的是 Windows PowerShell 协议适配，不是在外部复制一份 RTK 规则。

RTK PR [#1550](https://github.com/rtk-ai/rtk/pull/1550) 曾在 Codex 不能可靠
应用 `updatedInput` 的前提下设计 deny-and-retry。对于当前已验证的 Codex 基线，
这个前提已经过时。deny-and-retry 会多一次模型推理和 token，透明 `updatedInput`
才是现在合理的形状。

## 哪些事情属于本项目

- Windows PowerShell AST 分类和对象流保护。
- Codex JSON 到 `rtk rewrite` 的兼容适配。
- 在 RTK 上游没有原生透明 Codex 安装器时，提供安全安装与卸载。
- 保守的 fail-open 行为和可复现兼容性证据。

本项目不应该复制 RTK 命令注册表，也不应该膨胀成跨平台 Agent 框架。

## RTK 上游应该补什么

### 1. 原生透明的 `rtk hook codex`

真正的终局应当是 RTK 自己提供一个原生命令：

1. 从 stdin 读取 Codex `PreToolUse` JSON；
2. 在同一个 Rust 进程中直接调用内部 `rewrite_command()`；
3. 返回 Codex 的 `permissionDecision: "allow" + updatedInput`；
4. 由 `rtk init -g --codex` 负责安装、查看和卸载；
5. Windows、Linux、macOS 使用同一实现。

这是 RTK 上游优化，不是本项目再套一层可以达到的优化。它能彻底去掉当前
PowerShell Hook 再启动 `rtk rewrite` 子进程的开销，并让协议适配与注册表跟随
同一个二进制版本。

### 2. 结构化批量 rewrite API

当前 CLI 接受一整条命令字符串。为了让混合计划只启动一次 RTK，本项目只能用
经过 AST 校验的哨兵边界暂时编码多个槽位。上游更合理的接口是：

```json
{
  "commands": [
    { "id": "0", "command": "git status" },
    { "id": "1", "command": "cargo check" }
  ]
}
```

例如新增：

```text
rtk rewrite --batch-json
```

返回：

```json
{
  "results": [
    { "id": "0", "status": "rewritten", "command": "rtk git status" },
    { "id": "1", "status": "rewritten", "command": "rtk cargo check" }
  ]
}
```

每项必须带稳定 id 和明确的 `rewritten / unchanged / error` 状态；单项失败不能
污染相邻命令。再提供 `rtk capabilities --json`，适配器就不必猜版本。

这同样属于 RTK 上游。上游没有结构化 batch 之前，本项目保留哨兵微批处理作为
兼容方案。

### 3. 面向外部 Planner 的能力元数据

RTK 不需要自己解析 PowerShell AST，但注册表可以暴露命令是文本输入、文本输出
还是存在对象语义风险。外部 Planner 由此可以更准确地决定哪些槽位能委托。

单条命令的结构化结果可以是：

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

`status` 区分“支持但无需修改”和真正错误；`lossless` 与 `output_kind` 让调用方
判断摘要是否满足当前请求；管道元数据让 shell-aware 适配器在下游需要原生对象
时拒绝文本替换。`expected_savings` 只能是估算，不能成为静默接受有损输出的指令。

`rewrite --json` 与 `rewrite --batch-json` 中的每个结果应该共用这一套 schema，
并通过 `rtk capabilities --json` 发现能力，而不是让集成猜版本。

### 4. Read 意图与可测量取舍

仓库内的[读取评估](read-evaluation.zh-CN.md)显示：RTK 0.44.2 默认 read 对样本
逐字相同、估算 token 零节省，却增加了子进程启动；`minimal` 只节省 3.3%；
`aggressive` 和行窗口节省很高，但属于有损视图；行号模式反而增加 15.3% 输出。

这个证据支持“暴露意图元数据”，不支持“一律自动改写读取”。RTK 集成需要区分
精确源码、严格行窗口、代码轮廓和带行号引用。相关上游讨论包括
[#822](https://github.com/rtk-ai/rtk/issues/822)、
[#582](https://github.com/rtk-ai/rtk/issues/582) 和
[#1362](https://github.com/rtk-ai/rtk/issues/1362)。

本项目不会把推测性的对象管道 rewrite 结果做成持久化自学习缓存。PowerShell
Provider、alias、module、变量和 .NET 对象条件无法由一次历史结果证明等价；
缓存还会引入失效、隐私和安全责任，超出兼容适配层边界。

## Codex 上游问题：多个 `updatedInput` 写者

在固定源码提交
[`e4836f9`](https://github.com/openai/codex/blob/e4836f998da166aba456f60d2e74eb79d6e2542b/codex-rs/hooks/src/events/pre_tool_use.rs#L121-L156)
中，匹配的 Hook 并发执行，`latest_updated_input()` 选择 completion order 最大的
结果。源码注释直接写明：实际完成得最晚的 Hook 获胜。

```text
Hook A（RTK）:    git status -> rtk git status     30 ms 完成
Hook B（包装器）: git status -> audit git status   40 ms 完成
最终结果：B 覆盖 A。
```

如果时序反过来，结果也反过来。两个 Hook 都拿不到对方的输出，因此无法组合。
这属于 Codex 协议/运行时问题，不是 RTK bug，也不是安装器能安全解决的事情。

### 建议 Codex 怎样改

首选方案是确定性的串行 mutation pipeline：

1. 按配置声明顺序执行匹配的改写 Hook；
2. 后一个 Hook 接收前一个 Hook 已经修改过的当前 `tool_input`；
3. 审计记录每一步 mutation；
4. 最终输入再进入审批和 sandbox。

如果必须保持并行执行，那么一旦超过一个 Hook 成功返回 `updatedInput`，Codex
应该报告明确冲突，而不是按完成时序静默选一个。可以再提供显式 priority，但
priority 只能决定胜负，不能让独立变换自然组合。

无论选择哪一种，官方手册都应该写明。当前文档解释了单个 `updatedInput` 的
格式，却没有说明多写者按完成顺序竞争。

## 最终迁移方向

当 RTK 上游提供原生透明 Codex Hook，并且具备结构化或进程内 rewrite 后，本项目
应该变成以下二者之一：

- 把仍有价值的 PowerShell 规则贡献给上游；
- 进入兼容维护/弃用状态，并提供明确迁移命令。

我们的目标不是永久维护一层中间件，而是先把桥做正确，同时把上游缺失的契约
变成足够具体、可以测试和讨论的提案。

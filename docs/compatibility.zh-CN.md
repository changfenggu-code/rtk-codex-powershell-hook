# 兼容性与验证记录

最后更新：2026-08-02。

## 已验证基线

| 组件 | 已验证版本 | 状态 |
| --- | --- | --- |
| Windows | Windows 11 家庭中文版，10.0.26200（build 26200） | 支持基线 |
| PowerShell | 7.6.4 | 通过 |
| RTK | 0.44.1 | 通过 |
| Codex CLI | 0.146.0 | 协议和本地运行时基线 |

不声明更早版本可用。Codex Hook 语义和 RTK rewrite 覆盖会分别演进，新版本也应
重新跑发布门禁。

## 自动化证据

Windows CI 与本地 `tests/run-all.ps1` 共同覆盖：

- PowerShell AST 正向规则和拒绝规则；
- Codex `PreToolUse` JSON 输入、输出和字段保留；
- 0/1/多个 Delegate 对应 0/1/1 次 RTK 进程；
- 纯 Delegate 整体调用和混合计划 GUID 槽位校验；
- PowerShell 对象管道保持原样且 RTK 调用数为 0；
- 带空格和单引号的精确 RTK 路径；
- RTK 缺失、JSON/PowerShell 语法错误、超大输入时 fail-open；
- 实际执行生成的 `rtk rg`、`rtk find`、`rtk ls` 和显式 `rtk read`；
- 安装、升级、冲突告警、备份、卸载、`-WhatIf` 和幂等；
- 生产脚本静态安全审计；
- 发布 ZIP 内容和 SHA-256。

当前本地结果：五套测试、`304` 个断言、零失败；PSScriptAnalyzer `1.25.0`
和 actionlint `1.7.12` 也都是零告警通过。

## 真实 Codex 发布门禁

打 tag 前必须用隔离 Codex home 证明：

1. 原始 `git status` 通过安装器绑定的 RTK 执行；
2. 原生 `Get-Content` 不被改写；
3. 混合命令只改 RTK Delegate，Preserve/本地范围正确保留；
4. PowerShell 对象管道不启动 RTK rewrite；
5. 配置的 RTK 路径缺失时 fail-open；
6. 改写后仍然经过 Codex 正常审批和 sandbox；
7. 记录 Codex、RTK、PowerShell、Windows 版本和日期。

发布工作流不能代替这项本地集成门禁。CI 能确定性验证协议和打包，真实 Codex
运行需要本地已配置会话。

当前模型支持的真实门禁状态：**尚未通过**。第一次隔离 home 尝试证明 Codex
`0.146.0` 识别了 Hook 配置，但复制的 API-key 凭据在任何工具调用前返回 `401`；
第二次原本准备使用当前有效 provider，但该 provider 是非标准外部 HTTP 地址，
在没有明确同意把测试 prompt 和 Codex 正常上下文发送过去之前没有执行。本文不
用这两次尝试冒充工具调用成功。审查并同意当前 provider 后，才运行
`scripts/run-real-codex-e2e.ps1 -AllowProviderRequest`。

## 已知限制

- 只支持原生 Windows PowerShell。
- 只处理 Codex 规范名称为 `Bash` 的匹配调用；Hosted tool 不在范围内。
- Codex 特殊工具路径可能绕过默认 Hook；官方也把 Hook 定义为 guardrail，而非
  完整安全边界。
- 当前 Codex 的多个 `updatedInput` 写者按完成顺序竞争；同一 `Bash` 路径只应
  有一个改写 Hook。
- RTK 输出有意压缩，不承诺与原命令逐字节相同。
- 动态 PowerShell、赋值、重定向和无法证明安全的对象管道有意保持原样。

## 一手来源

- [Codex Hooks 官方文档](https://developers.openai.com/codex/hooks)
- [固定提交中的 Codex completion-order 实现](https://github.com/openai/codex/blob/e4836f998da166aba456f60d2e74eb79d6e2542b/codex-rs/hooks/src/events/pre_tool_use.rs#L121-L156)
- [RTK 仓库和 Windows 安装说明](https://github.com/rtk-ai/rtk)
- [RTK v0.44.1 Release](https://github.com/rtk-ai/rtk/releases/tag/v0.44.1)

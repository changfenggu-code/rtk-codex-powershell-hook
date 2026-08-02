# RTK Codex PowerShell Hook

这是一个面向 Windows/PowerShell 的确定性适配层：在 Codex 真正执行 `Bash` 工具命令前，通过 [RTK](https://github.com/rtk-ai/rtk) 对命令进行透明改写。

Codex 现在已经支持 `PreToolUse` 返回 `permissionDecision: "allow"` 和 `updatedInput`，RTK 0.44.2 也已经通过 `rtk rewrite` 暴露统一改写注册表；但 RTK 文档中的 Codex 接入目前仍以 `AGENTS.md + RTK.md` 指令约束为主。本项目把两端连接起来，不让模型重试，也不依赖模型记住“主动加 rtk 前缀”。

这是独立的社区项目，与 OpenAI 或 RTK 维护团队不存在隶属或背书关系。

[English](README.md) | [中文规范](docs/SPEC.zh-CN.md) | [兼容性](docs/compatibility.zh-CN.md) | [全命令评估](docs/command-evaluation.zh-CN.md) | [读取评估](docs/read-evaluation.zh-CN.md) | [上游改进手册](docs/upstream-roadmap.zh-CN.md)

## 项目边界

- 只支持原生 Windows + PowerShell。
- 只处理 Codex `PreToolUse` 中规范名称为 `Bash` 的工具调用。
- 使用 `updatedInput` 原地改写，不采用 deny-and-retry。
- 它是输出优化器，不是权限来源；Codex 的审批和 sandbox 仍在改写后照常执行。

Linux、macOS、WSL 和其他 Agent 的通用方案应该最终进入 RTK 上游的原生 Codex Hook，而不是继续扩大这个 PowerShell 兼容层。

## 环境要求

- Windows
- PowerShell 7（`pwsh.exe`）
- 支持 `rtk rewrite` 的 RTK；已验证基线为 `0.44.2`
- 支持 `PreToolUse.updatedInput` 的 Codex；已验证基线为 Codex CLI `0.146.0`

## 安装

先预览，不写任何文件：

```powershell
.\install.cmd -WhatIf
```

使用自动 RTK 探测：

```powershell
.\install.cmd
```

不传 `-RtkPath` 时，安装器先按 PowerShell 的实际执行顺序检查名为 `rtk` 的应用程序。若 `PATH` 中排在第一位的有效命令兼容，就保留裸 `rtk` 调用；若 `PATH` 中没有兼容 RTK，则依次检查有限的 Cargo 位置、官方 Windows 本地二进制示例位置 `%USERPROFILE%\.local\bin\rtk.exe`，最后检查有限的 Scoop 位置，并用验证后的兜底绝对路径绑定。安装器不会递归扫描磁盘、调用 Homebrew 或 Unix 安装脚本，也不会修改 `PATH`。

也可以由用户显式提供 RTK 绝对路径：

```powershell
.\install.cmd -RtkPath 'C:\Tools\rtk.exe'
```

安装器会先验证 `rtk --version` 和 `rtk rewrite --help`，然后原子复制 Hook，使用结构化 JSON API 向 `~/.codex/hooks.json` 合并且只合并一个注册项。其他 Hook 不会被删除或换序；已有文件会备份到 `~/.codex/backups/rtk-codex-hook/<timestamp>/`。

安装器不会修改 `%APPDATA%\rtk\config.toml` 或其他 RTK 配置。RTK 中可选的 `exclude_commands = ["cat", "head", "tail"]` 可以保护其他集成，但本 Hook 自身不依赖它，读取边界由 AST Planner 和返回结果校验独立保证。

透明 Hook 会取代 RTK 旧有的“Always prefix shell commands with rtk”指令式集成。如果 `~/.codex/AGENTS.md` 引用了 `RTK.md`，应在重启 Codex 前移除这条引用，让 Hook 收到模型生成的原始命令。安装器会对直接引用发出警告，但绝不会修改 `AGENTS.md` 或 `RTK.md`。

安装完成后重启 Codex。普通 `PATH` 模式下，模型发出的原始 `git status` 应改写为 `rtk git status`；显式路径、PATH 冲突或 Cargo/Scoop 兜底模式则使用 PowerShell call operator 加验证后的绝对路径。

可以通过 `-CodexHome <目录>` 安装到隔离环境。安装器拒绝把卷根目录当作 Codex home。

## 卸载

预览：

```powershell
.\uninstall.cmd -WhatIf
```

正式卸载：

```powershell
.\uninstall.cmd
```

卸载器只删除本项目的 Hook 文件和注册项，同样先做备份；不会删除 RTK、Codex、其他 Hook 或其他配置。

## 核心算法

Hook 先用 PowerShell 官方 AST 解析器理解命令，然后把每个符合条件的顶层范围分成三类：

- `Preserve`：普通读取、变量、重定向、对象管道、动态命令解析和无法证明安全的结构保持原样。
- `HookRewrite`：`Select-String`、`Get-ChildItem`、完整的 `Get-Content | Select-String` 等已证明映射由 Hook 本地完成。
- `DelegateToRtk`：RTK 已支持的原生命令交给 `rtk rewrite`。

没有 Delegate 就不启动 RTK；一个 Delegate 启动一次；全部顶层命令都是 Delegate 时，整条原始命令一次送入 RTK。只有 Preserve、HookRewrite 与 Delegate 混合时，才复制 Delegate 槽位形成带随机 GUID 边界的临时批次；RTK 返回后再用 AST 校验边界并映射回原始 extent。无论组合命令多长，每次 Hook 最多启动一个 RTK 子进程。

```powershell
git status; cargo check
# -> rtk git status; rtk cargo check

Get-Content Cargo.toml | Select-String workspace
# -> rtk rg -n -i -e 'workspace' -- 'Cargo.toml'

Get-ChildItem src -File | Select-Object Name,Length | Format-Table
# -> 保持原样；这是 PowerShell 对象管道，而且不会白启动一次 RTK

Get-Content -Raw Cargo.toml
# -> 保持原样；普通读取不进入自动 RTK 改写面
```

RTK 自动生成的 `rtk read` 会按槽位拒绝；用户明确写出的 `rtk read` 保留。绝对路径绑定模式会在最终输出边界统一处理输入中原本就存在的静态 `rtk` 与 `rtk.exe` 命令，这些已加前缀的独立命令不会再送入 registry 做一次无意义 rewrite。

示例展示默认的裸 `PATH` 模式；显式或兜底绝对路径安装会把每个生成的 `rtk` 替换为 `& '<已验证绝对路径>'`。

Planner 是确定且无状态的：它不持久化命令文本、rewrite 结果或对象管道分类，也不会根据一次推测性的 RTK 返回结果“学习”未来改写。

## 多个改写 Hook 的风险

当前 Codex 在多个匹配的 `PreToolUse` Hook 都返回 `updatedInput` 时，会选择“实际完成得最晚”的结果。它不是配置顺序，而是运行时竞态。安装器会扫描其他可能匹配 `Bash` 的 command Hook 并给出警告，但无法静态证明对方是否会返回 `updatedInput`。

因此，同一个 `Bash` 工具路径应该只有一个改写者；只做日志或策略检查且不返回 `updatedInput` 的 Hook 可以共存。当前源码证据和建议的上游修复方案记录在[上游改进手册](docs/upstream-roadmap.zh-CN.md)。

## 测试与发布包

运行与 CI 完全相同的入口：

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\run-all.ps1
pwsh -NoLogo -NoProfile -NonInteractive -File .\scripts\run-lint.ps1 -Bootstrap
pwsh -NoLogo -NoProfile -NonInteractive -File .\scripts\run-actionlint.ps1 -Bootstrap
```

生成 ZIP 和 SHA-256：

```powershell
pwsh -NoProfile -File .\scripts\package-release.ps1 -Version 0.1.0
```

用确定性的本机回环 provider 运行真实 Codex 运行时门禁：

```powershell
pwsh -NoProfile -File .\scripts\run-real-codex-e2e.ps1
```

这条命令创建一次性 `CODEX_HOME`，并启动只监听 `127.0.0.1` 的本地 Responses API 固件。它不会读取当前 Codex provider 或认证文件，也不会把数据发送到本机之外。第一阶段证明改写后的命令仍会被 Codex 策略拦截；第二阶段只执行固定的 `git status --short`，并验证输出确实经由真实 Codex 运行时返回。运行该门禁需要 Node.js。

测试覆盖 AST 规则、Codex JSON 协议、RTK 调用次数、真实生成命令、带空格和单引号的路径、RTK 缺失时 fail-open、安装/升级/卸载、全命令分类、隔离评估器、静态安全审计与发布包内容。

可以用下面的命令复现项目范围内的 RTK 命令清单与输出节省矩阵：

```powershell
pwsh -NoProfile -File .\scripts\evaluate-command-savings.ps1 `
  -EvaluationProfile Full -Iterations 3
```

[全命令评估报告](docs/command-evaluation.zh-CN.md)对 RTK 0.44.2 暴露的 79 条命令全部做了分类，并实测所有适用于本仓库的命令族。文档基准中，被选中的任务等价命令输出加权节省为 40.7%；这不是整个 AI 会话的节省率，普通文件读取和其他 Preserve 输出占比越高，真实工具输出级比例越低。

可以用下面的命令复现读取策略测试；脚本使用一次性 RTK tracking 数据库，不会改动用户的 RTK 配置或统计数据库：

```powershell
pwsh -NoProfile -File .\scripts\evaluate-read.ps1 -File .\rtk-codex-hook.ps1
```

RTK 0.44.2 的实测数据与解释见[读取评估报告](docs/read-evaluation.zh-CN.md)。

## 安全模型

生产 Hook 不执行原始命令。它只解析字符串、调用安装时绑定的 RTK 执行 `rewrite`、验证返回命令并输出 Codex 协议 JSON；不写文件、不下载代码、不启动后台进程，也不替代 Codex 的审批与 sandbox。

Hook 故障时退出码为 `0` 且 stdout 为空，让 Codex 回到原始命令。这种 fail-open 适合输出优化器，不适合安全拦截器。不要用本项目实现命令禁用策略。

## 许可证

Apache License 2.0。参见 [LICENSE](LICENSE) 与 [DISCLAIMER.md](DISCLAIMER.md)。

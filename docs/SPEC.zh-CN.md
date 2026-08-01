# Codex RTK PowerShell Hook 改写规范

## 边界说明

可以把现在 Hook 的边界理解成一句话：

> **命令结构能静态确认、参数是字面量、存在明确 RTK 等价形式，并且不会破坏 PowerShell 对象管道时，就改写；其余原样执行。**

这里的“防住”是自动改写，不是拦截执行。

**绿色：稳定改写**

搜索内容：

```powershell
Select-String -Path Cargo.toml -Pattern workspace
# -> rtk rg -n -i -e 'workspace' -- 'Cargo.toml'

Select-String -CaseSensitive -Path src/lib.rs -Pattern RuntimeActor
# -> rtk rg -n -e 'RuntimeActor' -- 'src/lib.rs'

Select-String -SimpleMatch -Path README.md -Pattern 'a.b'
# -> rtk rg -n -i -F -e 'a.b' -- 'README.md'

Select-String -Context 1,2 -Path src/lib.rs -Pattern actor
# -> rtk rg -n -i -B 1 -A 2 -e 'actor' -- 'src/lib.rs'

Select-String -Path src/lib.rs -Pattern '(?<=Runtime)Actor'
# -> rtk rg -n -i --pcre2 -e '(?<=Runtime)Actor' -- 'src/lib.rs'
```

目录查询：

```powershell
Get-ChildItem src
# -> rtk ls 'src'

Get-ChildItem -Force src
# -> rtk ls -a 'src'

Get-ChildItem src -Recurse -Filter '*.rs' -File
# -> rtk find 'src' -name '*.rs' -type f

Get-ChildItem src -Depth 2 -Directory
# -> rtk find 'src' -name '*' -type d -maxdepth 3
```

可以整体折叠的管道：

```powershell
Get-Content Cargo.toml | Select-String workspace
# -> rtk rg -n -i -e 'workspace' -- 'Cargo.toml'
```

简单复合命令也能逐段改写：

```powershell
Get-Content a.rs; Get-Content b.rs
# -> 保持原样

Get-Content a.rs && Get-ChildItem src
# -> Get-Content a.rs && rtk ls 'src'
```

RTK 自己原本支持的命令继续由 `rtk rewrite` 处理：

```powershell
git status
# -> rtk git status

cargo check -p btleplus
# -> rtk cargo check -p btleplus

rg RuntimeActor crates
# -> rtk rg RuntimeActor crates
```

当全部顶层命令都属于 RTK Delegate 时，整条原始命令一次交给 `rtk rewrite`；
当 Delegate 与 Preserve/HookRewrite 混合时，才把多个不连续候选复制到临时
批次，一次完成改写，再按原始 AST extent 放回。原始命令本身不会插入哨兵：

```powershell
git status; head -10 Cargo.toml; cargo check
# -> rtk git status; head -10 Cargo.toml; rtk cargo check
```

建议 RTK 配置在 `[hooks].exclude_commands` 中包含 `cat`、`head` 和 `tail`，
作为其他 RTK 集成的纵深保护。Codex Hook 的正确性不得依赖该配置：读取命令
必须由 AST 计划保持原样，任何返回槽位中的 `rtk read` 候选也必须被拒绝。
显式调用 `rtk read file -l minimal/aggressive` 不受影响。

**黄色：有意保持原样**

所有单纯文件读取：

```powershell
Get-Content -Raw Cargo.toml
Get-Content -TotalCount 100 Cargo.toml
Get-Content -Tail 50 app.log
Get-Content Cargo.toml | Select-Object -First 100
Get-Content app.log | Select-Object -Last 50
cat Cargo.toml
head -100 Cargo.toml
tail -50 app.log
```

普通 `rtk read` 默认完整输出，自动替换不能减少 token，且会增加进程开销；
`--max-lines` 是智能摘要而不是严格的前 N 行。因此读取命令保持原样，
`rtk read` 只作为显式过滤或预览工具使用。

参数依赖运行时变量：

```powershell
Get-Content $env:USERPROFILE\.codex\RTK.md
Get-Content "$root\Cargo.toml"
Select-String -Pattern $pattern -Path Cargo.toml
```

因为 AST 只能知道这里有变量，不能提前知道最终路径或模式。

带重定向：

```powershell
Get-Content Cargo.toml > copy.txt
Select-String foo -Path src/lib.rs > matches.txt
```

RTK 搜索或目录输出是面向模型的文本视图，不应拿去覆盖文件。

不能完整映射的行窗口：

```powershell
Get-Content search.rs | Select-Object -Skip 450 -First 130
```

该命令本身已经把输出限制为 130 行；自动改写既不继续节省 token，也无法
保持严格的起始行语义。

依赖 PowerShell 对象的管道：

```powershell
Get-ChildItem src -File |
    Sort-Object Name |
    Get-FileHash |
    Select-Object Path,Hash
```

`Get-ChildItem` 输出 `FileInfo` 对象；`rtk ls` 输出文本。替换后 `Get-FileHash` 会失效。

作为程序内部数据使用：

```powershell
$content = Get-Content Cargo.toml
$result = Select-String foo -Path src/lib.rs
Write-Output $(Get-Content Cargo.toml)
```

这类命令不是单纯把结果展示给模型，Hook 不会擅自改变数据形状。

动态改变命令解析环境：

```powershell
Set-Alias gc Write-Output
Import-Module Example
function Get-Content { 'custom implementation' }
```

发现这些结构后，本次 PowerShell 补充改写整体退出。

**红色边界：不会处理**

没有 RTK 等价能力：

```powershell
Get-Module
Get-FileHash
Sort-Object
Format-Table
ConvertFrom-Json
```

语法不完整：

```powershell
Get-Content 'unterminated
$$stage = ...
```

复杂脚本中的外部命令目前也可能不改：

```powershell
$matches = rg pattern file
if ($LASTEXITCODE -eq 1) {
    'none'
} else {
    $matches
}
```

这里整个脚本超出 RTK 原生解析范围，而 AST 补充层不会改写赋值右侧的外部命令。

实际判断时可以用这个简化流程：

```text
有 RTK 映射吗？
  否 -> 原样执行
  是
    参数都是静态字面量吗？
      否 -> 原样执行
      是
        改写会破坏对象管道、赋值、重定向或脚本控制流吗？
          是 -> 原样执行
          否 -> 自动改写
```

所以它大致覆盖日常搜代码、列目录以及可整体折叠的搜索管道；单纯查看文件
继续由 PowerShell 原生命令完成，也不会把通用 PowerShell 脚本强行文本化。

---

## 补充规范

### 1. 规范性术语

本文后续使用以下含义：

- **必须**：实现或变更不可违反的行为。
- **应该**：除非有明确且记录过的理由，否则应遵守的行为。
- **可以**：不影响协议正确性的可选行为。
- **保持原样**：Hook 以退出码 `0` 结束且不向 stdout 写入内容，由 Codex 执行原始命令。

### 2. 目标与非目标

本 Hook 的目标是降低 Codex 处理常见开发命令输出时的 token 消耗，同时保持命令安全边界和 PowerShell 数据流成立。

本 Hook 不是：

- PowerShell 命令禁用器或安全沙箱；
- 通用 PowerShell 到 POSIX Shell 的翻译器；
- PowerShell 对象管道优化器；
- 对所有 `Get-Content`、`Select-String` 或 `Get-ChildItem` 文本出现的强制替换器；
- Codex 自身审批、sandbox 或命令安全策略的替代品。

### 3. 处理顺序

实现必须依次执行以下步骤：

1. 校验 Codex `PreToolUse` 输入、`tool_name` 和 `tool_input.command`。
2. 使用 PowerShell 官方 AST 解析原始命令。
3. 将完整顶层命令或管道规划为 `Preserve`、`HookRewrite` 或
   `DelegateToRtk`，并保存每个节点在原始字符串中的 extent。
4. 在内存中完成 `HookRewrite`；`Preserve` 不进入 RTK 输入。
5. 没有 Delegate 时不启动 RTK；一个 Delegate 直接调用一次；如果全部顶层
   pipeline 都是 Delegate，则整条原始命令调用一次；混合计划中的多个 Delegate
   才复制到带随机 GUID 哨兵的临时批次。每次 Hook 最多调用一次 `rtk rewrite`。
6. 使用 PowerShell AST 校验 RTK 返回的哨兵和槽位，把候选映射回原始 extent；
   任何生成 `rtk read` 的候选只回退对应槽位。
7. 只有最终命令与原始命令不同时，才返回 Codex `updatedInput`。
8. 任意异常、超时、无效 JSON、语法错误或无法证明安全的结构都必须 fail-open。

### 4. Codex 协议要求

改写响应必须具有以下形状：

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "Accept RTK input rewrite; Codex still applies its own approval and sandbox policy",
    "updatedInput": {
      "command": "rtk rg -n -i -e 'workspace' -- 'Cargo.toml'"
    }
  }
}
```

实现必须保留 `tool_input` 中除 `command` 外的其他字段。`permissionDecision: "allow"` 只表示 Codex 接受 `updatedInput`，不能绕过 Codex 后续审批或 sandbox。

未发生改写时，stdout 必须为空。普通文本不能作为 PreToolUse 改写响应使用。

### 5. 静态安全条件

PowerShell 补充改写必须满足以下条件：

- 命令名称可由 AST 静态解析；
- 路径、模式、计数和上下文参数均为常量表达式；
- 路径不是动态变量、子表达式或非文件系统 Provider；
- `-Path` 不包含通配符；`-LiteralPath` 可以包含字面通配符字符；
- 命令没有输出重定向；
- 命令位于顶层或属于受支持的完整管道；
- 命令解析环境没有被函数定义、alias 变更或模块导入动态改变；
- 生成参数必须使用 PowerShell 单引号，并将内部单引号转义为两个单引号；
- 无法识别的参数必须导致该候选保持原样，不能被忽略。

RTK 批次还必须满足：

- 仅复制 `DelegateToRtk` 的原始 extent 文本，绝不执行临时批次；
- 每个批次使用不与原始输入冲突的随机 GUID，并为 N 个槽生成 N+1 个边界哨兵；
- RTK 输出中的哨兵必须数量正确、名称唯一、顺序一致，并且仍是无参数的顶层命令；
- 槽位必须从两个相邻哨兵之间提取，不能用普通字符串 `Split(';')`；
- 哨兵或输出 AST 校验失败时，所有 Delegate 保持原样；
- 生成的批次超过 `1 MiB` 时不得调用 RTK。

### 6. 对象语义边界

PowerShell cmdlet 可以返回强类型对象，而 RTK 子命令主要返回供模型阅读的压缩文本。因此：

- `Get-ChildItem | Get-FileHash` 之类的对象管道必须保持原样；
- 赋值右侧、子表达式和未知消费者前的 cmdlet 必须保持原样；
- 只有整个管道能被证明可折叠为一个 RTK 命令时，才可以替换整个管道；
- 已识别的 PowerShell 对象管道必须在 Planner 阶段直接 Preserve，不得先调用
  RTK 试写再回退；
- 不得仅因命令文本包含受支持名称就在任意 AST 深度进行替换。

### 7. 已知的有损差异

RTK 本身是面向模型输出的压缩层，不保证与原命令逐字节等价。绿色区域仍存在以下有意差异：

- `Select-String` 的 `MatchInfo` 对象被替换为 `rg` 文本输出；因此只允许用于直接展示或已知可折叠管道。
- `Get-ChildItem` 的 `FileInfo` / `DirectoryInfo` 对象被替换为 `rtk ls` 或 `rtk find` 文本；因此不能进入未知对象消费者。
- `rtk find` 会应用自身的结果上限和 ignore 规则，适合代码探索，不适合作为完整文件清单的业务输入。
- .NET 正则与 ripgrep 正则并非完全同构。常见 lookaround/backreference 使用 PCRE2；已知无法安全映射的 .NET balancing group 必须保持原样。

`rtk read` 不属于自动改写面：普通读取没有 token 收益，智能截断也不等价于
PowerShell 的严格行窗口。调用方仍可以显式使用其过滤和预览能力。

### 8. 失败与安全策略

本 Hook 是输出优化器，不是执行许可来源：

- RTK 不存在、返回异常状态或超时时，必须继续尝试安全的 PowerShell 映射或保持原样；
- PowerShell AST 解析失败时必须保留原始命令；
- 输入超过 `1 MiB` 时必须保持原样；
- RTK 批次失败时必须保留所有 Delegate，但可以继续采用已独立验证的 HookRewrite；
- 生产 Hook 不得使用 `Invoke-Expression`、下载代码、启动后台进程或修改文件系统；
- Hook 自身所有故障路径必须退出 `0` 且不输出无效 JSON。

### 9. 运行环境

当前已验证基线面向以下环境：

- Codex CLI `0.146.0`；
- RTK `0.44.1`；
- PowerShell `7.6.4`；
- Windows 上由 Codex 提供 PowerShell session shell。

RTK 全局配置的 `[hooks].exclude_commands` 应当包含 `cat`、`head` 和
`tail`，但 Codex Hook 仍必须独立保护读取命令，并在返回槽位中拒绝任何生成
`rtk read` 的候选，同时保留同一批次中的其他合法改写。

`hooks.json` 使用 PowerShell call operator 直接执行 `.ps1`，避免再启动一个 PowerShell 进程。如果 Codex session shell 改为 `cmd.exe` 或 Git Bash，注册命令必须改为显式的 `pwsh -NoLogo -NoProfile -NonInteractive -File ...`。

安装器必须解析并验证一个 RTK 绝对路径，通过 `-RtkPath` 注入 Hook。该路径既要
用于 `rtk rewrite` 子进程，也要替换生成命令中的 `rtk`，确保改写阶段与最终
执行阶段使用同一个二进制。配置路径丢失时必须 fail-open，不得悄悄回退到
`PATH` 中的另一个 RTK。

当前 Codex 在多个匹配 Hook 都返回 `updatedInput` 时，选择实际完成得最晚的
结果。安装器应该对其他可能匹配 `Bash` 的 command Hook 发出潜在冲突警告，
但不得删除、重排或篡改它们。

### 10. 验收要求

每次修改生产 Hook 或改写规则后，必须运行：

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\run-all.ps1
```

验收至少覆盖：

- 每个绿色命令族的正向改写；
- 每个黄色和红色边界的保持原样；
- Codex JSON 输入、输出和字段保留；
- 无效 JSON、缺少字段、超大输入和 RTK 缺失时的 fail-open；
- 0/1/多个 Delegate 分别对应 0/1/1 次 RTK 调用；
- 纯 Delegate 计划整条调用且不使用哨兵，混合计划使用 N+1 哨兵；
- PowerShell 对象管道在 Planner 阶段 Preserve 且 RTK 调用数为 0；
- 随机批次 ID、N+1 哨兵、乱序/缺失/伪装哨兵以及带引号分号的槽位；
- `rtk read` 单槽回退不得牺牲同一批次中的其他合法改写；
- 通过子进程执行真实 Hook；
- 通过 `hooks.json` 所用命令形状启动 Hook；
- 验证原生文件读取保持原样，显式 `rtk read` 可用，并实际执行生成的
  `rtk rg --pcre2`、`rtk find` 和 `rtk ls`；
- 使用当前 Codex 版本生成的 `pre-tool-use.command.output.schema.json` 校验真实响应。
- 使用安装器绑定的、含空格与单引号的 RTK 路径完成子进程协议测试；
- 验证发布 ZIP 内容和 SHA-256，并在发版前通过本机回环 Responses 固件和一次性
  Codex home 完成真实 Codex 端到端门禁；门禁必须同时证明改写后仍受 Codex
  策略约束，以及固定命令在显式 bypass 阶段的真实执行结果会返回模型协议。

断言数量不是稳定接口；新增规则时，正向案例和对应的拒绝案例必须成对增加。

### 11. 安装器要求

- 安装器必须使用 PowerShell 7 的结构化 JSON API 合并配置，不得用文本替换修改 `hooks.json`；
- 只允许写入规范化后的 Codex home 内的 `hooks/rtk-codex-hook.ps1` 和 `hooks.json`；
- 卷根目录、无效现有 JSON、无效源 Hook 或越界目标必须在任何目标写入前失败；
- 安装前必须备份已有目标，临时文件必须与目标位于同一目录并在验证后替换；
- 重复安装必须保持一个 RTK 注册，同时保留其他 matcher 和 Hook；
- 安装前必须验证用户指定或 PATH 解析出的 RTK 绝对路径、`--version` 与
  `rewrite --help`；
- 卸载器只能删除本项目的注册项与 Hook 文件，并且必须保留其他 Hook；
- `-WhatIf` 必须不创建目录或文件；生产安装器不得递归删除目录。

### 12. 变更控制

- 新增 PowerShell 参数映射前，必须核对 PowerShell 原始语义和 RTK 真实 CLI 参数。
- 新增复杂管道规则前，必须证明整体数据流可以被一个等价 RTK 文本命令替代。
- 不得为了提高表面改写率而降低 fail-open 范围或改写对象管道。
- `rtk rewrite` 已覆盖的通用命令规则不得复制进 PowerShell 适配层。
- 规范、生产 Hook 和测试矩阵必须在同一轮变更中同步更新。

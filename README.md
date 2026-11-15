# Codex HUD

**放在桌面一角的 macOS 原生 Codex + Claude 用量浮窗。** 同屏查看两平台余量，保留 Codex 本机 Token、重置卡到期提醒和任务状态；靠边收起后也能同时看见两个平台的周余量。

[English](README.en.md) · [下载应用](https://github.com/chenlongzhen/codex-hud/releases/latest) · [安全审查](SECURITY_REVIEW.md) · [验收记录](VALIDATION.md) · [MIT 许可证](LICENSE)

<p align="center">
  <img src="docs/images/overview.png" width="340" alt="Codex HUD 总览：Weekly 额度、Token、任务数量及重置卡到期提醒">
</p>

*图中均为演示数据，不是作者的真实账户信息。V1 界面以简体中文为主，提供中英文使用文档。这是独立社区项目，并非 OpenAI 官方应用。*

## 能看什么

- **Codex Weekly 剩余额度与 Reset 时间**，不以 5h 替代。
- **Claude 5h / Weekly 本地额度观测**，和 Codex 同屏；一次手动状态栏接入，不读取 Claude 凭据。Claude Reset 不是重置卡。
- **Today 和当前 Weekly 周期的 Token**，点击可展开 Input、Cached input、Output、Reasoning。
- **重置卡数量及逐卡到期日**：距到期不超过三天显示橙色，不超过 24 小时显示红色。
- **运行中和待回复任务**，区分等待回答与等待批准，待回复不会重复计入运行中。
- **数据新鲜度与异常状态**，未知或未验证的数据不会显示成正常的零。
- **桌面浮窗与菜单栏摘要**，支持背景透明度、始终置顶开关和左右靠边自动收起。

无需额外 API Key，不读取浏览器 Cookie。程序不会发起、恢复或终止任务，不会回答审批，也不会消耗重置卡。

## Claude 接入：让 AI 帮你配置

不需要理解 JSON 或 shell。打开[给 AI 的接入文档](docs/claude-setup-for-agents.zh-CN.md)，交给能操作本机的 AI，并告诉它：

> 请按这份文档帮我接入 Claude 额度，先备份，保留我的已有设置和状态栏；不要读取登录凭据。完成后验证配置，并告诉我如何确认真实数据。

AI 会检查应用位置、备份设置、接好状态栏桥接。你最后只需在 Claude Code 里发一条消息，等待 HUD 收到额度数据。也可按[快速指南](docs/quickstart.zh-CN.md)手动配置。

> **版本说明：** 当前源码包含 Claude 功能；此次仅提交源码，尚未发布包含这些改动的新安装包。已有 GitHub Release 不保证包含 Claude 功能，可先从源码构建。应用未公证，真实 Claude 接入和干净机器首次安装仍需实测。

## 安装与启动

### 下载应用

1. 安装 Codex Desktop，或包含 Codex 的 ChatGPT，并先登录 Codex。
2. 从 [Releases](https://github.com/chenlongzhen/codex-hud/releases/latest) 下载 `CodexHUD-macOS-arm64.zip` 和 `.sha256`，可用 `shasum -a 256 -c CodexHUD-macOS-arm64.zip.sha256` 校验后解压。本轮仅本地候选包，未发布新 Release。
3. 配置 Claude 前先将 **Codex HUD.app** 拖入“应用程序”，然后打开；见[中文快速指南](docs/quickstart.zh-CN.md)。HUD 会寻找受支持的已安装 Codex CLI，使用它已有的登录状态。
4. 等待第一次本地扫描。本次开发机器取得完整初始快照约需十秒；历史记录较多时可能更久。

下载版适用于 **Apple Silicon**，使用本地 ad-hoc 签名，**没有开发者公证**，macOS 可能拦截下载的应用。也可以选择从源码在本机构建。程序不会自动安装更新器。可在设置中开启“登录时自动启动”，默认关闭。

自启动使用 macOS 原生登录项，在登录 Mac 后启动 HUD。建议先将应用放到固定位置，再开启此选项；开关以系统实际状态为准。如提示需要允许，点击“打开系统登录项设置”完成授权，也可随时在 HUD 设置中关闭。

源码目标为 **macOS 13+**，构建需要 **Swift 6**。实际验收环境为 macOS 26.2、Apple Silicon、Swift 6.0.3 和 Codex CLI 0.160.0。其他系统版本及 Intel 构建尚未实机验证。

### 首次打开：手动允许此应用

如果 macOS 提示无法验证开发者，或 Apple 无法检查应用是否包含恶意软件，确认安装包来自本仓库的 Releases 页面后，通常可以手动允许打开：

1. 先双击 **Codex HUD.app** 一次，让系统显示拦截提示。
2. 进入 **系统设置 → 隐私与安全性**，向下找到 Codex HUD 对应的提示，点击 **“仍要打开”**。
3. 在后续弹窗中确认 **“打开”**，并按系统要求完成身份验证。

系统会为这个应用保存例外，之后通常可以直接双击打开。这是针对单个应用的放行，无需关闭整个系统的门禁检查。详见 [Apple 官方操作说明](https://support.apple.com/zh-cn/102445)。受单位管理的 Mac 可能限制此选项。上述步骤适用于开发者身份或公证提示，不用于处理“应用已损坏”或检测到已知恶意软件的警告。

### 从源码构建

安装包含 Swift 6 的 Xcode 或 Command Line Tools，然后执行：

```sh
git clone https://github.com/chenlongzhen/codex-hud.git
cd codex-hud
./scripts/check.sh
./scripts/build.sh
open '../Codex HUD.app'
```

无需第三方包，仅使用系统 SwiftUI、AppKit、Foundation 和 SQLite。

也可指定应用输出位置：

```sh
./scripts/build.sh '/absolute/path/Codex HUD.app'
```

脚本生成 Release 可执行文件、图标和 `.app`，并校验本地签名。针对两种已知的 Command Line Tools 升级残留布局，构建包装脚本只在 `.build/` 中使用局部副本或覆盖，不修改系统工具链。

## 第一次使用

| 位置或按钮 | 操作与含义 |
| --- | --- |
| 左上角 **CODEX** | 按住这里拖动浮窗。 |
| **Weekly / Reset** | 查看剩余额度，Reset 按本机时区显示。 |
| **Today / Week** | 点击展开两个周期的 Token 明细。 |
| **重置卡** | 点击查看每张卡的到期日，最近到期的排在最前。 |
| **运行中 / 待回复** | 点击查看任务；再次点击某条任务可打开对应 Codex 聊天。 |
| 刷新图标 | 立即重新读取数据。 |
| 齿轮图标 | 打开浮窗和连接设置。 |
| **×** | 隐藏浮窗，菜单栏继续运行。 |
| 菜单栏摘要 | 显示/隐藏浮窗，切换置顶或靠边收起，刷新、打开 Codex、进入设置或退出。 |

<p align="center">
  <img src="docs/images/tokens.png" width="340" alt="Token 展开明细，使用演示数据">
  <img src="docs/images/tasks.png" width="340" alt="运行中与待回复任务，使用演示数据">
</p>

### 调透明度、置顶和靠边收起

点击齿轮，或菜单栏中的 **设置…**：

- **背景透明度**：范围 0%–80%，只调整背景，文字和数字保持可读。0% 保留默认深色毛玻璃效果。
- **始终置顶**：开启时显示在普通窗口上方，关闭后采用普通窗口层级。
- **靠边自动收起**：拖到屏幕左/右边缘 16 pt 内，鼠标移开约 0.7 秒后收成 46 × 166 pt CX/CL 双标签；关闭 Claude 时恢复原 36 × 108 pt 单标签。鼠标移入或点击标签展开；展开后拖动 CODEX 标识离开边缘，即恢复普通浮窗。顶部和底部不触发自动收起。

这三项设置即时生效并自动保存，不会重启数据连接。打开设置窗口时暂不自动收起。

<p align="center">
  <img src="docs/images/settings.png" width="520" alt="透明度、始终置顶、靠边自动收起及连接设置">
  <img src="docs/images/edge-tab.png" width="46" alt="靠边收起后的窄标签，保留额度数字和告警点">
</p>

## 数据怎么来

```mermaid
flowchart LR
    CLI[已安装的 Codex CLI] -->|只读 app-server 请求| Quota[Weekly 额度与重置卡]
    Desktop[Codex Desktop 本地 IPC] -->|可关闭的实验状态订阅| Tasks[本机任务状态]
    Logs[本地 session JSONL] -->|只保留 Token 事件| Tokens[增量 Token 汇总]
    Quota --> HUD[原生浮窗与菜单栏]
    Tasks --> HUD
    Tokens --> HUD
    Claude[Claude 官方状态栏 stdin] -->|仅额度白名单| Bridge[原生离线桥接]
    Bridge -->|私有原子快照| Observation[5h / Weekly 本地观测]
    Observation --> HUD
```

### 账户额度和重置卡

HUD 启动自己使用的 Codex app-server，通过 [官方 `account/rateLimits/read` 接口](https://learn.chatgpt.com/docs/app-server) 请求额度与逐卡明细。它选择 Codex 额度桶中时长为 10,080 分钟的窗口，无论该窗口位于 primary 还是 secondary；不会用 5h 或模型备用额度代替 Weekly。

账户数据常态每 60 秒刷新，展开详情或卡片明细不完整时每 15 秒刷新。卡片数量来自 `availableCount`，到期日来自逐卡明细。部分接口响应可能只给数量，不给卡片：HUD 可在本次运行期间、数量相同时，显示最多一小时内的上次明细，并明确标为未验证。账户变更通知或修改连接设置会清空缓存。缺失的到期时间不会被编造。

### Claude 本地观测（默认开启显示，可关闭）

使用[官方 statusline stdin](https://code.claude.com/docs/en/statusline.md) 的 `rate_limits.five_hour` / `seven_day`；通常首次 API 响应后才可能提供。不新增凭据/钥匙串/cookie 读取，不调用 Claude 账户 API，不启动 Claude。原生桥接仅保存百分比与有界整数时间，HUD 每 5 秒读取私有原子快照；手动刷新只是重读。

无已有状态栏者复制最小片段；已有状态栏者向**纯文本生成器**粘贴原 command 的完整 JSON 字符串并明确选择 shell。生成器自动标准解码，输出组合脚本及**仅替换 command 值**的说明，不执行命令、不读/写真实设置。保留 padding、refreshInterval、hideVimModeIndicator 和其他配置；先自行备份，断开时先恢复原 command/配置，再删脚本。见[完整快速指南](docs/quickstart.zh-CN.md)。

这是本地观测，不是账户实时同步。连续 15 分钟数值/Reset 没变化标“旧”，并非服务端更新时间；过 Reset 保留“待同步”证据，不推测成 100% 剩余。读取失败清空数字。仅 used=100 称“观测为已用尽”；少于 1% 剩余显示 `<1%`。CL 和 C W 始终展示 Weekly，5h 耗尽独立提示；没有 Claude 重置卡，也不污染 Codex 告警。

仅一个配置来源，无法证明账号身份；多个 CLAUDE_CONFIG_DIR 会混写，换账号先停旧来源再清除。旧会话可能重播较旧值；其他设备和单独 Fable 周限额不完整覆盖。关闭 Claude 后恢复单标签并停止 HUD 读取，但用户配置的桥接仍可写入。

组合脚本输入收集等待 EOF，无大小/时间上限，不受桥接 main 起 2 秒预算覆盖，shell 变量不能保留 NUL。原命令在所选 shell 独立 -c 上下文运行。合成进程组 SIGTERM 已测试；真实 Claude 取消语义未验证，单独终止 wrapper 不保证终止后代，不承诺总延迟或孤儿进程的绝对保证。真实接入、干净机器、quarantine/Gatekeeper、其他系统均需用户实测。

`./scripts/package.sh` 可在私有临时目录生成**不发布的本地候选包**，含 app、指南、LICENSE、SHA-256 和解压自检，核验 arm64、Mach-O macOS 13 最低版本及纯系统动态依赖。免编译仅指用户无需 Swift/Xcode，仍需手动接入和可能的系统放行。版本仍为 1.1.0，不覆盖现有 Release。

### 本机任务与实验接口

独立启动的 app-server 看不到 Desktop 已加载的任务。因此 V1 默认开启可关闭的 **Desktop 本地 IPC v11** 状态订阅。这是观察到的实验接口，不是稳定公开 API。

SQLite 未结束记录和 writer lock 只用于发现候选任务，最终计数须由实时 `threadRuntimeStatus` 确认。HUD 检查本地 socket 文件所有者及连接对端的用户身份，在内存中保留任务标题和状态。IPC 快照可能附带对话历史并经过内存，但 HUD 不保存这些历史正文。

计数覆盖发现到的、已加载且未结束的**本机主任务**，不含子 Agent、side conversation、远程主机和云端任务。每五秒发现候选任务，每 15 秒验证状态所有者，超过 45 秒未验证则失效。协议或本地索引发生变化时，显示“任务状态未验证”和 `—`，不会假装正常空闲。可在设置中关闭实验接口。

高级共享 app-server Unix socket 模式使用 `thread/loaded/list` 和 `thread/read`，明确传入 `includeTurns: false`。该模式已实现，但本环境没有可用共享服务，尚未做真实端到端验收。

### Token 统计口径

读取所配置 Codex 目录中的 `sessions/` 与 `archived_sessions/`。默认使用 `~/.codex`，也尊重 `CODEX_HOME`。首次扫描后，每 30 秒按文件偏移读取新增记录。

- **Today**：本机时区 00:00 至统计时刻。
- **Week**：官方 Weekly reset 减去窗口时长，至统计时刻；不是自然周。没有有效 Reset 时显示 `—`。
- **总计 = Input + Output**。Cached input 已包含在 Input 中，Reasoning 已包含在 Output 中，不重复相加。
- 累计快照转成增量，排除重复快照和 fork 复制的早期历史，并处理追加半行、文件替换及累计计数重启。
- 这是本机可读记录统计，不是账户账单。其他设备及缺失、删除、尚未落盘的数据不在覆盖内，Token 数也不用于反推账户剩余额度。

## 遇到异常时

| 显示 | 含义及处理 |
| --- | --- |
| `app-server Offline` | 检查 Codex 登录与设置中的 CLI 路径，程序会重试。 |
| `Quota stale` | 读取失败、超过 150 秒未更新或已经跨过 Reset；旧值会带警告显示。 |
| `Weekly 暂不可用` | 账户响应没有受支持的 Weekly 窗口。 |
| `任务状态未验证` | 实时状态不完整、离线或协议不兼容；计数为 `—`，本地未结束记录仅供参考。 |
| `Token 数据不完整` / `Token stale` | 本地读取/格式异常、数值超出支持范围，或超过 90 秒未更新。 |
| 重置卡明细未验证 | 已知数量，但日期缺失、不完整或来自缓存；刷新后等待接口重试。 |

连接设置支持 Codex 数据目录、受信任的本地 CLI 可执行文件、共享 socket 和实验接口开关。显式指定无效 CLI 路径时会报错，不悄悄改用其他程序。

偏好保存在 `~/Library/Application Support/Codex HUD/settings.json`，窗口位置使用 macOS 用户默认设置。不要公开自己的偏好文件、真实诊断输出、sessions 或包含私人任务标题的截图。

## 开发与验证

```sh
# 行为回归检查，不需要账户
./scripts/check.sh

# 读取真实诊断快照，包含个人用量，分享前需自行检查
'../Codex HUD.app/Contents/MacOS/CodexHUD' --diagnose

# 检查真实窗口的层级、位置和渲染，输出到本地目录
'../Codex HUD.app/Contents/MacOS/CodexHUD' --check-window /tmp/codex-hud-window-check

# 使用虚构数据生成文档截图，不连接账户
'../Codex HUD.app/Contents/MacOS/CodexHUD' --demo /tmp/codex-hud-demo
```

诊断最多等待 45 秒，检查的数据源和完整卡片明细可用时返回 0，否则返回 2。输出不含账户 ID、任务标题、消息正文或凭据，但**仍含个人用量和时间信息**。

原生窗口检查不会合成鼠标输入，也不能代替人工交互验收。具体覆盖与缺口见 [VALIDATION.md](VALIDATION.md)，安全审查范围与修复见 [SECURITY_REVIEW.md](SECURITY_REVIEW.md)。

```text
Sources/HUDCore/       只读连接、状态、Token 与偏好
Sources/CodexHUD/      SwiftUI 浮窗、AppKit 窗口/菜单、设置与诊断
Sources/CSQLite/       系统 SQLite 桥接
Tests/HUDCoreTests/    行为检查及临时文件用例
scripts/              构建与检查脚本
```

## 许可证

[MIT](LICENSE)。

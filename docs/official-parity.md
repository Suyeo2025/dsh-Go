# 官方功能对照（DSH 0.2.1-rc.5）

> 版本：按 DSH 0.2.1-rc.5（`dsh --version`）重核，核对于 2026-11-05。上一版（rc.2）逐项核对于 2026-10-24；rc.2 → rc.5 之间官方新增的能力在本版补进各表，App 一侧的状态以 2026-11-05 的 iOS 改进波次（HEAD `9824a42e` 之后的工作树）为准，见文末「iOS 改进波次记录」。
>
> 依据：官方一侧读 `@deepseek-ai/dsh-client-ui-*`、`dsh-client-ui-entry-customization` 等包的 README；App 一侧每条状态都给了代码位置（相对 `app/`、`packages/`）。原生页面和流程的“有”，指代码和测试已就位；没有在真机上跑过的标「待真机」。
>
> 范围：同一份对照同时适用于 Android 和 iOS。iOS 版是纯远程客户端（`isRemoteOnlyPlatform`，`app/lib/platform/platform_caps.dart`），主要连「直连主机」（用户服务器上的官方 `dsh web`，没有 dsh-Go 引擎桥）；表里写 Android 的地方（本机引擎、桌面快捷方式、快速设置磁贴等）iOS 没有。

结论：官方网页端（`dsh-client-ui-*`、`dsh-experimental-client-ui-*`、打包后的 `dsh-web-frontend`）用户能碰到的功能，App 里基本都有入口，而且大多有原生页面或原生流程（Cordis 插件面板的批准运行和插件界面仍在网页版）。按 rc.5 重核后，仍没有的只有这几项：会话列表的「按工作区树」视图与手动拖拽排序、右侧栏的 Split / Fullscreen、「创建你的插件」（创造模式草稿）入口、网页版 `Work details` 四档详细度在 App 自己聊天页的对应；对话详情里的子代理续聊 / 打断已经走官方 `subagents/*`，不算缺口（见 P2-7 一行）。「全部功能」优先原生入口，网页版仅保留独立入口和语音插件设置。汇总页在「全部功能」：抽屉底部身份栏的全部功能键、输入框 `/全部功能`；它只放「现在去做」的功能，设置类入口集中在 设置 里，末尾留一组「设置」快捷卡。设置本身按意图分组（AI、能力、外观、通用、主机、帮助与关于），首页顶部可以搜索（`docs/design/settings-ia.md`）。

状态图例：☑️ 原生已有 · 🔄 原生做了一部分，其余在网页版或没做 · ⬜ 原生没有，入口是网页版深链 · ❌ 原生没有，也没有深链（官方有，App 暂未做；原因和排期见「缺口与后续」） · ➖ 手机上不适用（说明原因） · — App 故意不做。☑️ 指代码和测试已完成，不等于在真机上验证过；标「待真机」的项和还没在真机上验证的项列在文末「缺口与后续」。下表的「App 入口」里，「全部功能 › X」指汇总页里的一行；「网页版 › …」指深链落到的官方页面。

逐包核对的依据是各包的 `README.zh.md` 和 `lib/client.js`（中文文案、slot、remote 名称）；深链在电脑上用 `dsh web` 实测过（临时 HOME，见「深链怎么落地」）。

## 对话与输入

| 官方功能 | 官方包 · 官方入口 | 状态 | App 入口 |
|---|---|---|---|
| 对话视图：过程折叠、轮次导航、每轮用量 | ui-chat · 视图 tab「对话」 | ☑️ | 聊天页；设置 › 外观 › 完成后收起过程 |
| `Work details` 详细度（`ui-chat.transcriptView`：精简 / 标准 / 详细 / 完整，rc.5 设置里在 Work details 一行）与折叠时机（`collapseTiming`） | ui-chat · 设置 › 通用设置 | 🔄 | App 聊天页自己只有「完成后收起过程」一个开关（`ui/chat/turn_summary.dart`），不读这两个值；网页版这两个值可在 设置 › 界面 › 网页版显示 里改（`ui/engine_settings/general_settings_page.dart`、`namespace_copy.dart:136-150`），只影响网页版。App 聊天页的四档详细度暂未做，待设计 |
| 输入框、排队发送、插话 | ui-conversation · 输入框、queue dock | ☑️ | 聊天页；长按发送键选「排队 / 插话」 |
| 生成中发送的默认行为（`Send behavior while busy`，`ui-conversation.busyEnter`：`queue` / `steer`，官方默认 `queue`） | ui-conversation · 设置 › 通用设置 | ☑️ | 默认「跟随主机」：读主机的 `busyEnter`，主机没有这个值时保持插话（`state/busy_send_state.dart`，`state/chat_state.dart` 里 `busySendDefaultProvider`）；设置 › 界面 › 生成中发送 可改成「总是插话 / 总是排队」（`ui/settings/busy_send_tile.dart`）。网页版那一份仍在 设置 › 界面 › 网页版发送 里改 |
| 待办（Todo）条 | ui-conversation · `input.dock#todo` | ☑️ | 聊天页输入框上方常驻待办条（「3/7 · 正在：…」，点开原地展开清单）；对话详情 › 进度 |
| 上下文占用 | ui-conversation · 上下文圆环 | ☑️ | 输入条里的上下文小环（点开看用量）；对话详情 › 上下文 |
| 斜杠命令面板 | ui-commands · 输入 `/` | ☑️ | 输入 `/` |
| `/压缩` `/权限` `/计划` `/目标` `/反馈` | dsh-command-* · 斜杠命令 | ☑️ | 输入 `/`（执行走 `commands/execute`） |
| 下载会话日志（`/export`、会话顶栏「下载 Session 日志」） | session-log-export | ☑️ | 输入框 `/export`；全部功能 › 导出对话日志 |
| `/模型`：模型与推理等级 | ui-model-selection · 输入框模型位、`/model` | ☑️ | 聊天顶栏模型胶囊；`/模型` |
| `/文件`：添加附件 | ui-conversation · `+` | ☑️ | 输入框附件按钮 |
| 技能组（`/技能名`） | ui-skill · `/` 菜单「技能」组 | ☑️ | 输入 `/`（本次新增技能组）；全部功能 › 技能。技能弹层：在对话里用 / 新对话里用（往输入框插入 `/name `，与官方 `dsh-client-ui-skill` 的 onPick 一致） |
| 引用文件 / 对话 / 子代理（`@`） | ui-reference、ui-subagent · 输入 `@` | ☑️ | 输入框输入 `@`（文件、对话、子代理，`fileReferences/list`、`sessionReferenceResolver/candidates`）；全部功能 › 引用文件和对话（回到输入框） |
| 附件栏、图片画廊与灯箱 | ui-attachment | ☑️ | 输入框附件、消息图片 |
| 凭据遮挡（已发送文本里的 Key） | ui-secret-mask | ☑️ | 聊天气泡（点眼睛显示原文） |
| 权限审批卡 | ui-approval · 接管输入框 | ☑️ | 聊天里的审批卡 |
| 提问卡、计划待审（同意执行 / 要求修改） | ui-user-questions | ☑️ | 聊天里的提问卡（计划正文用 Markdown 展示） |
| 消息反馈（好 / 有问题）与反馈弹窗 | ui-message-feedback · 消息操作条、`/feedback` | — | App 不做：操作条上的 👍 / 👎 已去掉（2026-10-27，换成「分享」）；`/反馈` 照旧 |
| 从某条消息分叉 | ui-chat · `session/fork` | ☑️ | 长按消息或回复操作条 ⋯ › 从这里分叉 |
| 工具卡片、工作流运行节点、Cordis 卡片 | ui-tool、ui-workflow-run、ui-cordis | ☑️ | 聊天里的工具行 |
| 思考过程机器翻译 | experimental-ui-cot-translation · 展开思考后的工具栏 | ☑️ | 展开思考 › 「翻译」（插件开启后出现）；全部功能 › 思考过程翻译（插件开关与设置） |
| 语音输入 | experimental-ui-voice-input · 输入框麦克风 | ☑️ | 输入框的麦克风（空输入时在发送键位置，待真机验证）；全部功能 › 语音输入（回到输入框；🌐 网页版的引擎语音插件仍可用） |
| 输入框上方的思考胶囊 | —（App 自有） | ☑️ | 聊天页输入框上方 |

## 当前对话

| 官方功能 | 官方包 · 官方入口 | 状态 | App 入口 |
|---|---|---|---|
| 轨迹（事件表、时间概览） | ui-trajectory · 视图 tab「轨迹」 | ☑️ | 点顶栏标题 › 对话详情 › 轨迹；全部功能 › 对话详情 |
| 改动 / 交付物卡片 | ui-deliverables | ☑️ | 聊天里的改动卡与产物文件卡（预览、打开、分享、存到「下载」；分享打开分享面板：图片或文件本身）；对话详情 › 改动；全部功能 › 产出的文件 |
| 改动 review：左右对比 / 统一视图、换行、文件切换（rc.5 的 `changes-review` 标签） | ui-deliverables · 改动卡 › review tab | ☑️ | 改动页（`ui/chat/diff_page.dart`）：≥ 中等宽度（`WindowClass.mediumMin`，iPad、折叠屏）时顶栏出现「左右对比 / 统一视图」切换（`diff-split-toggle`），≥ 展开宽度默认左右对比，选择在本次运行内记住（`_splitPreference`）；窗口宽度不到 600dp（手机竖屏）时只有统一视图。左右对比由 `FileDiffPane(split: true)` 画，左边旧文件行号、右边新文件行号。官方「只增 / 只删时单栏」「在侧栏打开整份文件」「在本地应用打开」App 没有对应（待真机看 iPad 实际观感） |
| 行内代码文件链接（收尾正文里的 `` `path` `` 能精确解析到本轮产出文件时可点） | ui-deliverables · 行内代码链接 | ☑️ | 回复正文里的行内代码：完整路径，或在本会话产物里唯一的文件名，点开文件预览；不唯一的保持普通代码（`state/artifact_links.dart`，`ui/chat/render/markdown_body.dart` 的 `InlineCodeLinkScope`）。只在回复收尾（非流式）后生效。Markdown 链接 `[x](path)` 本来就能点（`markdown_body.dart`） |
| 后台任务（进行中 / 已结束、实时输出、停止） | ui-jobs · 会话顶栏「N 个后台任务」 | ☑️ | 全部功能 › 后台任务（本次新增，`job/list`、`job/follow`、`job/kill`） |
| 子代理目录与谱系 | ui-subagent · 会话顶栏「N 个子智能体」 | ☑️ | 聊天顶栏「N 个子智能体」胶囊；对话详情 › 子代理（谱系树，点开接着聊；一次性子代理只读）；聊天里点「子代理 · …」工具行打开那个子代理；全部功能 › 子代理。续聊 / 打断的走法见文末「子代理续聊 / 打断核实」 |
| 计划模式（徽章、计划卡片、右栏计划预览） | ui-plan | ☑️ | `/计划`；对话详情 › 进度 |
| 长期目标（目标条：编辑、暂停、恢复、清除） | ui-goal · 输入框上方目标条 | ☑️ | 聊天页输入框上方目标条，点开可编辑、暂停 / 恢复、清除（`goals/*`）；对话详情 › 进度 |
| 当前对话的权限预设 | ui-permission-presets · `/permission` 弹窗 | ☑️ | 设置 › 权限 › 当前对话；全部功能 › 设置 › 权限；`/权限` |
| 工作区文件树与文档预览 | ui-sidebar-files、ui-sidebar-documentpreview · 右侧栏 | ☑️ | 全部功能 › 文件；对话详情 › 文件（浏览、搜索、文本 / 图片 / PDF / 表格预览，Office 由主机转 PDF 预览；长按打开、分享、保存） |
| 终端 | ui-sidebar-terminal · 右侧栏「新建终端」 | ☑️ | 对话详情右上角的终端键；全部功能 › 终端（多标签、快捷键行；离开页面终端继续跑） |
| 右侧栏（push 形态、顶栏角上的展开键） | dsh-client-ui-sidebar-right · 会话顶栏角 | ☑️ | `SessionDetailPage` 的面板模式 + `DetailPanelKey`：宽屏对话详情常驻右栏；窄屏改用底部面板 |
| 右侧栏的 New tab / Split / Fullscreen（多标签、分屏、全屏两种呈现，`ctx.layout.openRightbar(track, fullscreen)`） | dsh-client-ui-sidebar-right、dockkit | 🔄 | App 的对话详情是固定的几页（文件、改动、终端、进度……），不是可分屏的标签树：没有 Split；窄屏的底部面板和宽屏的右栏分别对应官方的 fullscreen 和 normal 两种呈现，但不能手动切换；没有插件 tab（better-sidebar 等只能靠 islands，见下）。不做 dockkit 式的分屏，这是有意的取舍（手机 / 平板上用页面切换代替） |
| 浏览器侧栏 | ui-sidebar-browser | ➖ | 官方 Web 版默认就不启用（只有桌面版有），App 内网页版也没有 |
| 在本地应用打开 | ui-open-in-app · 会话顶栏「在本地打开」 | ➖ | 需要运行 Host 的机器有桌面；手机本机没有。远程主机可在其网页版里用 |
| 智能体团队（成员、任务板） | experimental-ui-agent-team | ☑️ | 聊天顶栏的团队胶囊；全部功能 › 智能体团队（成员、任务板与消息；插件未开启时页内可开启） |
| 会话重命名、归档 | ui-workspace | ☑️ | 抽屉里长按对话（置顶、重命名、移到文件夹、分享、复制会话 ID、多选、归档）；多选后批量归档（可撤销） |
| 停止并归档（有运行中工作的会话：Host 拒绝普通归档，客户端列出运行中的轮次 / 子代理 / 后台任务 / 提醒，确认后停止并归档） | ui-workspace · 会话行 › Archive | 🔄 | App 归档一律带 `stopActivity: true`（`state/sessions_state.dart` 的批量归档与单条归档调用 `archiveSession(id, stopActivity: true)`，`packages/dsh_client/lib/src/session_api.dart:351`），归档后有撤销；没有官方那种“逐项列出运行中工作再确认”的对话框 |
| 复制会话 ID | ui-workspace · 会话行菜单最后一项 | ☑️ | 抽屉里长按对话 › 复制会话 ID（`ui/shell/sessions_drawer.dart` 的 `copy-id`，只写剪贴板，不连主机） |
| 归档视图：隐藏 / 全部 / 仅归档，取消归档 | ui-workspace · View options › Archived | ☑️ | 抽屉 ⋯ › 已归档（`ui/shell/drawer/drawer_actions.dart:44` → `showSessionSearch(archivedOnly: true)`，标题「已归档的对话」，空时「还没有归档过的对话」）；搜索里勾「含已归档」也能找回并取消归档 |
| 会话搜索 | ui-sidebar · 搜索 | ☑️ | 抽屉顶部搜索框；全部功能 › 搜索对话 |
| 待处理交互标记（等待审批 / 计划待审 / 等待回答） | ui-workspace · 待处理交互 | ☑️ | 抽屉对话行尾「待确认 / 计划待审 / 待回答」；筛选「待确认」 |
| 未读完成提醒 | ui-workspace · 会话行状态点 | ☑️ | 抽屉对话行尾小圆点；筛选「未读」 |
| 排序：最近更新 / 手动拖拽 | ui-workspace · 视图选项 | 🔄 | 抽屉 ⋯ › 排序：最近活动 / 创建时间；对话不能手动拖拽排序（文件夹可以）。官方的手动排序靠 `workspace/insertSessionBefore`，App 没有调用，和现有「文件夹 + 置顶 + 日期」模型冲突，需先设计（延后） |
| 分组：按工作区 / **按工作区树**（rc.5 新增，工作区按最近的已注册祖先嵌套）/ 单列表 | ui-workspace · View options › Group by | ❌ | 抽屉只有「按工作区」（工作区切换）加 App 自有的文件夹，没有工作区树；手机抽屉里价值一般，延后 |

## 自动化

| 官方功能 | 官方包 · 官方入口 | 状态 | App 入口 |
|---|---|---|---|
| 自动化任务页：全部 / 已开启 / 已结束、规则、运行记录、关联会话、删除 | ui-schedule · 侧栏面板「自动化任务」 | ☑️ | 全部功能 › 自动化任务（列表、搜索、筛选、详情、运行记录、改名、改指令、删除、跳到关联对话） |
| 编辑运行时间（重复规则、时区、cron） | ui-schedule · 详情「运行时间」卡片 | ☑️ | 自动化任务 › 详情 › 运行时间（重复规则、时区、cron） |
| 新建任务 | 官方也没有表单，由模型 `schedule_create` 建 | ☑️ | 自动化任务 › 新建（填好名称、指令、运行时间后交给对话里的模型去建，和官方同一条路） |
| 会话顶栏的提醒时钟 | ui-schedule · 会话顶栏 | ☑️ | 对话顶栏标题胶囊尾端的时钟键（有进行中的自动化任务时出现，只有图标，空间不够时让位）；点开看名称、规则、接下来三次运行，可「立即运行」或进「管理」。官方没有暂停 / 恢复，App 也不提供 |

## Agent 与模型

| 官方功能 | 官方包 · 官方入口 | 状态 | App 入口 |
|---|---|---|---|
| 新对话默认权限 | ui-permission-presets · 设置 › 通用设置 | ☑️ | 设置 › 权限 › 新对话默认（`settings/mutate permission`）；本机上选「完全权限」就是 App 自己的开关（原「自动执行命令」）；全部功能 › 设置 › 权限 |
| Agent 预设：选择新对话默认、查看配置 | ui-agent-preset · 设置 › Agent 预设、新会话页 | ☑️ | 设置 › 个性化 › Agent 预设（列表、设为默认、查看 YAML） |
| 新对话选预设（新会话 hero 的预设标签，`session/create` 带 `agentPreset`） | ui-agent-preset · `conversation.hero.agentPreset` | ☑️ | 新对话空状态里的预设胶囊（主机列出 ≥ 2 个预设时才出现，选择一次性、换主机清空）：`ui/chat/empty_state.dart` 的 `_PresetChip`、`state/new_chat_preset_state.dart`，经 `createSessionInWorkspace(agentPreset:)`（`state/workspaces_state.dart:488-501`）传给 `session/create` |
| 创造模式入口：「浏览更多插件」「创建你的插件」（三个“更多”菜单；创建 = 用 `cordis` 预设开新会话并把请求放进**草稿**，不发送） | dsh-client-ui-entry-customization · 侧栏更多 / 会话视图更多 / 右栏更多 | 🔄 | 「浏览更多插件」对应 设置 › 插件 › 插件市场 ☑️。「创建你的插件」没有对应入口：App 只有 Agent 预设编辑器会用创造模式（`startCreator`，`state/preset_editor_state.dart:32`，用 `cordis` 预设开新会话并**直接发送**请求，`ui/features/preset_editor/preset_editor_page.dart:189`）。要做的话是在 全部功能 / 插件页加一个入口，用草稿而不是直接发送，待设计 |
| Agent 预设：新建、编辑 | ui-agent-preset | ☑️ | Agent 预设 › 新建 / 复制 / 编辑（原生表单，经 Cordis 插件写入） |
| 账号与余额 | ui-settings-account · 设置 › 账号与余额 | ☑️ | 设置 › 顶部卡片 › 账号 |
| 模型服务商与密钥 | ui-settings-models · 设置 › 模型 | ☑️ | 设置 › 模型（DeepSeek 账号 / API Key、ChatGPT 与 Claude 订阅登录、自定义渠道；订阅建的渠道只读）；全部功能 › 设置 › 模型 |
| 远程主机上填 / 清除 DeepSeek API Key（`credentials/set` / `credentials/unset`） | ui-settings-models · 设置 › 模型 › DeepSeek | ☑️ | 设置 › 模型，连着远程主机时点 DeepSeek 一行（主机允许写入时）：`ui/providers/remote_deepseek_key_sheet.dart`、`providers_page.dart:162`。Key 只进输入框并发给主机，App 不记录、不再显示；之前远程分支只显示状态点 |
| 子智能体设置（递归层数、并行、可选模型） | ui-settings-subagent · 插件 › 子智能体 | ☑️ | 设置 › 引擎参数 › 子代理 |
| Agent 循环（并行工具调用上限） | ui-settings-agent-loop · 插件 › Agent 循环 | ☑️ | 设置 › 引擎参数 › Agent 循环 |
| 命令执行（超时、输出上限） | ui-settings-shell · 插件 › 终端 | ☑️ | 设置 › 引擎参数 › 命令执行 |
| 联网搜索（Key、端点、预算） | ui-settings-web-search · 插件 › 网页搜索 | ☑️ | 设置 › 联网搜索 |

## 插件

| 官方功能 | 官方包 · 官方入口 | 状态 | App 入口 |
|---|---|---|---|
| 插件管理：安装、启用、停用、移除 | ui-plugin-manager · 侧栏面板「插件」 | ☑️ | 设置 › 插件；全部功能 › 插件；插件详情右上角可分享（链接 / 二维码，或图片卡片） |
| 插件市场 | ui-plugin-market · 插件 › 发现 | ☑️ | 插件 › 插件市场 |
| 实验性插件开关（团队、语音、翻译、工作树…） | ui-plugin-manager · 插件 › 实验性插件 | ☑️ | 插件 › 已安装（官方可选插件只有开关） |
| 插件自己的配置页 | ui-plugin-manager · 插件详情 | ☑️ | 插件详情 › 设置（按插件声明的表单原生渲染）；设置 › 引擎参数 › 插件 |
| 插件清单（加载器全部行，只读） | ui-settings-plugin-inventory · 设置 › 内置插件 | ☑️ | 设置 › 引擎参数 › 插件清单 |
| Cordis 插件面板（插件在运行中创建的动态插件） | ui-cordis · 侧栏左下角 | 🔄 | 全部功能 › Cordis（列表、状态、停止、移除）；批准运行和插件界面在网页版（Cordis 页 › 在网页版打开） |

## 工作区、设置与外观

| 官方功能 | 官方包 · 官方入口 | 状态 | App 入口 |
|---|---|---|---|
| 工作区：添加、切换、分组、置顶 | ui-workspace、ui-directory-picker-browse · 侧栏 | ☑️ | 抽屉里对话列表上方的工作区切换；全部功能 › 工作区（添加、改名、分组、置顶、移除）；新对话空状态显示要建在哪个工作区 |
| 目录选择（应用内浏览 / 系统选择框） | ui-directory-picker-* | ☑️ | 添加工作区时的原生目录浏览（主机文件系统；本机另有「手机存储」「下载」等快捷入口） |
| 通用设置：语言、显示代码工作视图、链接打开方式、性能与用量、Enter 发送 | ui-settings-general、ui-chat、ui-conversation | ☑️ | 设置 › 界面 › 网页版显示 / 网页版发送（引擎侧的这些开关；App 自己的显示设置在 设置 › 外观） |
| 会话日志上传（官方 API） | ui-settings-session-log · 通用设置 | ☑️ | 设置 › 隐私与分享 › 向 DeepSeek 上传对话日志（原生开关） |
| 外观、字号 | ui-theme · 通用设置 | ☑️ | 设置 › 外观（App 自己的主题与字号；网页版仍用自己的设置） |
| 三栏布局（AppFrame） | dsh-client-ui-layout · 三栏 AppFrame | ☑️ | `AdaptiveScaffold`：≥840dp 三栏，左侧放不下时收成导轨；侧栏和面板都要而聊天栏会窄于阅读宽度（720 + 边距）时，后展开的一侧保留、另一侧收起（`ui/shell/adaptive/adaptive_layout.dart` 的 `LayoutSide`、`state/adaptive_layout_state.dart` 的 `prefer`；13 寸 iPad 横屏的三栏取舍）。表单底部按钮条限宽到 720（`ui/remote/ssh_host_form.dart` 的 `RemoteFormBar`、`ui/providers/provider_widgets.dart` 的 `FormBottomBar`）。待真机看 iPad |
| 快捷键（命令速查、按设备自定义键位） | ui-shortcuts、client-shortcuts | 🔄 | 外接硬件键盘（iPad、带键盘的 Android 平板）有一组固定快捷键：⌘N 新对话、⌘K 搜索、⌘⇧[ / ⌘⇧] 上一条 / 下一条对话、⌘. 停止、⌘, 设置、⌘ + 反斜杠键折叠列表、⌘⇧D 折叠详情、⌘/ 速查表（`ui/shell/shortcuts.dart`、`shortcuts_sheet.dart`，非苹果平台用 Ctrl）。键位不能自定义；网页版通用设置里仍可编辑它自己的。手机没有硬件键盘时不适用。待真机 |
| 新手引导、预览版说明 | ui-settings-general、ui-settings-models | ☑️ | App 自己的引导页 |
| 网页版整体 | dsh-web-frontend | ☑️ | 抽屉品牌行的切换键；全部功能 › 网页版；设置 › 界面 › 打开网页版。两处入口都按当前主机打开（`ui/web/dsh_web_launcher.dart` 的 `dshWebPage` / `openDshWeb`）：本机引擎仍是 `LocalWebScreen`，直连 / SSH 主机打开它自己的网页，没有可用网页时提示原因、不再显示「引擎没有运行」（`ui/settings/interface_page.dart`、`ui/shell/home_shell.dart` 的 `DrawerDestination.web`）。Android 上当前主机是远程主机时，同样改为打开该主机的网页。WKWebView 实际加载待真机 |
| 第三方插件的网页界面（dsh-context 的 Context 视图、better-sidebar 的右栏、meow-memory 设置页等，用户实例上在用） | 各第三方包的 slot（`sidebar.panellist`、`conversation.view`、`sidebar.right.pane.tab`……） | 🔄 | App 用 islands（把官方页的某个 slot 嵌进原生页）显示：直连主机已放开（`ui/plugins/islands/island_gate.dart:50`），其余显示「在网页版打开」。iOS 有了 Swift 的 `dsh/islands`（`ios/Runner/IslandsChannel.swift`，只实现 `device`），WKWebView 最多 2 个岛（`island_budget.dart` 的 `maxWkWebViewIslands`）；隐藏中的岛在 iOS 用 1/255 透明度保证合成（`island_view.dart` 的 `islandHiddenOpacity`）。模拟器连直连主机实测：插件市场（`plugins.bundle.config`）岛化正常，meow-memory / dsh-context 走原生表单，dsh-im、better-sidebar 没有 config 座位、回落到网页版。直连主机没有 bridge，Context / Fleet 视图、better-sidebar 的 Files/Git/Tasks 没有座位，只能进网页版首页。真机内存档位待验证 |

## App 自有（官方网页版没有）

| 功能 | App 入口 |
|---|---|
| 分享（链接、图片、文件、文字；回复、选中消息、整段对话、产物文件、插件卡片） | 回复下方「分享」、长按回复 / ⋯ › 分享；抽屉里长按对话 › 分享；产物文件菜单 › 分享；插件详情 › 分享 › 图片 |
| 分享码（插件、整套配置，链接 / 二维码 / `.dshgo` 文件） | 插件详情 › 分享 › 分享链接；设置 › 隐私与分享 › 分享配置；全部功能 › 分享配置；打开 `dshgo://` 链接或分享来的文件自动导入 |
| 社区（论坛、插件精选、提示词、交流群、动态） | 设置 › 帮助与关于 › 社区；全部功能 › 社区；全部功能 › 论坛 |
| DS Bot（Bot 团队、群聊、记忆、通知） | 抽屉列表顶部「DS Bot」（Bot 的对话都收在这一行，带未读数）；全部功能 › DS Bot；Bot 通知点开直达对应 Bot 或群聊 |
| 订阅登录失效提示 | 对话里「ChatGPT / Claude 登录已失效」那一行的「重新登录」 |
| 重新回答（在新对话中重新生成，原对话不变） | 最后一条回复操作条 ↻；长按回复 / ⋯ › 重新回答 |
| 引用追问（引文放在输入框上方，以引用块发出） | 长按回复 / ⋯ › 引用；选择文字里选中一段 › 引用 |
| 图片保存到相册 | 长按消息里的图片 › 保存到相册；图片查看页右上角 |
| 系统集成（分享进来、桌面快捷方式、快速设置磁贴）——Android | 其他 App › 分享 › DSH（文字 / 图片 / 文件进新对话，单个 .dshgo 或分享链接走导入）；长按桌面图标 › 新对话 / 语音输入 / 最近 3 个对话；下拉快速设置 › 新对话；用 DSH 打开的其他文件进新对话 |
| 系统集成——iOS | `dshgo://` 链接：`ios/Runner/LinksChannel.swift`（由 `SceneDelegate.swift` 喂入）接到 Dart 的 `dsh/links`，热启动落地已在模拟器验证，冷启动待真机（模拟器停在系统「在“DSH Go”中打开？」确认框）。分享扩展 `ios/ShareExtension`（照片 / 链接 / 文件 → App Group 收件箱 → `ios/Runner/ShareChannel.swift` → 新对话草稿）：收件箱到草稿一段已在模拟器验证，在相册里点「分享 › DSH Go」待真机；TestFlight 发版前要先在开发者门户配置 App Group 和扩展的描述文件（见 `tooling/ios/README.md`）。推送已上线（`app/lib/push`、`ios/Runner/PushChannel.swift`，服务器侧 dsh-watch bridge），语音输入已上线（服务器语音模型 ready，待真机） |
| 回前台 / 换网后的连接恢复 | 直连主机：回前台离开 ≥ 20 s 立即重连并显示「重新连接中」，< 20 s 或换网先探活一次，探到连不上再重连（`remote/direct/direct_link.dart` 的 `resumeReconnectAfter`、`probeTimeout`，`remote/network_watch.dart` 的 `appSuspension`）；SSH（`remote/ssh/ssh_link.dart`）、中转（`remote/relay/relay_backend.dart`）原本就有探活。待真机（iOS 挂起后的实际表现） |
| 宠物不挡正文 | 聊天列表离开底部时宠物淡出、窄胶囊（权限胶囊等）不当站台（`pets/pet_signals.dart` 的 `petContentBehindProvider`，`ui/pets/pet_stage.dart`；规则见 `docs/design/pets.md`）。待真机（iPhone 与 iPad 竖屏） |

## 深链怎么落地

官方网页端没有路由：没有 hash、query 或 pathname，`ctx` 也没挂在 `window` 上。所以 App 不拼 URL，靠注入脚本 `app/assets/web/dsh_web_open.js` 落到页面。`WebViewPage` 每次加载都注入这个脚本，首次加载后调用一次 `window.__dshAppOpen(target)`。target 的结构见 `app/lib/ui/web/web_target.dart`，脚本按 target 做的事如下：

- **会话**：写入官方启动时会恢复的选中会话 `localStorage['dsh.sessions.current'] = {"sessionId": …}`，然后刷新一次。刷新后脚本从 `sessionStorage` 读回剩余的 target 接着执行。
- **全局面板**（插件 / 自动化任务）：点侧栏 `button[aria-label="插件" | "自动化任务"]`。
- **设置分区**：点账号菜单 › 设置，再点对应导航项（通用设置 / 模型 / 内置插件 / Agent 预设）。如果侧栏有独立的「设置」按钮，就直接点它。
- **插件卡片**：打开插件面板。停在某个插件详情（或它某个组件的页）时先按顶部的返回一级一级回到列表（最多三下，每下等页面画好），再点卡片：先按官方标在卡片上的包名 / 条目 id（`data-plugin-package` / `data-plugin-item`）找，找不到再按 `查看 <名称>`。实验性插件折叠在「更多」后面时先展开。空名称不参与匹配（它会匹配上任意图标按钮，比如卡片的启用开关）。
- **不赖着不走**：只有最新一次打开在动（新的打开让旧的停下）；页面加载完之后整次最多找 15 秒；用户在页面里一碰屏幕或打字就停手。停下的不再点任何东西、也不报结果；超时或没找到的报对应步骤，页面停在已经走到的地方（找不到卡片就停在插件页）。
- **右侧栏**：点会话顶栏「打开右侧边栏」，再点开始页的「工作区文件」或「新建终端」。右栏已经开着时点「新标签页」。
- **侧栏**：手机布局下用 `__dshApp.toggleSidebar()`，否则点「打开侧边栏」。

控件只按无障碍名称匹配（中英两套文案），不依赖哈希类名；脚本只做点击和写官方自己的存储，不改样式，也不增删官方节点。没落地时，脚本通过 `DshAppOpen` JS channel 回报失败的步骤，App 弹一句中文提示，页面停在首页。

远程主机：SSH 主机通过 App 的本地转发 `http://127.0.0.1:<转发端口>/?token=…` 打开远端的网页版。DSH 的浏览器防护接受任何 loopback Host，这一点已读源码 `dsh-client-connection` 的 `isTrustedApiRequest` 核实，但没有在真实 SSH 主机上跑过。经 DSH Remote 中转的主机没有 HTTP 通道，网页版入口会提示去那台电脑上打开。

（以下实测是 rc.2 时做的，没有按 rc.5 的页面重做：rc.5 的侧栏「更多」菜单、会话视图的 More 菜单都是新增的，注入脚本按无障碍名称匹配，理论上不受影响，待复测。）

实测：在电脑上用 runtime 里的 DSH 0.2.1-rc.2 起 `dsh web`，HOME 指向临时目录，在浏览器里注入同一个脚本。下面这些目标都落对了：插件、自动化任务、设置 › 模型 / Agent 预设 / 内置插件 / 通用设置、插件卡片（子智能体、Agent 循环、终端、智能体团队、语音输入、思考过程机器翻译）、换会话后打开终端 / 文件、侧栏。手机宽度（375px）加上注入的手机布局后，又测了一遍设置、面板、插件卡片、侧栏和终端。「账号与余额」只在登录官方账号后出现；没登录时脚本会回报失败，所以汇总页的账号入口用原生页面。

## 更新记录

- 2026-10-24：终端、工作区文件与文档预览、工作区与目录选择、子代理谱系与续聊、智能体团队、思考过程翻译、`@` 引用、语音输入、引擎设置（子代理 / Agent 循环 / 命令执行 / 联网搜索 / 通用设置 / 日志上传）、插件配置页与插件清单、自动化任务编辑、Agent 预设编辑全部做成原生，对应行改为 ☑️；全部功能里只剩「网页版」本身是网页入口。新增「App 自有」一节。
- 2026-10-24（第二批）：待办条、目标条、顶栏提醒时钟做成原生，改为 ☑️；Cordis 有了原生列表页，改为 🔄；抽屉加上文件夹、筛选、待确认 / 未读标记、多选与排序；宽屏三栏与右栏；「App 自有」加上重新回答、引用追问、相册保存、系统集成。
- 2026-11-05：按 DSH 0.2.1-rc.5 重核。官方 rc.2 → rc.5 的新增项补进各表（停止并归档、工作区树、行内代码文件链接、改动 review 左右对比、右栏 Split / Fullscreen、创造模式入口、`Work details`、复制会话 ID、新会话选预设）；App 一侧补上 iOS 改进波次第一波的结果（见下一节）；新增「子代理续聊 / 打断核实」；「缺口与后续」同步了本轮延后清单。

## iOS 改进波次记录（2026-11-05）

本轮一共 10 个模块，分两波。第一波 7 个模块的代码已在工作树里（下表的依据是现在的代码；**都还没有在 iOS 真机上跑过**，模拟器 / 单元测试之外的现象标「待真机」）。第二波的 settings-ios、ios-native 已收口，下表和上面「网页版整体」「第三方插件的网页界面」「系统集成——iOS」三行已按落地后的代码复核。

| 模块 | 结果 | 依据 |
|---|---|---|
| link-resume | 直连回前台不再等 15 s 的 mux ping：离开前台 ≥ 20 s 立即换 socket 重连并显示「重新连接中」；更短的切换或换网先 5 s 健康探活，探到连不上才重连、未授权则重新登录。Android 直连主机行为同样改变（同一缺陷的修复，不做平台门控）。待真机 | `remote/direct/direct_link.dart`（`resumeReconnectAfter`、`probeTimeout`、`_refresh`、`_probe`）、`remote/network_watch.dart`（`appSuspension`）、`state/connection_state.dart:241`；测试 `test/remote/direct_resume_probe_test.dart`、`network_watch_resume_test.dart` |
| busy-send | 生成中发送默认跟随主机 `ui-conversation.busyEnter`；主机没有值时仍是插话；App 另有覆盖选项「跟随主机 / 总是插话 / 总是排队」。**行为变化**：有该值的主机（含 Android 本机引擎）原来默认插话，现在官方默认 `queue` 时变成排队（用户已拍板） | `state/busy_send_state.dart`、`state/chat_state.dart`（`busySendDefaultProvider`）、`ui/settings/busy_send_tile.dart`、`ui/settings/interface_page.dart:105`、`ui/settings/index/spots.dart` 的 `Spots.busySend`；测试 `test/chat/busy_send_test.dart`、`test/settings/busy_send_tile_test.dart` |
| pet-clearance | 往上翻看时宠物淡出；窄胶囊（权限胶囊等）作避让区、宠物站下一层。待真机；会动 `test/pets/goldens` | `pets/pet_signals.dart`、`ui/pets/pet_stage.dart`、`ui/chat/chat_list.dart`、`docs/design/pets.md`；测试 `test/pets/pet_clearance_test.dart` |
| drawer-fixes | 筛选胶囊的数字与列表同用 `drawerFilterMatches`（修「待确认 1」却没有待确认对话）；会话行菜单加「复制会话 ID」；「仅归档」页有自己的标题和空状态 | `state/drawer_view_state.dart`（`drawerFilterMatches`、`drawerFilterCounts`）、`ui/shell/drawer/drawer_filter_bar.dart`、`ui/shell/sessions_drawer.dart`、`ui/shell/session_search_page.dart`；测试 `test/drawer/drawer_filter_counts_test.dart`、`session_copy_id_test.dart` |
| ipad | 三栏放不下时后展开的一侧保留；表单底部按钮条限宽 720；硬件键盘快捷键；改动页左右对比。`LayoutPrefs` 的行为变化同样适用于 Android 平板 / 折叠屏（首次打开时两侧都要而放不下，面板会先收起）。待真机 | `ui/shell/adaptive/adaptive_layout.dart`、`state/adaptive_layout_state.dart`、`ui/remote/ssh_host_form.dart`、`ui/providers/provider_widgets.dart`、`ui/shell/shortcuts.dart`、`shortcuts_sheet.dart`、`ui/chat/diff_page.dart`；测试 `test/shell/adaptive/layout_precedence_test.dart`、`form_bars_width_test.dart`、`shortcuts_test.dart`、`test/chat/diff_split_test.dart` |
| host-parity | 新对话空状态可选 Agent 预设；远程主机可在 设置 › 模型 里填 / 清除 DeepSeek Key | `ui/chat/empty_state.dart`（`_PresetChip`）、`state/new_chat_preset_state.dart`、`state/workspaces_state.dart:488-501`、`ui/providers/remote_deepseek_key_sheet.dart`、`providers_page.dart:162`；测试 `test/chat/preset_picker_test.dart`、`test/providers/remote_deepseek_key_test.dart` |
| inline-code-links | 回复收尾后，正文里的 `` `path` `` 能精确对上本会话产物（完整路径或唯一文件名）时可点开预览 | `state/artifact_links.dart`、`ui/chat/render/markdown_body.dart`（`InlineCodeLinkScope`）；测试 `test/chat/inline_code_links_test.dart` |
| settings-ios | 网页版入口按当前主机打开（`dshWebPage`）；账号页只在有本机引擎的构建里（iOS 搜索、`dshgo://open/account` 都去掉，首页总览卡在 iOS 不再锚定账号）；字体行移到设置首页「外观」组（Android 同样移动）；「联网搜索」「图像与视频」行在主机缺对应能力时标「主机未提供 / 未安装」（不分平台）；iOS 快捷面板默认 远程主机 / 插件 / 全部功能 / 设置，Android 不变 | `ui/web/dsh_web_launcher.dart`、`state/quick_panel_state.dart`、`ui/settings/index/spots.dart`（`androidOnlyPages`、`Spots.font`）、`ui/settings/settings_screen.dart`；测试 `test/platform/ios_settings_gating_test.dart`、`test/settings/hub_font_row_test.dart` |
| ios-native | Swift 侧 `dsh/links`（热启动模拟器已验证，冷启动待真机）、`dsh/islands`（`device`）与 iOS 岛的透明度修复、分享扩展（`ios/ShareExtension`，App Group `group.com.colex.dshgo`）。可选的 App Intent「问 DSH」没做。分享扩展要 App Group 能力：TestFlight 发版前需用户在开发者门户注册 App Group、扩展 App ID 并生成描述文件，`tooling/ios/tf-release.sh` 缺描述文件时会先报错；本轮只做到无签名编译（release，Xcode 27）和模拟器验证 | `ios/Runner/LinksChannel.swift`、`ShareChannel.swift`、`IslandsChannel.swift`、`SceneDelegate.swift`、`ios/ShareExtension/`、`ui/plugins/islands/island_platform.dart`、`island_budget.dart`、`island_view.dart`；测试 `test/plugins/islands/island_ios_platform_test.dart`、`integration_test/ios_islands_test.dart`，脚本 `tooling/ios/sim-islands.sh`、`sim-smoke.sh --links` |
| parity-docs | 本文 | — |

## 子代理续聊 / 打断核实（P2-7）

官方的父级续聊 / 打断接口是 `subagents/prompt` 和 `subagents/interruptByParent`（`packages/dsh_client/lib/src/agents_api.dart:289`、`:318`）。核实结果：

- `app/lib` 里**没有直接调用** `promptSubagent` / `interruptSubagent` 的地方。
- App 打开子会话时调用 `client.routeSubagent(SubagentAddress)`（`state/agents_state.dart:484`、`:511` 的 `selectSubagent`），把子会话登记进客户端的路由表（`agents_api.dart:215`）。之后 App 对这个子会话照常调 `client.prompt` / `client.cancel`；而 `DshClient.prompt`（`session_api.dart:443`）和 `cancel`（`:464`）看到该会话在路由表里，就改走 `promptSubagent` / `interruptSubagent`。也就是说**线上用的就是官方的 `subagents/*` 接口**：`subagents/prompt` 会带上 `parentSessionId`、`childSessionId`，一次性子代理（`oneShot`）抛「只能查看记录」，父会话不在运行时报「上级对话不在运行」（`agents_api.dart:275-311`）。
- 因此先前「App 无调用点、现走 `routeSubagent` + 直接 prompt 子会话」的说法需要修正：没有绕开官方接口，只是调用点在 `dsh_client` 包里的 `prompt` / `cancel` 内部，不在 `app/lib`。
- App 一侧已经有的 UI：一次性子代理在聊天页是只读的（`ui/chat/chat_screen.dart:1458-1460`，和 DSH Web 一致）；子代理对话顶栏有「‹ 上级对话」返回键（`chat_screen.dart:1463` 的 `isChild`）。没有专门做的：「上级对话不在运行」「这个子代理不能继续」这两种主机错误只有 `SubagentReadOnlyException` 的文字，没有单独的界面分支；父会话归属靠打开时的路由登记，`session/agent-busy` 时由 `adoptSubagentRoute` 兜底。要不要把这些做成显式界面、以及打断语义怎么定，需要单独设计，本波次不改，标「待设计」。待真机：对一个正在运行的连续型子代理续聊、打断。

## 缺口与后续

下面按本轮（2026-11-05）延后清单同步；「原因」是这轮没做的理由，不是永远不做。

| 项 | 原因 |
|---|---|
| Live Activity / 灵动岛 | 需要 ActivityKit、Widget 扩展，并要 dsh-watch bridge 发 `liveactivity` 推送，涉及服务器侧改动，工作量大、风险高 |
| iPad 多窗口（`UIApplicationSupportsMultipleScenes`，现为 false，`Info.plist:70-71`） | Flutter 多 Scene 支持仍是实验性，App 的 Riverpod 全局状态按单窗口设计，改动面大 |
| iPad 拖放附件 | Flutter 没有内建 drop 目标，要新增依赖（`super_drag_and_drop` 或 `desktop_drop`）；用户同意加依赖后可做 |
| App Intents「最近会话」、小组件 | 需要 App Group 里的会话快照数据（靠推送或后台刷新喂），与 Live Activity 同一套数据通道；「问 DSH」是 ios-native 的可选尾项 |
| Cordis 批准运行原生化 | 用户实例没在用 cordis 预设，价值低；仍在网页版 |
| 子代理续聊 / 打断的显式错误界面（见上一节） | 接口已经走官方 `subagents/*`；「上级不在运行」等错误的专门界面要先定父会话归属与打断语义 |
| 「按工作区树」视图与手动拖拽排序 | 树视图在手机抽屉里价值一般；手动排序要 `workspace/insertSessionBefore` 加本地顺序投影与拖拽手势，和「文件夹 + 置顶 + 日期」模型冲突，需先设计 |
| 右侧栏 Split / Fullscreen、插件 tab | 手机 / 平板用页面切换代替分屏，不是缺陷；要对齐需先定对话详情是否改成标签树 |
| 创造模式「创建你的插件」入口、`Work details` 四档详细度（App 聊天页） | 没做，待设计；见上面对应两行 |
| 横屏 iPhone 键盘不弹 | 模拟器自动化的局限，待真机确认；真机复现再派 |
| iOS 标准导航栏与「‹ 上一页」 | 边缘右滑返回已有（`ui/theme/page_transitions.dart:427`）；换系统导航栏是全局设计变更，需用户拍板 |
| iPad 上搜索 / 终端 / 设置子页满屏推入 | 不是错误，属设计讨论；要做就在 `AdaptiveLayout` 的 medium / expanded 分支改成分栏或 sheet |
| iOS 配置项（ATS、启动屏深色、深色 / tinted 图标） | 发布工程事项；`PrivacyInfo.xcprivacy` 已存在 |
| 语音「服务器 `speech/prepare`」 | 已 ready，无需动作 |
| dsh-media 安装、dsh-go-bridge | 用户决定不装 |

以下是更早就在这里的条目，仍然有效：

- **下载会话日志（`/export`）**：☑️ 已原生实现（`lib/ui/features/session_export_page.dart`）。和官方一样 GET `api/session.export?sessionId=…&includeDescendants=true` 拿 ZIP（`dsh-session-<id>.zip`），然后走系统分享或存到「下载/DSH」。入口：输入框 `/export`、全部功能 › 导出对话日志。经 DSH Remote 中转的主机没有 HTTP 通道，导不了，页面会说明。
- **凭据遮挡**：☑️ 已原生实现（`lib/ui/chat/secret_mask.dart`），匹配规则照官方 `lib/client.js` 移植。
- **原生化候选**：Cordis 的批准运行和插件界面（目前在网页版）。
- **待真机验证**：iOS 回前台的连接恢复、宠物避让、iPad 三栏取舍与快捷键 / 左右对比；深链在手机 WebView 里是否都落对（rc.5 页面没有重测）；SSH 主机的网页版；原生终端的软键盘与快捷键行；语音输入（系统识别与引擎插件两条路）；订阅登录失效后「重新登录」的整条路径；DS Bot 通知点开的跳转。

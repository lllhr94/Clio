# Clio `batch-0.36` 全量功能地图（Feature Inventory Map · Deliverable #4）

> 盘点 `App/Sources/`（179 个 Swift 文件）与 `AgentKit` 暴露给用户的全部能力，严格区分为 **L1 一级能力入口**（每天/高频直接使用的功能）、**Global Settings 全局设置**（改变整个 App 的行为与外观）、**Per-Chat 局部设置**（仅改变当前会话或单步动作），以及 **System 系统级集成表面**。

---

## 一、A 类：一级功能入口（L1 Capabilities — 用能力，不是调设置）

| 功能能力 | 日常称谓 / 书卷称谓 | 真实源码文件 | 当前真实入口与点击路径 | 心智模型与可发现性问题 | DS 2.0 建议落位 |
|---|---|---|---|---|---|
| **案头首页与待办流** | 首页 / 案头 | `DeskHomeView.swift` | 侧栏第一项「案头」或启动默认页（1 tap） | 承载旅伴横条、待审批横幅、晨信与最近对话；右上 3 按钮与侧栏重复 | **侧栏 L1 #1 首页**（精简顶栏重复按钮） |
| **发起新对话 / 新建叶** | 新对话 / 另起一叶 | `NewChatSheet.swift`, `LeavesSheet.swift` | 首页右上图标 / 侧栏顶部胶囊 / 聊天内⋯菜单（1–2 taps） | 「把旧对话收成一叶」概念对新用户略抽象，需要更直白副标题 | **全局新建动作**（侧栏顶胶囊 + 首页主入口） |
| **旅伴管理与名帖** | 助手与群聊 / 旅伴与雅集 | `NameCardView.swift`, `CardEditors.swift` | 首页横条 / 首页 `＋` 菜单 / 设置 › 旅伴（1–3 taps） | 管理入口分散在首页 `＋` 和设置 › 旅伴两处 | **侧栏 L1 #2 旅伴**（管人/群聊/导入名帖，行为设置留设置） |
| **四层长期记忆管理** | 记忆 / 拾遗 | `MemoryPageV2.swift`, `MemoryImportSheet.swift`, `MemoryReviewHistory.swift` | 侧栏 → 调弦 → 旅伴 → 记忆（**需 4 次点击！**） | **核心 L1 能力被当成设置深藏 4 层以下**，用户几乎找不到在哪删改记忆 | **侧栏 L1 #3 记忆（1 tap 直达）**，设置保留「自动召回与夜间整理开关」 |
| **文件workspace与PDF知识库** | 文件与知识库 / 书案 | `StudyPage.swift`, `Study/Workspace.swift`, `Study/InteractivePreview.swift` | 侧栏「书案」 / 聊天顶栏 ⋯ › 打开文件（1–2 taps） | 0.36 新增 PDF 全文索引能力仅隐式给模型调，用户看不见哪些文件已入库可检 | **侧栏 L1 #4 文件与知识库**（显示索引状态+快速预览） |
| **内嵌网页浏览器** | 浏览器 / 远游 | `Roam/Browser.swift`, `Roam/RoamChrome.swift` | 仅聊天顶栏地球图标（模型跑浏览时出现）或首页无独立入口 | 用户想预先登录某个网站让代理续接时，没进对话前找不到入口 | **侧栏 L1 #5 工作台 › 浏览器** + 聊天快捷地球钮 |
| **本地 Linux 终端** | 终端 / 斗室（含笔砚全屏） | `Study/DenPage.swift`, `Study/Inkstone.swift`, `Study/OutfitSheet.swift` | 侧栏「斗室」 / 聊天顶栏 ⋯（1–2 taps） | 「斗室」和设置里的「远程主机 远山」同样开 `InkstonePage` 全屏终端但分开摆 | **工作台 › 本地终端（Alpine）** 与 SSH 主机关联互通 |
| **SSH 远程主机与远程终端** | 远程主机 / 远山 | `HillsPage.swift`, `Hills/Tunnel.swift` | 侧栏 → 调弦 → 能力 › 远山（**3 taps + 混在设置弹窗里**） | SSH 是**管理远程工作环境与私钥的工具能力**，并非应用设置 | **工作台 › SSH 与远程主机**（配置首页也能直接搜到并跳转） |
| **定时任务** | 定时任务 / 更漏 | `Routines.swift` | 侧栏 → 调弦 → 能力 › 定时任务（**3 taps**） | 查看/停用/修改每日简报或提醒必须钻进设置 | **工作台 › 定时任务** + 设置 › 自动化跳转 |
| **手札与日记回顾** | 日记 / 手札 | `Reading/Daily.swift` | 聊天/晨信关联卡片或旅伴名帖附近 | 目前入口较隐晦，和 4 层记忆回顾容易混淆 | 并入 **记忆 › 日记与回顾时间轴**（或在旅伴详情页卡片化呈现） |
| **全库统一搜索** | 搜索 / 寻访 | `DeskHomeView.swift:127`, `DeskSidebarView.swift:35`, `MemoryPageV2.swift`, `clio-docs-fts.db` | 分裂为首页找话、侧栏按标题过滤、记忆页内找记忆 | **缺少跨「对话+记忆+PDF/文件」统一检索表面** | **侧栏顶部统一搜索栏（3 Tab 结果聚合）** |

---

## 二、B 类：Global Settings 全局设置（改变整个 App 的行为、偏好或密钥凭据）

| 分组归属 (现状 vs 2.0 建议) | 功能设置项 | 真实源码文件 | 当前路径与点击 | DS 2.0 精确归类与说明 |
|---|---|---|---|---|
| 模型与服务 | **服务商与 API 密钥** | `ServicePage.swift`, `SetupView.swift`, `BrandIcon.swift` | 调弦 › 服务商（push，+号却弹 sheet） | **1. 模型与服务 › 服务商列表**（全部统一 NavigationStack push；仅新建向导用 sheet） |
| 模型与服务 | **默认 / 备用 / 整理 / 生图模型** | `DefaultModelsPage.swift`, `Design/ImageModelPage.swift` | 调弦 › 默认模型（生图藏其二级） | **1. 模型与服务 › 模型分配**（主/备/记忆小模型/生图模型同组或直观入口） |
| 外观与阅读 | **主题与纸色/纯黑（设色）** | `Design/LookPage.swift`, `Design/Ink.swift` | 调弦 › 设色 (2 taps) | **2. 外观与阅读 › 主题与配色**（含浅/深/OLED 纯黑/纸底或纯白/6 色系/气泡色） |
| 外观与阅读 | **字体与标记字体（笔庄）** | `Design/FontPage.swift`, `Craft` | 调弦 › 字体 (2 taps) | **2. 外观与阅读 › 字体系统**（正文体 / 题词体 / 代码等宽体，含宋体/楷体按需下载） |
| 外观与阅读 | **字号、行高与界面密度** | `Design/LookPage.swift:131`, `Pref.swift` | 调弦 › 字号与大小 (2 taps) | **2. 外观与阅读 › 排版与界面密度**（补齐标题字重/段距/阅读宽度独立 `StopRow`） |
| 外观与阅读 | **日常 / 书卷称谓切换与旁注** | `Tone/ToneViews.swift`, `Tone/*.json` | 调弦 › 称谓与旁注 (2 taps) | **2. 外观与阅读 › 用语风格**（支持热切 1,075 个键名及旁注开关） |
| 外观与阅读 + 对话 | **动画淡入、触觉开关与帧率检测** | `ChatDisplayPage` (`SettingsView.swift`), `FrameMeter.swift` | 调弦 › 对话显示与反馈 (2 taps) | 拆出 **「动效与触觉」进外观**（增独立震动强度/关闭）；帧率开关进 **数据与诊断** |
| 对话与 Agent | **消息上下文、压缩与温度步数** | `ChatContextPage`, `Pref.swift:109-126` | 调弦 › 上下文与长短 (2 taps) | **3. 对话与 Agent › 上下文与生成参数**（基础滑尺直接可见；温度/上限/步数收纳为高级折叠） |
| 对话与 Agent | **思考过程、心绪与运行行迹展示** | `ChatDisplayPage`, `Pref.swift` | 调弦 › 对话显示 (2 taps) | **3. 对话与 Agent › 对话展示**（是否显示思考、心绪、耗时与默认展开行迹） |
| 对话与 Agent | **语音识别与朗读 (STT/TTS)** | `VoiceSettings.swift`, `Voice.swift` | **藏在「对话显示」里或仅靠搜索！** | **3. 对话与 Agent › 语音、听写与朗读**（独立二级页，首页搜「语音/whisper」直达） |
| 记忆与旅伴行为 | **自动召回、夜间整理与晨信日记** | `MorningSettingsPage`, `TeamModel+Memory.swift` | 晨信单挂一页；记忆开关在记忆页右上 | **4. 旅伴与记忆 › 记忆策略与晨信日记**（行为开关放设置；增删改记忆放侧栏 L1「拾遗」） |
| 记忆与旅伴行为 | **宠物选择、大小与安静模式** | `Pet/PetPage.swift`, `PetLibrary.swift` | 调弦 › 宠物 (2 taps，目前弹 sheet) | **4. 旅伴与记忆 › 像素宠物**（也可从聊天点小克长按菜单直达设置） |
| 工具与扩展 | **MCP 连接器目录与 OAuth** | `Connect/ConnectorsPage.swift`, `Google.swift`, `MCPAuth.swift` | 调弦 › 能力 › 连接器 (2 taps sheet) | **5. 工具与扩展 › MCP 连接器**（统一标注「云端 OAuth / 本地隧道 / 远山自建」关联说明） |
| 工具与扩展 | **技能管理与自定义技能** | `Skills.swift`, `SkillInstaller.swift` | 调弦 › 能力 › 技能 (2 taps sheet) | **5. 工具与扩展 › 技能目录** |
| 工具与扩展 | **联网搜索引擎与 SearXNG** | `SearchSettings.swift` | 调弦 › 能力 › 联网搜索 (2 taps push) | **5. 工具与扩展 › 联网搜索与自定义引擎** |
| 工具与扩展 | **工作目录与外部文件夹挂载** | `Workspace.swift`, `MountedFolders` | 书案文件页底部/菜单操作 | 在 **5. 工具与扩展 › 工作空间与挂载权限** 给出统一管理与状态排查入口 |
| 权限与隐私 | **全部能力许可、智能审批与外网卫士** | `Grant/GrantsPage.swift`, `Grants.swift` | 调弦 › 能力 › 权限与批准 (2 taps sheet) | **6. 权限与隐私 › 权限与安全边界**（集中管理设备权限、常允许工具清单及 `followAfterWeb` 外网限制） |
| 权限与隐私 | **密码匣（信匣）** | `Vault/SecretsPage.swift`, `Secrets.swift` | **藏在「面容锁」最下面！（3 taps）** | **6. 权限与隐私 › 密码匣（信匣）**（提升为一级安全行：明确标注与钥匙串绑定、模型不可见、备份加密） |
| 权限与隐私 | **面容锁与后台遮蔽** | `Design/AppLock.swift`, `PrivacySettingsPage` | 调弦 › 通知与隐私 › 面容锁 (2 taps) | **6. 权限与隐私 › 应用锁与屏幕保护** |
| 通知与后台 | **完成通知、灵动岛与后台续跑** | `NotificationSettingsPage`, `LiveTurns.swift`, `KeepAwake.swift` | 调弦 › 通知与隐私 › 通知与后台 (2 taps) | **7. 通知与后台 › 通知、灵动岛与后台运行** |
| 数据、诊断与关于 | **本地加密备份 / WebDAV 恢复** | `Care/Backup.swift`, `Care/WebDAV.swift`, `Care/CarePage.swift` | 调弦 › 隐私 › 养护与恢复 (2 taps，混在 1583 行巨石内) | **8. 数据与养护 › 备份与云同步 (WebDAV)**（独立清晰表单） |
| 数据、诊断与关于 | **存储空间、归档与缓存清理** | `Care/CarePage.swift` | 同上，混在 `CarePage` 中部 | **8. 数据与养护 › 存储空间与归档管理** |
| 数据、诊断与关于 | **总用量仪表盘、日志与性能掉帧检测** | `UsageSheet.swift`, `Care/Diag.swift`, `FrameMeter.swift` | `CarePage` 底部 + 聊天内跳转 | **8. 数据与养护 › 用量统计与诊断日志** + **9. 关于 Clio**（版本/更新说明/开源许可） |

---

## 三、C 类：局部 / 单会话或上下文临时设置（Per-Chat / Ephemeral）

| 能力 / 控制 | 真实源码 | 生效范围 | 当前入口 | DS 2.0 保留与规范约束 |
|---|---|---|---|---|
| **单会话覆盖模型 & 思考档位** | `ChatPage+Chips.swift` (`ChatModelMenuView`) | 仅当前对话 `chat.key` | 聊天顶栏模型胶囊 | **保留原位 1 tap 切换**，明确提示「仅影响这段对话，全局默认不变」 |
| **打开对话内终端 / 文件 / 连接器 / 技能** | `ChatPage+TopBar.swift`, `ChatPage+Dock.swift` | 当前对话快速唤起 | 聊天顶栏 `⋯` 菜单 | 按频率与场景收敛为：常用直达 `搜对话 / 看大纲 / 全库导出` + 能力快捷面板 |
| **当前轮「回溯 / 重发 / 引用 / 朗读」** | `ChatPage+Rows.swift`, `ChatAssistantCell.swift`, `QuoteSheet.swift` | 单条消息 | 回复操作栏 / 长按 | 维持无干扰单行动作条；长文支持跨段系统选字后原位触发引用 |
| **本对话上下文估算 / 立即压缩 / 请求报文检视** | `UsageSheet.swift`, `ModelInputPage.swift` | 当前会话上下文 | 点顶栏百分比或底栏菜单 | 保持为轻量半屏 Sheet，增加环状进度可视化与清晰中文用量对比 |
| **常亮黑屏工作态 (`AlwaysOn`)** | `Design/AlwaysOn.swift` | 当前长任务运行期间 | 聊天 `⋯ › 常亮黑屏` | 保持 OLED 极低功耗纯黑保护，数字强制 `monospacedDigit()` 防跳动 |
| **聊天内隐藏宠物「先躲一会儿」** | `Pet/PetStage.swift`, `PetLibrary.swift` | 临时 1 小时隐藏或按气泡静默 | 长按输入框小克 | 保留直观长按菜单与提示通知气泡；**严禁阻挡正文/按钮点击** |

---

## 四、D 类：系统级集成表面（iOS System Surfaces）

- **灵动岛与锁屏实时活动 (`LiveTurns.swift`, `TurnActivity.swift`)**：呈现运行步数、状态、待批准角标（参考 Flighty 紧凑双行信息密度，最多 2 条关键字段）。
- **桌面小组件 (`WidgetFeed.swift`)**：每日晨信预览、快速开启语音/问答、待审批提醒。
- **App Shortcuts / URL Schemes (`ClioApp.swift:141-160`)**：`clio://chat/<id>`、`clio://ask`、`clio://dictate`、`clio://new`、`clio://settings/<page>`——DS 2.0 改造所有 `SettingsPage` 路由必须 100% 保持已有 `clio://settings/<page>` 深链兼容。

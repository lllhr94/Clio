# Clio `batch-0.36` 现有 UI 全量审计报告（Deliverable #3）

> **审计基准**：`https://github.com/lllhr94/Clio` 分支 `batch-0.36`（截至 PR #93 / `9d92652`），基于 `App/Sources/` 下全部 **179 个 Swift 源文件**及 `zh-CN.daily.json` / `zh-CN.literary.json`（每份各 **1,075 个叶子键**）逐行源码实测审计，非旧版截图推测。

---

## 一、全局设计基础设施审计（`Ink` / `Kit` / `Words` / `Prose` / `Pet` / `Haptics`）

| 现有模块 | 核心源文件 | 实测亮点（必须继承） | 实测缺陷与隐患（2.0 必须解决） |
|---|---|---|---|
| **Ink 色彩系统** | [Ink.swift](file:///f:/work/Antigravity/Clio/App/Sources/Design/Ink.swift#L207-L387) | ① 支持纸墨四底组合（`paper` `#F6F1E7` / `white` `#FFFFFF` / `inkDark` `#1C1A17` / `oled` `#000000`）；<br>② 六组古典色盘（黛/胭/竹/缃/藤/墨）会以 `0.05 * tint` 极克制渗入底色；<br>③ 朱红 `seal` 严禁普通按钮使用；<br>④ 聊天气泡用 `glassBubble` 轻量渐变描边替代长列表真玻璃，保住 120Hz。 | **WCAG 2.1 AA 对比度硬伤**（Python 实测）：<br>• 浅色 `#F6F1E7` 上：`inkFaint #A8A294` = **2.26:1（不及格）**；`warn #C08A3E` = **2.69:1（不及格）**；`ok #5E8C6A` = **3.43:1（小字不及格）**。<br>• 深色 `#1C1A17` 上：`inkFaint #6E685D` = **3.14:1（小字不及格）**。<br>• `Ink.Palette` 里 `ok/warn/stop` 为全局静态，未针对白底 vs 纸底、OLED 纯黑做动态亮度拉升。 |
| **Ink 字体与 Prose 排版** | [Ink.swift](file:///f:/work/Antigravity/Clio/App/Sources/Design/Ink.swift#L433-L578)<br>[Pref.swift](file:///f:/work/Antigravity/Clio/App/Sources/Design/Pref.swift#L15-L98)<br>[ChatListModels.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatListUIKit/ChatListModels.swift#L110-L200) | ① 已具备 `MapleMono + ClioMonoCN` 2:1 等宽对齐字体方案与半角字细胞缩放（`codeBlockFonts`）；<br>② `Pref.leading` 自动抵消各字体原生行高差异（解决文楷自带大行距吞掉调节感）；<br>③ 0.36 UIKit 引擎 `ChatResolvedMetrics` 已实现 H1/H2/H3 分级（`1.24 / 1.13 / 1.05` × `readingSize`）、`paragraphGap = 0.72×`、`listSpacing = 0.42×`。 | ① **可调节维度不足**：`LookPage`/`Pref` 仅暴露字体、字号（6 档 `15–24`）、行距（4 档 `1.35–1.8`）与界面密度，缺少**标题字重**、**段落间距**、**阅读行宽**独立控制；<br>② 缺少 **W3C CLREQ** 中文标点挤压与行首行尾禁则统一规范；<br>③ `ApproveView.swift:135` 硬编码 `.fontDesign(.rounded)`，未跟随 `Theme` 系统走；<br>④ 标题倍比 `1.24 / 1.13 / 1.05` 在 `17pt` 下仅 `21 / 19 / 18 pt`，H2/H3 区分度偏弱（任务书第八节建议测试 `22–24 / 19–20 / 17–18 pt`）。 |
| **Kit 公共组件 & lint 护栏** | [Kit.swift](file:///f:/work/Antigravity/Clio/App/Sources/Design/Kit.swift#L1-L180)<br>[StopPicker.swift](file:///f:/work/Antigravity/Clio/App/Sources/Design/StopPicker.swift#L1-L180)<br>[tools/lint.py](file:///f:/work/Antigravity/Clio/tools/lint.py#L1-L140) | ① `RowLabel`、`IconBadge`、`RowCard`、`StopRow`/`StopRuler`、`WideButtonStyle` 统一性高；<br>② `StopRuler`（竖向胶囊刻度尺）锁定 `lockedGeometry` 防止拖动字体变化自毁视图，并支持 VoiceOver 调节；<br>③ `tools/lint.py` 自动阻断裸 `design: .monospaced`、裸 `.custom(...)`、裸颜色、5 档外硬编码字号及裸书卷词。 | ① 组件**状态系统不完整**：缺少统一的 Loading / Error / Empty / Disabled 6 态契约，`PressStyle` 与 `TapStyle` 在按压反馈上有混用；<br>② `StopRuler` 滑过默认基准档位（如 `1.0×` / `1.65×` / `17pt`）时只发统一样式 `tick`，缺乏「基准回中加重一档 `detent` 触觉」；<br>③ `IconBadge` 目前强绑定在古典 6 色 `Ink.Tile`，且不同页图标大小、背景形式未覆盖空态插画系统。 |
| **Haptics 触觉系统** | [Haptics.swift](file:///f:/work/Antigravity/Clio/App/Sources/Haptics.swift#L1-L67)<br>[Ink.swift](file:///f:/work/Antigravity/Clio/App/Sources/Design/Ink.swift#L641-L654) | ① 已封装 `CoreHaptics`（`CHHapticEngine`），并为朱印 `thud()` 设计了瞬态+连续低频+回弹三段式 AHAP；<br>② `Pref.haptics` 提供总开关。 | **严重过度震动缺陷（违背 Apple HIG 与任务书第十五节）**：<br>① `Haptics.light()` 实际调用了 `.medium` 马达且 `intensity = 0.8`（过重！）；<br>② `PressStyle(haptic: true)` 默认给**几乎所有普通按钮**在 `isPressed` 时打一次 `Haptics.tick(0.5)`（`rigid` 马达）；<br>③ 无连续拖拽节流阀（≥ 35ms）、无 `Selection / Success / Error` 语义原语、无独立强度档位、听写录音期未明确物理静默约束。 |
| **Words 双称谓词典** | [zh-CN.daily.json](file:///f:/work/Antigravity/Clio/App/Sources/Tone/zh-CN.daily.json)<br>[zh-CN.literary.json](file:///f:/work/Antigravity/Clio/App/Sources/Tone/zh-CN.literary.json) | 双语JSON严格 **1,075 键对等**（43 个命名空间），`L.hint()` 支持书卷模式旁显示日常灰色小字。 | 新用户首次进入遇到「调弦/拾遗/斗室/远山/更漏/应许/密匣」理解门槛偏高；`DeskSidebarView`（如 `调弦`）、部分设置子页未全量配齐日常旁注或清楚解释，且两词典混用 `L.t` 与老代码 `Words.t`。 |
| **Pet 像素宠物** | [PetStage.swift](file:///f:/work/Antigravity/Clio/App/Sources/Pet/PetStage.swift#L23-L160)<br>[PetPage.swift](file:///f:/work/Antigravity/Clio/App/Sources/Pet/PetPage.swift#L6-L120) | ① 严守「立于输入框上沿、仅可左右拖拽、上提松手挤压落回」红线，并主动避让右下方「回到底部」钮与回复按钮；<br>② `reduceMotion` 下关闭弹性动画与随机闲逛；<br>③ 跨对话冒泡可一键直达待审批/完成会话。 | ① 当键盘弹出与输入框动态增高（多行输入 + 附件 + Dock 卡片）并发时，多卡片叠高易压缩正文阅读视口；<br>② 三套候选视觉语言（若启用无朱印风格）需适配与气泡材质一致的载体，而非单一静态边框。 |

---

## 二、聊天界面 20 项完整逐项审计（对应任务书第九节）

| # | 审计元素 | 现有实现源码 | 现状评估与优点 | 实测问题与 DS 2.0 改进重点 |
|---|---|---|---|---|
| **1** | **顶部导航栏** | [ChatPage+TopBar.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatPage+TopBar.swift#L42-L234) | 悬浮极简玻璃背板 + 向下纸色渐变溶出（无 hard scroll edge）；AX 大字态自动分两行避免挤爆。 | 右侧controls组（模型胶囊 + 浏览器钮 + ⋯更多）在窄屏下与旅伴状态角逐水平空间；缺少与底部工具态的一体化安静退让策略。 |
| **2** | **模型名称与思考档位** | [ChatPage+Chips.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatPage+Chips.swift#L40-L150) | 当前不离开聊天即可点顶栏胶囊换模型和探测后的真实思考档位；长模型名自动剥离日期后缀 `shortModelName`。 | **无触觉/视觉清晰度分层**：切换模型和思考档位应走 `Selection` 触觉；多供应商重名模型在下拉里视觉层级较密。 |
| **3** | **旅伴头像与运行状态** | [ChatPage+TopBar.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatPage+TopBar.swift#L14-L40), [Glance.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/Glance.swift) | 点头像弹 `Glance` 一眼卡或 `NameCardSheet`；状态映射齐全（闲坐/沉吟/落笔/候印）。 | 在消息流正文里默认关闭头像（`chat.faces = false`）节省横向宽度是对的，但顶栏状态文字「落笔/沉吟」对开启书卷词典的新用户缺少直观微动画语义区分。 |
| **4** | **用户消息气泡** | [ChatOtherCells.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatListUIKit/ChatOtherCells.swift), [Ink.swift](file:///f:/work/Antigravity/Clio/App/Sources/Design/Ink.swift#L686-L697) | 使用 `glassBubble` 仿玻璃微高光描边替代昂贵真 `.glassEffect`，滚动 120Hz 稳且支持多色气泡定制。 | 多图/多文件+长文本共存时，气泡内附件间距与文本对齐基准可按 `4/8/12/16` 更严整收敛。 |
| **5** | **AI 正文** | [ChatListViewController.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatListUIKit/ChatListViewController.swift), [ChatTextTileRenderer.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatListUIKit/ChatTextTileRenderer.swift) | **核心护城河**：UIKit `UICollectionView` + `NSAttributedString` 预排版 + `CoreText` 异步瓦片栅格化 + 向上翻页 0.0pt 锚点锁定。 | 必须保留全部 UIKit 底层架构，只在样式/度量（H1-H3 阶梯、CLREQ 标点与中西间距、代码块/表格对比度）上注入 DS 2.0 Token。 |
| **6** | **思考过程** | [ThinkingBox.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ThinkingBox.swift#L6-L130) | **Live 防跳设计极佳**：思考时固定 3 行窗体（`.lineLimit(3, reservesSpace: true)`）+ 无动画流式刷新（避开叠影），结束折叠成 `"想了 N 字"`；还区分 `PulseBox` 心绪块。 | 缺**耗时等宽读数**（如 `已思考 12.4s`）与统一 `2pt` 语义左轨；折叠行字色 `inkFaint` 在 Clio 1.0 下仅 `2.26:1`，极易看不清！ |
| **7** | **工具执行过程** | [ChatTrace.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatTrace.swift#L101-L140), [ChatWorkingBar.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatWorkingBar.swift) | 区分 `ok / failed / unknown` 明确语义（防误报），收起成单行脉冲概要，展开为时间轴。 | 当并发只读工具（0.36 新特性：5–8 步并行查库/读文件）同时运行，当前单行滚播易遮蔽并行进度，应引入 **Flighty/Structured 式紧凑并行时间轴 + 本轮产物聚拢**。 |
| **8** | **计划清单** | [PlanCard.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/PlanCard.swift#L5-L137) | 自创 `PlanReveal` SwiftUI `Layout` 只动画裁剪高度、内部列表预先排版好，完全消除了展开时的文本重排卡顿。 | 在 `Dock` 上与审批/浏览器手交卡片并发时占用垂直空间较多；`Reduce Motion` 已做好，可补充完成后的自动轻收起提示。 |
| **9** | **命令输出 & 代码块** | [ToolTail.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ToolTail.swift#L5-L143), [ChatBlockViews.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatListUIKit/ChatBlockViews.swift) | `ToolTail` 250ms 节流合并突发日志只取最后 5 行，防刷屏掉帧；代码块 2:1 等宽居中西对齐。 | 长表格与多语言代码块在深色/浅色下语法色（如注释 `inkFaint`）对比度需调至 AA ≥ 4.5:1，代码头「复制」缺少清晰的已复制微状态切换。 |
| **10** | **任务状态与灵动岛** | [LiveTurns.swift](file:///f:/work/Antigravity/Clio/App/Sources/LiveTurns.swift), [ChatPage+Composer.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatPage+Composer.swift#L36-L80) | `ChatAwayCardView` 在其他对话完成/出错/待签时及时汇总提醒；Live Activity 支持锁屏/灵动岛续看。 | 任务完成/失败状态卡当前依赖较细文字与 `inkSoft`，高信息密度场景缺少 Flighty 式的「主指标大字 + 辅助元信息等宽对齐」层级。 |
| **11** | **审批卡片（高危红线）** | [ApproveView.swift](file:///f:/work/Antigravity/Clio/App/Sources/ApproveView.swift#L5-L180), [InlineApproval.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/InlineApproval.swift) | 具备 `Taint.reason` 外网污染强制弹窗 + `canTrustThroughWeb` 隔离、`forced == true` 禁止常驻授权、AX 大字号自动切平铺滚动、就地与全屏双入口。 | ① `ApproveView` 目前强耦合书卷「倾斜信纸+朱印」；方向 B/C 需要非书卷对等仪式（但不削弱任何一步安全防线与滑轨阈值）；<br>② 命令风险摘要与参数细节混在一块，缺少飞书 Card 2.0 的「左标签右等宽」可快速核查字段。 |
| **12** | **主动提问卡片** | [InlineAsk.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/InlineAsk.swift#L7-L183) | **0.36 重大升级**：非涉密问题对话内直接单选/多选/自定义输入，`field.secret` 与 `requiresVault` 强制切到 `FormSheet` 隔离密钥。 | `limitWarning` 多选上限提示目前纯靠字色变化与 `1.8s` 自动消失，缺少结构化计数胶囊（如 `最多选 2 项`）与更紧凑的选项排列。 |
| **13** | **来源引用** | [ChatSources.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatSources.swift#L12-L100) | 行末紧凑多站点堆叠图标胶囊 `N 个来源` + 搜索引擎过滤 `isSearchPage`，彻底解决行内 `[1][2]` 角标过小误触问题。 | 展开后的 `SourcesSheet` 以网址与标题为主，可增加命中摘要摘录预览与外网来源风险提示。 |
| **14** | **图片、文件和互动预览** | [InteractivePreview.swift](file:///f:/work/Antigravity/Clio/App/Sources/Study/InteractivePreview.swift), [ChatProseRenderer.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatListUIKit/ChatProseRenderer.swift) | `WorkspaceFileRef` 软链接逃逸防护、0.36 新增 MCP 工具图预算控制、断网 `WKWebView` 沙箱互动预览。 | 点击消息内图片/文件卡片跳全屏查看器可升级 iOS 26 原生 `.matchedTransitionSource` 一镜到底缩放过渡。 |
| **15** | **回复操作栏** | [ChatAssistantCell.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatListUIKit/ChatAssistantCell.swift) | 仅在每轮完整回复末尾落一行轻量操作（复制/引用/重来/朗读/记一笔），不把每个段落包成厚卡。 | 当小克 `PetStage` 站在输入框上沿时，靠 `replyActionsRight` 自动让位机制好，但部分图标缺少语义化分组。 |
| **16** | **历史跳转与小地图** | [ChatPage+Outline.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatPage+Outline.swift), [ChatPage+Finding.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatPage+Finding.swift), [ChatPage+Dock.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatPage+Dock.swift#L121-L210) | 支持目录大纲（问答对预览）、全会话异步搜索（不打断分页窗口）、右缘小地图游标与 `navigationGeneration` 防跳回错位。 | 「回到我上一句」浮动钮与小地图的显隐时机 (`1.4s`) 在快速连续浏览长对话时有时闪现较快；建议增加滚动条旁轻量锚点提示。 |
| **17** | **输入框** | [ChatPage+Dock.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatPage+Dock.swift#L56-L120) | 底部液态玻璃容器承载多行输入、长粘贴自动转附件芯片 (`keepLongPaste`)、引用预览与编辑重发模式。 | 编辑重发状态与引用追问状态在输入框上方堆叠时视觉区分度接近，应增加清晰的顶部语义色条/胶囊标签。 |
| **18** | **附件选择** | `ChatPage+Attachments.swift` | 支持相册多选、相机、书案文件、网页链接、剪贴板自动识别与排队草稿附件持久化。 | 底部附件图标矩阵在纯文本短对话与多附件排队状态下的视觉过渡可更统一。 |
| **19** | **语音、停止与发送** | [Voice.swift](file:///f:/work/Antigravity/Clio/App/Sources/Voice.swift), [ChatPage+Composer.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatPage+Composer.swift), [AlwaysOn.swift](file:///f:/work/Antigravity/Clio/App/Sources/Design/AlwaysOn.swift) | 具备系统识别 & 云端 STT（Groq/硅基流动/OpenAI）、防误触长任务停止二次确认（`confirmStop`）、排队消息发送策略（等做完/插嘴）。 | 语音口述态波形与实时转写状态在输入框内的空间反馈不如豆包/ChatGPT 清晰明显；停止按钮应按防误触策略配清晰状态语义。 |
| **20** | **宠物与键盘联动** | [PetStage.swift](file:///f:/work/Antigravity/Clio/App/Sources/Pet/PetStage.swift), [ChatListViewController.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/ChatListUIKit/ChatListViewController.swift#L91-L108) | `ChatListViewController` 拥有专门的 `keyboardSpacerView` + `CADisplayLink` 键盘插值同步，`PetStage` 跟着输入框上沿稳稳上移，不盖住输入框和按钮。 | 需在 DS 2.0 验收清单中将「键盘弹出时宠物高度、输入框与最新消息底部间距同步 0 跳位」列为 ProMotion 真机一票否决项。 |

---

## 三、导航、搜索与设置分类现状关键缺陷（为第五–七项提供实证依据）

通过逐行检查 [DeskSidebarView.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/DeskSidebarView.swift)、[DeskHomeView.swift](file:///f:/work/Antigravity/Clio/App/Sources/Reading/DeskHomeView.swift)、[SettingsView.swift](file:///f:/work/Antigravity/Clio/App/Sources/SettingsView.swift) 与 [CarePage.swift](file:///f:/work/Antigravity/Clio/App/Sources/Care/CarePage.swift)，确认以下 **6 大真实结构性痛点**：

1. **核心功能「深埋失踪」**：
   - **长期记忆（四层记忆 `MemoryPageV2`）**：既不在侧边栏导航，也不在设置首页！用户想手动看/改记忆必须点 **4 次**：`打开侧栏 → 调弦(设置) → 旅伴 → 长期记忆(拾遗)`，或者靠搜索框搜词。
   - **密码匣 (`SecretsPage`)**：不在「capabilities/权限」里，而被藏在 `通知与隐私 → 面容锁` 页面底部。
   - **语音设置 (`VoiceSettingsPage`)**：藏在 `对话显示` 子页里；**生图模型 (`ImageModelPage`)**：藏在 `默认模型` 子页里，用户无法从设置首页直接感知这两项能力。
2. **设置页面跳转行为精神分裂 (`SettingsView.swift:333-338`)**：
   - `SettingsView` 首页 6 组共 **21 行**，其中 12 行是 `NavigationStack` 右推进入（如服务、模型、外观），而同屏另外 9 行（`add, pet, grants, connectors, skills, timing, hosts, care, vault`）突然改为 **`.sheet` 从底部弹出**！甚至同一分组内上一行右推、下一行弹窗，破坏 iOS 原生空间心智模型。
3. **`CarePage.swift` 单体巨石（1,583 行代码）**：
   - 在名为「隐私与安全 › 养护」的一张弹出表单内，硬塞了 **8 个截然不同的职责**：本地加密备份、WebDAV 云备份/恢复、已归档对话统计、设备诊断信息、磁盘缓存清理、网络连通性探测、最近报错日志、掉帧测试 (`Hitches`) + `UIKit Spike Lab` + 版本号与关于。
4. **全局搜索支离破碎**：
   - 侧边栏搜索框 (`DeskSidebarView:35`) **只按对话标题与最后一句预览过滤**，搜不到聊天正文；
   - 首页放大镜 (`DeskHomeView:127`) 调 `team.search()` 搜全量对话，但**完全搜不到「四层记忆（拾遗）」和「书案文档/PDF 知识库（0.36 `clio-docs-fts.db`）」**，三个检索库各自孤岛运行。
5. **首页与侧栏入口重复打架**：
   - 侧边栏头部已有「新对话」、底部已有「调弦（设置）」；首页右上角 (`DeskHomeView:267-306`) 又重复摆出「新对话」「＋(旅伴/雅集/收名帖)」「调弦（设置）」三颗悬浮玻璃圆钮，造成入口冗余与视觉散乱。
6. **远山（SSH）与连接器（MCP）关系模糊**：
   - `HillsPage.swift` 同时管 **SSH 远程电脑** 与 **远程 MCP Server**（需要手填 URL / 隧道），而 `ConnectorsPage.swift` 又单独列了一份常用 MCP 连接器名录，两者都往 `Hills.shared.servers` 写入数据，但界面彼此割裂且缺乏引导互链。

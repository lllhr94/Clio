# 现状与交接

## 0.37 PR 1B（独立工作树）

- 工具图片保存为本地引用。当前轮和上一轮可内联，较早图片可凭引用重看、补笔记，缺失时显示过期。媒体清理只选超过 30 天且能确认无人引用的文件。
- 请求窗口保留完整的工具调用与结果。自动重试受输出和副作用约束，超长请求在同一模型服务保留本轮结果。工具重复时先提醒换个做法，仍无进展才停下。
- 辅助视觉默认关闭。图片和压缩资料按服务地址、协议、请求路径和数据类型授权。服务身份变化或恢复备份后，发送需要重新确认。
- 用量页可在本机清理旧工具输出并撤销，也可重试失败的上下文压缩。压缩前的记忆提取在开始和落盘时都校验写入权限。
- 书案及可写挂载的删除进入回收站，保留 30 天。原位置、目录或文件身份不符时保留回收站项目。回收站内容和索引排除在备份之外。
- Windows 已核对 1C 文件锁及静态检查。新增 SwiftPM 测试和 App 集成测试，等待 macOS CI 编译运行及 iPhone 验收。

## 0.36 发版定稿（11-27，PR #67–#102 → `batch-0.36` → `main`）

- **正式版本**：**Clio 0.36**（`CFBundleShortVersionString = "0.36"`，发行标签 `v0.36` / `latest`），已按主人确认（「这版就做 0.36 正式版吧 模糊跟磨砂下个版本修」）于代码基线 `4c8d7ba` 冻结并合入 `batch-0.36` 与 `main`，更新说明见 `docs/releases/0.36.md`。
- **包含范围**：120Hz 全 App 流畅度与对标 Telegram 引擎（PR #67–#94）+ Clio DS 2.0 Wave 1–5 堆叠改动及真机反馈修整（PR #95–#102）；`AgentKit` 412 项测试全部通过（CI `45875357022`）。
- **留到下一版（0.37）继续做**：
  1. **聊天顶栏渐进模糊与输入框磨砂通透度细调**（按主人最新实机反馈，记入 `docs/FEEDBACK.md` 0.37 待办第一条）。
  2. **子会话异步干活与双轨交流节奏**（之前主人已确认：① 后台子会话异步干活＋自动回信，主对话不卡死；② 先接话再干活；③ 闲谈与干活双轨分流）。

## Clio DS 2.0 工程实施汇总（11-26，Wave 1–5 堆叠 PR #95–#100）

- **冻结设计基线**：`origin/design/v2-review` v16（Design Tokens `2.4.0`；Telegram 原版参考上游提交 `24638bc`），基于 `batch-0.36`（`ee034ac`，已合入 PR #67–#94）以 5 组可独立回滚的堆叠分支依次实现；已随 PR #101–#102 一并合入 `batch-0.36` 并快进合入 `main` 发版 0.36。
- **堆叠分支与试签验证进展**：
  - **Wave 1**（`antigravity/ds2-wave1-tokens-haptics` -> `batch-0.36`，PR #95）：WCAG 2.1 AA 全量色彩与 `UIScale`/排版开关 Token、`PressStyle` 去默认震动与语义/节流触觉、`StopRuler` 默认档位圆点与震感、双语词典对称键及 `tools/lint.py` 规则。
  - **Wave 2**（`antigravity/ds2-wave2-typography-reveal` -> Wave 1，PR #96）：原样移植 Telegram `TextRevealController.swift`（附 `UPSTREAM.md` 与 `README.md` `GPL-2.0-or-later` 致谢）、CoreText `Points` 揭示掩码与突发降级、单源 `SafeLineBox`（消除 `lineSpacing`/`minimumLineHeight` 叠加并对齐用户气泡）及四套阅读预设 + 9 项精细排版控件。
  - **Wave 3A**（`antigravity/ds2-wave3a-chat-chrome` -> Wave 2，PR #97，CI `45750773619`）：`ChatChromeCoordinator` 统一协调 12 项浮层、`Scroll-Aware Chrome` 沉浸阅读与流式停止胶囊、顶栏模型名简化、`Paper Scrim` 防透字。
  - **Wave 3B**（`antigravity/ds2-wave3b-ia-settings` -> Wave 3A，PR #98，CI `45756201280`）：侧栏 `4+1` 信息架构、`UnifiedGlobalSearchSheet` 全域检索（含中文 IME 防断保护）、设置页 `8+1` 统一 `NavigationStack` 分类与 `CarePage` 拆解。
  - **Wave 4**（`antigravity/ds2-wave4-workflow-network` -> Wave 3B，PR #99，CI `45758960253`，`AgentKit` 407/407 通过）：工具执行严格 7 态、批准单手势取消保护与无障碍等效按钮、`PrivateNetworkPolicy` 五域分类与 Fake-IP 代理兼容开关、`PrivateNetworkGrant` 作用域授权与 6 类可懂诊断、多跳 SSH `ProxyJump` 及路径绑定指纹校验。
  - **Wave 5**（`antigravity/ds2-wave5-polish-a11y` -> Wave 4）：`InteractivePreview` 与 UIKit 图片/交互卡 `.matchedTransitionSource` / `preferredTransition = .zoom` 一镜到底缩放；`Ink.inkFaint`、边框/分隔线高对比度自适应，减透明降级、减动效避让、`DenPage` 非纯色终端状态图标与 `StopRow`/`StopRuler`/`ApproveView`/`InlineApproval`/`InlineAsk`/`AlwaysOn` 全组件 AX1–AX5 断点重排。
- **PR #95–#100 复审问题修复（11-26 同步并向下合齐至 Wave 5）**：
  - **PR #96（P1）**：恢复 80 字无装饰短文本同步绘制阈值，将流式渐显 CoreText 图块与 `ChatRevealLayoutSnapshot` 统一移回后台队列并用令牌序号保序防并发覆盖。
  - **PR #97**：在 `ChatChromeCoordinator` 监听旁白状态变化通知，沉浸态下开启旁白立即恢复顶栏与输入区。
  - **PR #98**：`UnifiedGlobalSearchSheet` 变更关键词立即清空旧命中防误点，并把 PDF 命中页码传给 `StudyFile` 的 `PDFView` 精准跳页。
  - **PR #99（P1）**：为远游所有操作入口（含页面点击、表单填写/提交、信匣填凭据、`browser_read/text/screenshot/scroll/back/tabs`）接通 `.read`/`.write`/`.credential` 私网授权校验，撤销后对已打开标签即时阻断。
  - **PR #100**：UIKit `preferredTransition = .zoom` 退出时校验 `card` / `PictureBlockView` 复用世代、源路径与窗口在场性，防复用缩回错图。
- **待 iPhone 真机联合验收清单**（60Hz 标准屏 + 120Hz ProMotion，详表见 `design/design-system-2.0/engineering/04-device-qa-and-acceptance-rubric.md` D1–D15）：
  1. **排版与字体**：实测霞鹜文楷、`New York`、苹方与宋体在 7 处正文面的无双倍行距对齐，确认长文档/混合中英代码块与表格手感。
  2. **Telegram 渐显实体校准**：在实体 iPhone 上对照慢速/突发/中英混排流式长段实测 `durationMultiplier`、`SnippetLayer` 高负载熔断与定稿选区稳定性。
  3. **Scroll-Aware Chrome 与 Zoom 过渡**：沉浸收起/恢复及「停止生成」胶囊、中文输入法全域检索连续选词、图片与 `InteractivePreview` 缩放过渡。
  4. **私网与跳板实网验证**：Fake-IP（`198.18.0.0/15`）开/关对照、`*.local` / `.ts.net` / 已授权内网 HTTP/HTTPS、SSH `ProxyJump` 多跳指纹校验，确认 `127.0.0.1` 与云元数据 `169.254.169.254` 零豁免拦截。
  5. **无障碍全开关**：VoiceOver 逐项朗读与操作、`AX3+` 大字号重排与旋转、增强对比度、减弱透明度、减弱动态效果、纯黑 OLED 切换。

## 11-26 DS 2.0 聊天真机反馈

- 顶栏助手胶囊过长，输入区会盖住刚发的消息，沉浸时顶栏和遮罩占位过大。已在 [PR #101](https://github.com/lllhr94/Clio/pull/101) 收紧顶栏和沉浸控件，并补输入区避让，待真机复核。
- 流式正文一次冒出整段、阅读位置跟不上，以及短消息气泡两端呈尖角。后续分支 `codex/ds2-stream-reveal` 叠在 #101 上。正文逐帧显露，贴底时滚动跟着已显示的行走，上翻和选字时停留。短气泡的底色、光泽和阴影沿同一轮廓绘制。需在真机对照慢速、突发和单次回包，以及单字、短句、换行和长按气泡。
- Antigravity 接手后续分支 `antigravity/ds2-stream-reveal-polish`（叠在 PR #101 上，开 PR #102）：
  1. 流式与私网收口：微调长回复收敛速度与 `SnippetLayer` 触发阈值（120 pts），取消渐显中途向下拖动进入空白区时的回弹，并补齐 #99 远游私网授权复检（异步查权前后校验页面未换、只读模式放行纯 `<a href>` 链接导航并拦住按钮/脚本提交）。
  2. 顶底栏美学与可开关沉浸重构（第一步）：移除 `DeskSlideHost` 安全区硬切线并加顶/底独立纸雾渐隐；顶栏改为 Hana 风极简居中三段式（空闲仅头像＋名字，点开直达切模型/思考/详情/名帖，干活显状态）；底栏改为方案 A 收窄单胶囊（空闲 `26pt` 留白、打字舒展至 `20pt`、低占比先隐用量圈），右上/左下角浮钮统一圆润样式，宠物改为纯被动附带兼容；「滚动时沉浸阅读」进「设置 › 对话 › 对话显示与反馈」（默认关，打开即启用 120Hz 跟手渐进＋防长回复误弹）；并接入 `ask_companion` 回信居中轻提示，发布含全量改动的 `probe-antigravity-ds2-stream-reveal-polish` 试签包。
  3. 下一波独立计划（第二步，已由主人确认需求）：① 后台子会话异步干活＋自动回信（主对话不卡死）；② 先接话再干活的表达节奏；③ 闲谈与干活双轨分流。
  4. **纸墨设计原语、正文改版与设置瘦身联合批次（Antigravity + Codex 协作互审）**：新增 `SlidingCapsuleControl`、`DetentPaperBackdrop`、`FloatingToastOverlay`（独立透传 `UIWindow`）、三档触感（含低电量自动静音）与「减弱视觉效果」、模型自定义名称及防重名消歧；正文页实现齐状态栏光学渐进模糊（`0..<safeAreaTop+4pt`）、纯透明液态玻璃底栏（空闲 `28pt` 边距 / `8pt` 抬高）、顶部 `36pt` 同心头像并锚定原位 `ChatCompanionHubPopover`（动态读取全部 `endpoints` 的两层供应商→模型切入）、极简 4 组 `⋯` 菜单、单一 `⌄` 回底钮、双方头像纯标识 Q 弹与 `Haptics.light()`、克制自适应胶囊与审批落印回弹；设置页由 Codex 收拢为 5 大组 + 右侧全热区「我」头像菜单 + 3 格状态快览 + 多段比例存储条（`StorageCleanup` 五类不重叠口径），双端交叉审查后统一发 `probe-antigravity-ds2-stream-reveal-polish`。
  5. **真机实测返修与全端光学模糊统一（Antigravity + Codex 互审定稿）**：修复正文右上 `⋯` 菜单与查找条被 `GlassFaceModifier` 拦截导致无法点击的问题；新增公共 `TopEdgeBlurVeil`（基于 `UIVisualEffectView` 分片与 `UIViewPropertyAnimator` 公开接口实现真光学渐进模糊），统一铺开至正文状态栏（锁死 `safeAreaTop+4pt`）、设置首页与子页及全 App 次级滚动页；修复 `DeskSlideHost`（及 `ChatRoamThumbHost`）正常动效传入 `nil` 导致侧滑遮罩竖向断层的动画 bug；沉浸阅读模式收拢为右下角单颗带未读角标的 `⌄`（支持轻点正文空白处及 Switch Control / 键盘无障碍动作恢复栏位）；顶部旅伴弹卡消除模型 ID 重复并固定「供应商 → 模型」两层结构，同时拓宽至 `312pt` 并增大底部圆角留白；`ChatBarMetrics` 与列表缩放解耦锁住 HanaAgent 黄金控件尺度（`46pt` 顶栏 / `38pt` 头像 / `44pt` 回底钮 / 奶雾 `.regularMaterial` 磨砂加厚收窄输入框 `334pt` 宽），并校准新机 `UIScale` 四档（`84% / 90% / 95% / 102%`）兼容无感迁移升级与老备份恢复。
  6. **实机彻查回归与全端苹果原生边缘模糊恢复（Antigravity + Codex 联合审计及互审）**：彻底删除 8 切片 `TopEdgeBlurVeil` 及全部 20 处自定义叠层（解决状态栏斑马纹、侧栏静止糊掉「首页」、设置与弹窗双层叠雾），UIKit 聊天列表重新启用苹果原生 `topEdgeEffect` / `bottomEdgeEffect` `.soft` 并通过 `additionalSafeAreaInsets` 随顶底栏和沉浸收起同步伸缩（SwiftUI 列表/表单统一纯净 `.scrollEdgeEffectStyle(.soft)`）；全聊天浮钮（`≡`、旅伴胶囊、`⋯`、浏览器指示器、`findBar`、`⌄`、输入框）统一改用 Hana 风奶油磨砂 `frostedChatChrome`，去掉顶栏胶囊多余的 `v` 箭头并用三槽自定义 `Layout` 实测左右宽度消除切换缩放后短名被截断成 `...` 的问题（弹卡宽度自适应视口）；`DeskSlideHost` 改为常驻 `sidebarDimVeil`、同事务提交展开位移并按实时露出宽度裁剪侧栏，根治侧滑在 `sideWidth` 处的垂直明暗切线；修复设置快览「默认模型」宽格展示防截断、`UIScale` 读取边界自动归一化、宠物右避让随 `ChatBarMetrics.jumpSize` 联动与 44pt 隐形输入区命中热区（兼容 `PetStage` 拖曳边界）；并一并修复 Codex 查出的 5 项隐藏缺陷（`lastTailLineID` 隔离翻旧消息误计未读与震动、`WeakViewControllerBox` 解除来源弹窗强引用环、Toast 按 `dedupeKey` 防连续归档互相覆盖撤销及主窗体 `UIAlertController` 避让、记忆归档串行捕获真实原层级并在撤销时完整还原深浅/置顶状态、`StorageCleanup` 跨目录 inode 去重与「其他」占比展示、全端统一 `!Theme.shared.reduceVisualEffects` 及全局不动点模型消歧）。
  7. **聊天顶缘原生渐进模糊与 HanaAgent 通透磨砂收口（Antigravity + Codex 互审定稿）**：将真实 `ChatTopBarView` 通过 `PassThroughTopEdgeContainerView` + `UIHostingController`（`safeAreaRegions = []`、`isTyping`/`onDismissTyping` 跨宿主解耦、左右约束贴合安全区、大字模式动态高度联动、三/四槽精准空白透传与归属安全弹窗收口）直接嵌入 `ChatListViewController`，挂接苹果原生 `UIScrollEdgeElementContainerInteraction(edge: .top)` 绑定 `collectionView.topEdgeEffect.style = .soft` 并关闭 `bottomEdgeEffect`，保留 `.never` 与零逐滚动 `additionalSafeAreaInsets` 回写确保 120Hz 流畅与状态栏下方紧致渐进模糊（SwiftUI 备用列表同步切 `.safeAreaBar(edge: .top)` 并隐藏底缘）；同时将 `FrostedChatChromeModifier` 调为 `.ultraThinMaterial` + 极淡纸色染色（浅/深/OLED 独立调参、细渐变描边与高对比实色清晰边界）让背后柔焦文字隐约可辨，并为 `ChatComposerTextField` 保留常驻 `"消息"` 标签与 `Ink.inkSoft` 提示对比度。

## 当前一览（11-25，Clio 0.36 全 App 120Hz 流畅度与对标 Telegram 引擎升级收口）

- **集成分支**：`batch-0.36`（`CFBundleShortVersionString = "0.36"` / `CFBundleVersion = "37"`，`fc2f66c` 起，当前已合并 PR #67–#94，最新代码合入提交为 `8417b4d`）；**未碰 `main` / `latest` / `v0.36`**，正式发版仍等主人说「发」。
- **CI 改进**：`0545787` 为 `.github/workflows/build.yml` 的 `AgentKit` 测试补充失败断言高亮输出（不再被 `tail -n 80` 遮盖前置套件错误）。
- **已合入 PR（Wave 1–4 与两次安全加固均已通过本地门禁、Pro 审查及 macOS CI 全绿）**：
  - **Wave 1**
    - `v36-1a-perf-fix`（PR #67，`239a9fa`，CI `45443323679`）：用户气泡改轻量 `glassBubble` + 1.5pt 编辑框、`Voice` 语音懒加载、`ProseView` 配置快照整合、正则预编译与 `fresh` 观测隔离。
    - `v36-1b-memory-safety`（PR #68，`c93f37f`，CI `45449509297`）：`Entry.tainted/delegated` 隔离、SHA-256 撤回记忆哈希与轮内删除实时停发、`AssembledSystemPrompt` 前缀/动态尾切分、压缩与切走前记忆冲刷。
    - `v36-t-mcp-image`（PR #69，`b09e4e1`，CI `45457682671`）：修好 `Hills.swift` 保留 MCP 图片到 `ToolOutput.images`，`Craft/MCPImage` 像素/体积预算控制及单轮上限，`canSee` 下沉到 `Hills.shared.tools(canSee:)`。
  - **Wave 2 + `T_CACHE`**
    - `v36-3-spike-uikit`（PR #70，`51d8776`，CI `45457589213`）：隔离 UIKit `ChatUIKitSpike` 原型（连点 5 下「养护 › 版本」或 Debug 下可见，含跨段选字「引用」、前文 20 条稳停与 `anchor Δ`、流式定稿零闪跳测量）。
    - `v36-t-web-search`（PR #71，`51cf3d1`，CI `45459450988`）：修复 Bing/DDG 广告与追踪剥离、中文与非东亚多语种相关性打分、新增 HTTPS/局域网 SearXNG 与源站绑定密钥及有序回退、`speak()` 接 `NLLanguageRecognizer` 自动识别语种。
    - `v36-t-cache`（PR #72，`50c562e`，CI `45460741559`）：`Endpoint.promptCache` 与设置页 Anthropic 缓存开关（`nil` 沿用旧版主机默认策略防旧中转报错）、`ModelRequest.systemCachePrefix` 同步原子实时前缀实现两段系统提示 `cache_control` 切分。
    - `v36-2a-readonly-index`（PR #73，`9ca1f0a`，CI `45461880846`）：契约一可重建只读 SQLite3 + FTS5 索引 `clio-index.db`（schema v3、分槽版本、CJK 二元词与长消息分块去重、SQL 层 `MemoryAccessContext` 与 `leaf_tainted` 遮蔽、摘录前信匣脱敏、`search_history` 接 `Grant.memory`），不动任何 canonical JSON 写入。
  - **Wave 3**
    - `v36-3a-state-split`（PR #74，`a8eb79c`，CI `45475980271`）：聊天状态域拆分、`ChatPage` 预排版解耦与宠物状态瘦身（未触碰 `PetStage.swift` / `PetPerch.swift` 拖拽定位红线）。
    - `v36-t-ask`（PR #75，`eba5f8e`，CI `45476926514`）：主动提问卡片 InlineAsk v2（单选/多选/文本输入与涉密字段强制走信匣规则校验 `AskUserRules`）。
    - `v36-2b-memory-db`（PR #76，`e43108c`，CI `45484583716`）：权威 `clio-memory.db` 与 canonical JSON 对账同步、四层记忆（常驻/近期/较早/封存）、删除墓碑同步及 `书案` Markdown 镜像。
  - **Wave 4（含安全专题与 4B 收官）**
    - `v36-t-conc`（PR #77，`02377b3`，CI `45487989339`）：只读工具并发批处理（外部读取与非只读自动退回串行）与连续重复轮询刹车（`Agent.swift`），修复并发栅栏单测等待竞争。
    - `v36-t-bak`（PR #78，`a3bbfc8`，CI `45493772745`）：`BackupCrypto` 口令加密备份（PBKDF2-HMAC-SHA256 >= 600,000 + `AES.GCM` + 头段 AAD）、WebDAV 分块流式上传下载、`书案/技能/` 暂存恢复、`Vault`/SQLite 严格排除。
    - `v36-3b-uikit-chat`（PR #79，`a34f3b4`，CI `45494622169`）：正式聊天流迁移至 `UICollectionView`（`App/Sources/Reading/ChatListUIKit/*`）及外观「聊天列表引擎」调试切换入口，合齐双词典新键。
    - `v36-2c-memory-ui-import`（PR #80，`36343e2`，CI `45496948531`）：四层记忆管理页 `MemoryPageV2`、待审提案合并与批量一键记忆导入 `MemoryImporter`（含粘贴脱敏）。
    - `v36-3c-interactions`（PR #81，`fc1e07b`，CI `45503174152`）：UIKit 聊天列表跟手键盘弹出与下拉收起、`Desk` 侧栏随动视差（遵守减弱动态效果）、大图 Hero 缩放转场与查看器。
    - `v36-security-fix`（PR #82，`ab7fee1`，CI `45503610384`）：根据 Codex 审计补牢 4 处安全规则——含密钥备份全程内存组包封缄（明文 `#keys` 不落 `.part` 磁盘）、拒绝从未加密备份导入 `#keys`、`AskUserRules` 对非涉密字段也拦截 URL 内嵌口令/凭证、`MemoryImporter` 识别 JSON 引号包裹的密钥键值对。
    - `v36-4-recall-fts`（PR #83，`c617224`，CI `45507298082`）：通道一 FTS5 `.deep` 零成本召回（严格仅拼入易变 `extraTail`，保持 `systemCachePrefix` 字节级不变）、夜间 `MemoryPromotionPolicy`（`.pinned` 与墓碑严格免疫、零召回/单次未编修浅用不误晋升）与单事务提交、`Library/Caches/ClioIndex/clio-docs-fts.db` 自愈文档索引（保留 PDF 页码与分目录密文轮换清理）。
    - `v36-4b-sec-fix`（PR #84，`53a30a8`，CI `45512687307`）：根据 Codex 对 PR #83 的只读审计修齐 5 处边界——检索查询截断与 `Set`/单次分析防耗时拖慢、PDF 越界页码 `Int32(exactly:)` 防崩溃、`search_docs` 路径与返回边界实时信匣脱敏及轮换重检、`Disk.frozen` 阻断读盘与 `MountedFolders.revision` 变动失效防陈旧命中、`LiveChatMemoryGate` 在单对话关闭记忆后同轮立即停发常驻与召回记忆。
  - **真机 120Hz 流畅度与小地图专项（PR #85）**
    - `v36-perf-uikit-scroll`（PR #85，`792ac13`，CI `45535306791`）：针对真机 120Hz 掉帧追踪（进页 160 ms、载入更早 159 ms、滚动 16–77 ms）与小地图问题完成 7+1 项优化——① `ChatListViewController` 滚动度量 ≥0.10s 节流+停滑立即追平、触摸滚动期冻结 `@Observable PetPerch` 突变与布局失效、隔离 `Hitches` 写 `UserDefaults` 触发头像重刷的反馈环、取消进页 `premeasureItems` 双重测算并下调 `.steps` 估算至 50；② `ChatListState.isEquivalent` 28 字段等价短路；③ `ChatTraceHostingCell` 复用持久 `TraceRowModel` 与 `UIHostingConfiguration`（`.id` 隔离行态+`TraceGeometry` 防串高）；④ `ChatProseRenderer` 用 `CTFramesetter` 单次无界/窄边安全测算替代主线程 `UITextView.sizeThatFits`；⑤ `ChatRichTextView` 无装饰跳过布局、规则/引用改单趟 `enumerateTextLayoutFragments` 与行内代码走原生 `enumerateTextSegments(.selection)`；⑥ 表格改 `UILabel` 对象池加 `contentOffset` 归零与字形越界保护、气泡 `shadowPath` 缓存、`UIDeferredMenuElement.uncached` 懒构菜单、`ChatMeAvatarView` 异步宠物包/主题签名失效及隐藏续行钮跳过重配；⑦ `loadEarlier()` 后台提前预热待展开楼层 Markdown 与代码分词（含任务取消透传）；⑧ 右侧小地图改 `ChatChrome.activeTurnID` 120Hz 单轮实时追踪、背景刻度 `Canvas` 化与独立单游标浮层，确保滑多快都仅亮唯一当前轮游标。
  - **全 App 120Hz 流畅度与对标 Telegram 聊天引擎升级（PR #86–#94）**
    - `v36-async-text-render`（PR #86，`792b398`，CI `45551380342`）：CoreText 瓦片异步栅格化底座 `ChatTextTileRenderer`、`CarePage` 分段加载、导出路径清理。
    - `perf-1-cross-page-hitches`（PR #87，`b088207`，CI `45557663856`）：全 App 跨页隐形杀手清障（`Theme` / `UIScale` 观测域拆分、滚动期隔离 `PetPerch` 突发读写不改拖拽定位、`ModelError` / `EndpointKey` / `Chat` 主线程清理、`tools/lint.py` 性能守卫规则）。
    - `perf-3-subpages-io-lazy`（PR #88，`b07e129`，CI `45566799046`）：高频子页 I/O 与懒加载改造（`MemoryImporter`、`MemoryStoreBridge` `commitQueue`、`CareWebDAVCoordinator`、`Inkstone`、`Grants`、`SecretsPage`、`Attach` 等）。
    - `perf-2-settings-services`（PR #89，`3566424`，CI `45566183786`）：设置页与服务商/模型流畅度（`ChatDisk` + `TeamModel+Options` 统一落盘与刷盘栅栏、`EndpointMutationGate`、字体进度门控、`BrandIcons` 限额缓存）。
    - `perf-4-chat-desk-120hz`（PR #90，`5edea12`，CI `45579920302`）：聊天 120Hz 清障与首页 `Desk` 拆解（`BoundedLRUCache`、`DeskHomeView`/`DeskSidebarView`/`DeskSlideHost`、`tools/lint.py` 四条性能规则升级为硬错误，0 perf errors）。
    - `perf-5a-chat-bg-prefetch`（PR #91，`766f9a9`，CI `45593836738`）：Telegram Step 1 — 只读 `Sendable` 布局测量快照、`UICollectionViewDataSourcePrefetching` 滚动前方与进场/更早后台预热、公式非阻塞估算+无跳动锚点回填、进程级单调递增 `renderToken`。
    - `perf-5b-chat-uikit-cards`（PR #92，`9b8cc58`，CI `45604825230`）：Telegram Step 2 — 清除列表滚动内 `ChatHostedBlockView`，将文件卡片/图片块（共用 `LocalPictureCache` / `FileCardCache` / SSRF 防护下载器）、折叠与实时 `.steps` 摘要（点击弹原有 SwiftUI 详情 sheet，带卡片/展开回退 `ChatTraceHostingCell`）与 `.liveToolTail` 全部切为纯 UIKit 视图。
    - `perf-5c-chat-async-coretext`（PR #93，`9d92652`，CI `45615041312`）：Telegram Step 3 — 补齐 `didReceiveMemoryWarning` 瓦片与装饰缓存清理、`drawGeneration` 复用防串图与流式 15Hz→定稿无闪烁交接、旁白静态朗读与链接自定义操作、`hitTestLink` 行内边界收敛、深浅/缩放无残影重绘，及气泡更多菜单「选择文本」（异步弹起原生选字并保留自定义菜单）。
    - `perf-5d-polish-memory-home`（PR #94，`8417b4d`，CI `45648772318`）：真机 456 包复测收口——将「记忆 / 拾遗」上提到设置首页（并去重搜索项）、书案 ≥4KB/≥60 行 `.txt` 与 ≥128KB `.md` 切 TextKit 2 懒排版阅读并拆分「书案列表 / 书案文件」掉帧页名、养护页首帧延后挂载网盘输入框与归档区（120ms）、右侧小地图拖动与跳转提前后台预热落点前后消息。
- **审查覆盖与交接 Claude 复核重点**：
  - Wave 3–4、两轮安全修复及 PR #86–#94 均经过 Antigravity Pro 只读逐行复审（全部 `READY TO MERGE`）及 macOS CI 单测编译验证；Codex CLI 对 `batch-0.36` 安全边界与 `4B-1` 做了两轮只读对抗审计（已修问题见 PR #82、PR #84）。
  - **留待 Claude 回来重点复核**：① `Agent.swift` 只读并发门禁与循环刹车（PR #77）；② `Backup.swift` / `BackupCrypto.swift` 口令流、`#keys` 拒绝未加密导入与 `书案/技能/` 暂存回滚（PR #78、PR #82），以及原有 `Team/mounts.json` 进备份评估；③ `AskUserRules.swift` URL 凭证拦截范围（PR #75、PR #82）；④ `MemoryStore` / `MemoryRecall` / `DocSearchIndex` 访问隔离与 `LiveChatMemoryGate` 轮内实时关停（PR #73、#76、#83、#84）；⑤ **设计裁决留档**：`MountedFolders` 用户自行在文件 App 挂载的本地文件夹暂维持与 `read_file`/`read_pdf` 一致的「非外部网页污点」策略（见 `CraftTests.swift:508`），待 Claude 一并确认 `search_docs` / `read_file` 挂载目录是否需要单独接入 `Taint`。
- **下一步**：待含 PR #86–#94 的最新 `probe-batch-0.36` 测试包在 iPhone 真机复测「设置首页记忆入口、书案大 txt 预览、进养护页首帧、右侧小地图跳转」手感；主人计划下一版大改 UI / UE；正式版待主人确认「发」且 `docs/releases/0.36.md` 写好后再合并到 `main`。

---

**远程工作地点（PR #66）**：编辑或删除主机后，作废使用旧连接配置的待批准请求。已删除的远程工作地点提示重新选择，文件与命令执行都没有本地回退。引擎 `Agent.perform` 的单次授权作用域和 `Taint` 规则随本 PR 一并留待交接复核。

**终端审批（PR #61，已进入 0.35 试签包）**：聊天底部可查看完整的可滚动说明。有完整命令或脚本的强制单可就地确认一次，其余强制单走大单。待真机核对长说明滚动、按钮热区和审批后正文位置。

**11-24 集成**：PR #63 合入终端命令分组、已保存输出、失败与结果未知提示及单轮步数选项。PR #62 同步这套命令卡和「接着做」入口，加入正文缓存、挂载撤销校验、图片缩略解码和养护页掉帧记录节流刷新。待集成包真机复测。

## 当前一览（11-24，Antigravity 0.35 发版前对齐）

- **版本**：0.34 已发布（`v0.34` / latest，`main` = `ae7a7d6`）。进行中 0.35，集成分支 `batch-0.35`（`ff38137`，已合齐 #33–#63）。
- **发版基线**：`63c82ac`（build 395）含 #64、#65、#66，已通过集成 CI 并上传 [0.35 试签包](https://github.com/lllhr94/Clio/actions/runs/45426655690)。正式版在 `main` 按 `docs/releases/0.35.md` 发布。
- **已合入 0.35**：Antigravity A2–A16 与聊天掉帧修复（PR #34、#35、#39、#40、#42、#43、#46、#47、#48、#51、#53、#54、#55、#59、#62、#63），Codex C32–C41、A8 及审批/触摸热修（PR #33、#36–#38、#41、#44、#45、#49、#50、#56、#57、#60、#61）。`TASKS.md` 里派出去的活已全部勾掉。
- **0.35 发版说明**：`docs/releases/0.35.md` 已补齐 #65 诊断与跳转、#66 权限与工作地点。
- **发版前体检（11-24，无阻断问题）**：两份词典 867 键完全一致、零缺键；`tools/lint.py` 0 报错；新增字体授权与 README 致谢齐全；A9/A11 密钥均在钥匙串、不进备份。记录 3 条非阻断小项可后续顺手处理：① 设置搜索关键词补「步数 / 智能审批 / 缓存」（已在 PR #65 补齐）；② `project.yml` 系统权限弹窗静态文案仍含「旅伴 / 信匣」；③ `Backup.swift` 含 `Team/mounts.json`（换机后需重新授权挂载，等 Claude 回来与「备份带上技能」一并评估）。
- **真机复测进展**：`ff38137`（build 385）已在真机完成首轮排查，养护页掉帧已降至 1 次；长对话仍观察到向上跳动（含正文高骤降与小地图二次落位）及 120 Hz 聊天掉帧，已单开 PR #65 补详细诊断轨迹、隔离滚动浮层状态并做跳位兜底。合入后待真机复测跳动与掉帧，并核对撤挂载预览、就地审批、命令折叠卡及 0.35 其余新功能。
- **后续安排**：终端外部内容后是否按本地斗室 / 远山区分放行边界；下一批小改动；浏览器和云端；闲谈、宠物画中画、让 AI 做宠物。
- **等 Claude 回来**：备份带上 `书案/技能/`（并评估 `mounts.json`）；复查这一个月合进来的安全相关改动。

**A12 稳健与流畅收尾**（PR #51，已合入 0.35）：养护页「存储与缓存」分项和保守的孤儿图片清理；排队消息跨重启保留，撤回时图片一起回到输入框；公式块放得下时不抢上下滑；新页面文案进两份词典；修了云端转写转圈时的越界闪退，压缩后上下文圈即时刷新。待真机核对。

**C39 掉帧**（PR #50）：终端输出合并更新，步骤行构建、工具输出整理和展开素材准备移出主线程。任务描述只更新本对话的订阅处，养护诊断分段加载。真机基线是 131 次、最长 612 ms，改后待同机复测。

**C40 聊天布局**（PR #49）：计划从输入框上沿展开并在卡片内裁剪，模型菜单由整张顶栏的纸色覆盖。审查通过，待真机验证。

**0.35 搜索、笔记与语音**：A9（#46）默认内置网页，可手动选择搜索服务。A10（#47）共享内容进入草稿，回复可存成笔记。A11（#48）提供选字朗读和引用、可选云端转写，地址确认后保存，HTTP 限回环和局域网 IP。下一步真机核对搜索切换、重名保存和语音转写。

**C38 侧边栏管对话**（`codex/c38-threads`）：当前和旧对话统一长按、左滑操作，置顶、归档和颜色随对话在当前段和旧对话之间移动。侧边栏删除当前段只清这一段。冷开闲置对话时首批消息行在后台整理。PR #44 已合入 0.35，待真机验证。
**A8 互动预览卡**（`codex/a8-interactive-preview`）：回答里的 HTML、SVG 文件有静态缩略图，点开可在独立离线页面操作、缩放、横屏和分享。书案文件也使用这套预览。PR #45 已合入 0.35，待真机核对 WebKit 下的缩略图、横屏及隔离。

**11-22 深夜最后（Claude）**：0.35 集成包编过、已发 probe（run 45007305614）。合进来的：A2–A7（Antigravity）、C32–C36（Codex）；Claude 拆完 `ChatPage.swift`、`Team.swift`（只搬家），加了 Anthropic 缓存、领券和防骗规矩、通知里不能批读过外部内容的单子、挂载文件夹的写入在读过外部内容后要问、网盘恢复可选份。等主人真机试。下一步见 `docs/TASKS.md`；Claude 回来先做：备份带上技能、复查这一个月合进来的安全相关改动。


> **0.34 已发布（11-22，v0.34 / latest，`main` = `ae7a7d6`）。** 新的集成分支是 `batch-0.35`，版本号已改成 0.35（37）。latest 的说明文字里版本号显示成乱码，是 CI 里 `$VERSION（` 的毛病，已改成 `${VERSION}（`，下次发版就好；这次的会话不能改 Release，主人可以在网页上手动改一下。

> **2026-11-23 起约一个月 Claude 不在**，交接见 `docs/HANDOFF.md`：Codex 临时合并和打包，Antigravity 照常领任务，正式发版仍只等主人说「发」。

**C35 小修**（PR #37，已合入 0.35）：宠物沿输入框上沿避开最新回复按钮，代码块采用半角 ASCII 与全角东亚文字，新对话默认展开，聊天产出位置按称谓显示。真机请复核小屏、不同宠物尺寸和两种代码字体。

**C36 发给模型的内容**（`codex/c36-model-input`）：聊天用量页可查看实际聊天请求，包含工具续问、重试和备用模型接手。每次按段查看并复制系统提示、记忆、技能、工具说明和上下文统计。记录只留在运行中的 App。PR #41 已合入 0.35，待真机验证。

**C33 聊天与侧边栏**：`codex/c33-chat-side`。聊天的「新对话」复用助手和记忆选择页；侧边栏旧对话支持重命名和确认后删除。流式与定稿共享正文组件。巡检新增档位卡、新对话、带置顶和旧对话的侧边栏，以及流式中段与完稿的对照。

**11-22 深夜（Claude，交接前最后一批）**：测试包 run 44970381184 编译通过、已发布。改了：调数值统一成竖向胶囊档位（`StopRow`）；上下文 / 压缩按模型上限倍数；连接器去掉自带 Client ID 和本机权限块；终端页标题、「完成」按钮；日常模式去书卷词；侧边栏只分「置顶 / 对话」并列出收起的旧对话；新对话先选助手和记不记忆；回复写完不再消失重画；思考档位逐档探测。下一步给 Codex（C33）和 Antigravity（A3），见 `docs/TASKS.md`「0.34 第四轮」。都要真机确认。

**11-22 夜（Claude）**：
- 模拟器巡检截图：CI 的截图里新加了长对话、跳到底、正在出字、纯黑、大字号、小屏（iPhone SE）几组（`Shots.swift`、`build.yml`）。截图改成小 JPEG 推到 `shots/<run>` 分支。
- 从截图里修的：回答写完那一下的重影（流式样式和定稿样式交叉淡入，两份同时可见）；筛选胶囊被硬切；设色页三个「设色」。
- A1 改由 Claude 做完：字号、行高、明暗全局即时生效；字体下载后重画；称谓跟随；深色几处。
- 列表 / 表格 / 引用中间隔一行，边写边显示不再断开（`StreamBlocks`，夹具测试已改成要求连着）。
- 写了 `docs/releases/0.34.md` 草稿；交接见 `docs/HANDOFF.md`。
- 仍未确认：29.593 秒卡顿的原因；真机上空白页是否彻底没了。

最后更新：2026-11-21（Claude 交接，额度到期前写）。接手前先读 `AGENTS.md`，谁做什么见 `docs/TASKS.md`。

更早的完整规划和执行手册在主人的 claude.ai 文档里（只有主人能打开）：https://claude.ai/artifact/UnCgDX6xF2ZfHytSFLRsVi 。仓库里以本文件为准。

## 2026-11-21 交接：接手的人先看这一节

**最新（11-21 夜里，全项目彻查）**：主人要求从头到尾查一遍，结果和修法在 `docs/AUDIT-FULL.md`（安全 10 条、数据 10 条、引擎 3 条，另有「已知没改」一节）。

**最新（11-21 深夜）**：0.34 全面审查（`docs/REVIEW-0.34-FULL.md`，32 条）里 Claude 那份已修完，逐条修法在该文件末尾「修复记录」。#22～27、#29～31 是 Codex 的 C31，PR #31 已合入。仍未确认：之前 29.593 秒卡住的根因；流式列表和表格遇到内部空行的已知问题。

**最新（11-21 晚）**：清单看 `docs/PLAN-NEXT.md`（Claude 马上做 / 接下来 / 交给 Codex）；给 Codex 的整份在 `docs/CODEX-NEXT.md`；Open Minis 65 条规则在 `docs/MINIS-RULES.md` 等主人勾选；多平台在 `docs/PLATFORMS.md`；浏览器和云端在 `docs/BROWSER-AND-CLOUD.md`。主人说「暂时先这样」，下一批等主人发话。

**当前状态**
- 分支 `batch-0.34`，最新包已打：https://github.com/lllhr94/Clio/releases/download/probe-batch-0.34/Clio-probe.ipa （run 44919087066，编译通过，含 0.34 审查修复、C31 和全项目彻查；之前 run 44913324754；之前 run 44895339886：含 Codex PR #25–#30 和 Claude 11-21 晚三批，清单见 `PLAN-NEXT.md`）。主人在真机上试，等反馈。
- 已合入：C14～C21（Codex）；Claude 的性格 / 说话风格 / 朱印字 / 名帖正反面、头像呼吸与一眼卡、记下了可撤回、问答目录、做成长图、健康卡片、常亮黑屏入口；浏览器小窗宽度、来源不重复（正文末尾的「来源：」链接列表在有来源条时藏起来，提示词也不让模型写）、窄表格铺满卡片。
- Codex 的互查问题见 `docs/REVIEW-0.34.md`，除 #8（群聊正在做的那行字闪）外都已处理。

**交给主人试的检查单**（主人回什么就记进 `FEEDBACK.md`）
1. 短表格铺满卡片；2. 浏览器小窗只有网页那么宽；3. 查网页的回复末尾不再列链接，只剩「N 个来源」；4. 新建 / 编辑旅伴选性格、说话风格、朱印字，聊几句看语气和心绪块；5. 名帖翻面、「递出去」的图不带记忆；6. 聊天页：头像呼吸、点开一眼卡、「记下了 / 撤回」、问答目录、做成长图、干活时「常亮黑屏」；7. 首页筛选、归档撤销、颜色标签；8. 常亮黑屏点一下就关；9. 隔夜看「常记」里的整理记录。

**派给 Codex、还没交**：C24 掉帧、C26 聊天页三件、C25 复查修复。Codex 暂时没额度，主人恢复后转发 `docs/CODEX-NEXT.md`。

**等主人定**（不要自己拍板）
- 下一批小改动（`FEEDBACK.md` 末尾「下一批」）：主人还没点头。建议：选字后引用追问 / 朗读、自己的消息选字引用、草稿跨重启、坏图占位、我的气泡颜色、长对话小地图。
- 浏览器追 Open Minis、云端工作区：方案在 `docs/BROWSER-AND-CLOUD.md`，要主人定先做哪几条、云端先到哪一步、本机和云端怎么分。
- 「N 个来源」做精（只这一处显示来源）。
- 闲谈（`COMPANION-DESIGN.md`）、天气卡片（要天气工具）、多条消息拼长图、宠物画中画、让 AI 做宠物。
- 0.34 发布：主人说「发」时，先写 `docs/releases/0.34.md`（中文，按主人看得懂的话），再合 `main`。

**资料**：同类 App 对照 `docs/RESEARCH-2026-11.md`（含两轮），旅伴设计 `docs/COMPANION-DESIGN.md`，聊天手感 `docs/CHAT-SMOOTH.md`，问题总账 `docs/FEEDBACK.md`，任务 `docs/TASKS.md`。

## 版本

- 已发布：0.33（`main`，`latest`，`v0.33`）。
- 进行中：0.34，分支 `batch-0.34`，测试包在 `probe-batch-0.34`。主人说「发」之前不合并到 `main`。

## 0.34 宠物跟随与大小

- C22：同一只宠物随聊天底部的输入框、批准单、短问答、查找栏、键盘和底部面板移动。拖开后固定在屏幕上，长按可回到输入框。减少动态效果时只平移。
- C23：设置里用一根滑杆即时预览，48 点是标准目标。像素档随设备和宠物素材调整，保留旧设置接近的体积。待在真机核对键盘、附件面板的交互式收起和两种屏幕像素密度。

## 0.34 掉帧排查

- C32，`codex/c32-smooth`：修了宠物包解压与解码限额、通知冷开与表单展示、后台任务收尾、听写和朗读、终端与 JavaScript 取消，以及聊天产出卡片、分享和导出路径。单帧宠物不再开绘制时钟，睡眠动画降低频率。宠物舞台的每秒状态检查在 Claude 负责的文件里，留待联动复查。后台通配符与真实到期行为仍需真机验证。

- 真机反馈定位到书案打开约 464 KB 的 TXT 粘贴片段。原预览把 TXT 当 Markdown 一次解析并排版整份文件。修复分支 `codex/large-txt-preview` 让 64 KiB 起的 TXT 直接显示原文，交给系统文本组件按可见范围排版。待装包含修复的包，用原文件复测首屏、滚动和返回。
- C24：设置首次读盘、养护占用扫描、远山钥匙串、技能和宠物读取已移出主线程。聊天的草稿与流式正文各自更新，浏览器截图在后台编码，宠物无变化时跳过布局采样。
- 改前真机记录为 11-21 的 172 次、最长 29,593 ms。改后真机数据待同一台 iPhone 复测，编译和本地验证分别记录在 PR。

## 0.35 聊天模型入口

- C34（PR #38）：聊天顶栏下方用独立一行显示当前模型，点模型名打开菜单，思考档位排在最上。当前档位失效时回到默认。设置过探测结果的按实测显示；未探测沿用服务的档位规则。底栏只保留原有的工作地点和会话操作。等待真机核对长模型名和群聊。

## 0.34 手感和屏幕适配

- C26：选字期间暂停自动回底，滑动后的跳转按钮定时淡出，顶栏入口合到 ⋯。C30：聊天按需排版、复用同宽文字高度，落盘和选择文件在后台。C25：修复互查列出的七条，并补上群聊即时心绪的发言者。
- C28：批准单、侧栏、一眼卡、长图预览、照片条、引导、聊天卡片及文件表格使用所在窗口尺寸。目标真机矩阵为 iPhone SE、标准 iPhone、Pro Max、iPad 竖横屏和分屏、最大字号。实机结果待回传。

## 0.34 首页整理

- C19 已接入侧栏四种状态筛选、颜色标签和四秒归档撤销。首次引导后未连接模型的首页显示三步清单。归档可搜索并恢复。
- 分支 iOS CI 通过，截图关闭。待合入 0.34 并在真机确认手势和首次使用流程。[GitHub Actions](https://github.com/lllhr94/Clio/actions/runs/44869592944)

## 0.34 设置重新分组

- C16：设置首页分为模型、旅伴、外观、对话、能力、通知与隐私，共 21 行，副标题说明能调什么。拆开旧外观大页，搜索可以直达各小页。各页独立恢复默认，沿用原有存储键。行距可以单独调节，也可跟随字号。
- 文件和斗室从对话侧栏进入，新旅伴和收名帖在首页右上「＋」。密码匣保留在「通知与隐私 › 面容锁」，记忆从旅伴列表进入，两项都可搜索。
- 已逐行核对源码和两份称谓词典。分支编译见 [GitHub Actions](https://github.com/lllhr94/Clio/actions/runs/44793484858)。下一步由 Claude 合入 0.34，并在集成包上核对真机点按、面容锁和系统进度显示。

## 0.34 无障碍

- C13：设置行和模型菜单可折行，聊天的大字号工具与输入框分行，批准单可滚动且权限选项可换行。补了附件、搜索、终端、文件和密码控件的 VoiceOver 名称。需在集成版本用真机的最大字号和 VoiceOver 验证。

## 0.33 已经做了

- 设置：右上角齿轮直接进；分组为 AI、旅伴、能力、工具、外观、通用；全部竖列；设置内搜索可直达子页并高亮。
- 侧边栏：搜索、新对话、首页 / 文件 / 终端、置顶与最近对话，底部一整行「设置」。
- 聊天：步骤一行一步、各有图标，做完收成一行；搜索来源叠在一起；回复底下只留复制、重来、⋯；计划清单卡（`update_plan` 工具）；多文件改动卡；顶栏和输入框后垫纸色渐隐。
- 连接器：分类、谷歌官方 MCP（一组）、此设备上的权限、推荐开关、详情；服务商图标运行时获取（含国内可达的图标源）。
- 设计系统：五档字号、三种圆角、公用组件（`Kit`）、界面大小四档（`UIScale`）。
- 排版：换字号即时生效；行距约 1.6 倍；段落与列表间距按阅读类 App 调；字号 15/16/17/19。
- 称谓：日常 / 书卷两本词典（`App/Sources/Tone/`），日常旁注，首次打开和「外观」里都能选。
- 宠物：站在输入框上、按状态动、打盹、溜达、点 / 连点 / 拖 / 长按有反应、别的对话的事冒气泡、宠物设置（大小、安静、藏 1 小时）、导入 schema 1 宠物包。
- CI 截图流程（`shots=true`，默认不开）。
- 形象换代：先做过剪影形象（卷卷、墨团、天鹅），后来整套换成像素宠物包（小克、肉包），剪影已删。

## 2026-11-20 合并与引导页（Claude）

- 合入 Codex 的 C5（宠物定格当头像和插画）、C7（小克 11 个状态、肉包 14 个状态，内置在 `App/Pets/`）、C8（小克 App 图标，浅色 / 深色 / 单色）、C9（引导插画，小克、肉包各 4 张）。
- 首次打开改成四页引导（`SetupView.welcome`）：替你动手、你拍板、选称谓（`ToneCards`，当场切换）、接上模型（接模型服务 / 先看演示）。插画按当前宠物选小克或肉包那套，最近邻放大。看过一次（`intro.seen`）后不再出现，演示退出后直接到接模型。
- 新装的手机默认宠物是小克（`builtin-xiaoke`）；以前藏起形象的人仍然是不显示。
- **旧形象整套删掉**：卷卷、墨团、天鹅、鲸鱼的剪影、「形象」页（颜色、画框、饰品、自己的画像）都没了。只剩宠物包一套角色：选中的那只就是头像和各处插图。「不显示」改成「站在输入框上」开关，关掉头像仍是它。旧设置自动迁到小克。导入宠物可以直接选一张图片或 GIF（只有闲坐一个状态）。
- 书卷词典里引导页的按钮改回日常说法（继续、就这样、接上笔庄、先看样张）。
- 署名一律 `lllhr94`，不写真名（已写进 `AGENTS.md`）。

## 2026-11-20 Clio 的标志元素（Claude）

- 主人从效果图里选定：侧边栏字标「Clio」（Hoefler Text 斜体）+ 白字红底朱印「克」（马善政毛笔字）；空对话题词「今天写点什么」两边细线（霞鹜文楷）；批准单点了同意盖「克」字朱印（拒绝仍是灰色圆章）。
- 引导页标题、批准单的来源名、填表标题改用文楷。
- 「外观」里加了单独的「字体」页（`FontPage`）：正文和标题 / 题词各选一种，每种用它自己写一行示例。正文可选书卷、苹方、圆体、宋体、楷体、文楷；标题和题词可选文楷（默认）、楷体、宋体、书卷、苹方。宋体、楷体是苹果的，第一次选时下载，显示进度，启动时自动备好。
- 字体：`App/Fonts/`，霞鹜文楷 GB 1.530（国标字形版）常规、加粗各裁到简体全部 7542 字（各约 3.5 MB，改名 Clio Kai），马善政只留「克」（2 KB，改名 Clio Seal），OFL 授权全文随包。`tools/subset_fonts.py` 可重新生成。

## 2026-11-20 发版前打磨（Claude）

- 代码字体：Maple Mono 7.9（只要英文、去掉连字，两档各 130 KB）。代码块、行内代码、斗室终端、步骤命令、模型名、路径一律走 `Ink.mono` / `Ink.uiMono`；「字体」页第三组「代码」可换回系统等宽。
- 图标：设置里的功能图标改成实心色块 + 白色实心符号 + 轻微渐变，一组一种颜色，颜色取 Clio 色板（黛、胭、缃、墨、藤、竹，`Ink.Tile`），深色模式下也够深。连接器页「此设备」和字母图标同一套颜色。
- 排版：标题上方留白加大；列表项更紧、序号不加粗、圆点变淡；表格表头下一条稍深的线，单元格用正文字体和正文颜色，按实际字体量宽；行内代码改暖灰底；代码块头部只写语言名。
- 深色模式：主按钮、滑动操作里的白字在深色下对比不够，改为纸色字或深色色块。

## 2026-11-21 一大包（Claude）

做了：旅伴头像（点头像换）、聊天里双方头像（开关默认关）、你的气泡用真玻璃、每条回复下统一的「复制 · ⋯」、正文长按自由选字（跨段，代码/表格/图片单独成块）、在对话里找、回到我上一句、做事中途只占一行、打字不重排回复、灵动岛只显示宠物小图和进度圈/勾、后台保持运行（默认关）、回来自动接着做、压缩不拿走原文且在后台进行、模型显示厂家图标加供应商角标、连接器图标和重影、C15 生图全部、C16 设置六组。每个 CI 包有新编号。
主人提的问题总账在 `docs/FEEDBACK.md`。
没做完 / 下一步：C17 风格统一（Codex）、C14 规则测试（Codex，规则抽到 `AgentKit/Sources/Craft/ChatRules.swift`，接回页面由 Claude 做）。
要观察：气泡真玻璃在长对话里会不会掉帧；后台保持运行的耗电。

## 正在做 / 下一步（按顺序）

**C8 App 图标**：主人已选定铜红长发 Q 版少女。浅色、深色与单色三种图标已接入 `AppIcon.appiconset`，待 Claude 合并后与本批次一起跑 CI。

1. **验证宠物这一包**：编译、截图核对（聊天页、宠物设置）。
2. **称谓铺满**：出错提示（`AgentKit` 的 `Explain` 在包里，需要在 App 侧按标题映射到 `errors.*`）、加载提示、其余空状态和页面里的写死文字，逐步改成 `L.t`。
3. **页面逐个打磨**（统一清单见下）。
4. **宠物第二轮**：Codex Pet 格式导入、「让 AI 帮你做一只」、iPhone 画中画小窗；等 Gemini 的宠物素材到了做成内置包。
5. **App 图标与启动画面**（等 Gemini 设计）、首次打开四页引导（文案已在词典 `onboarding.*`）、「更新了什么」提示。
6. 之后：DSH 式的工具步骤细节（每步图标块、思考穿插、「已中断」状态行、「查看改动」）、项目（Projects）。

## 首次打开引导

- C9：小克四页引导已改用 C7 定稿的闲坐首帧，只叠加道具与手，预览在 `design/incoming/onboarding/preview.png`。等主人确认后由 Claude 接入。

## 0.34 称谓第二轮

- C10：设置子页、连接器、终端、文件、批准单和填表的新增词条已接入两份词典。待主人确定的书卷说法列在 PR。

## 0.34 生图

- C15 前三步：模型服务里可选生图模型，`generate_image` 通过兼容接口生成一张 PNG，保存在书案，通过现有聊天图片语法显示。系统提示按工具是否可用引导。前三步已合入。第 4 步接收聊天模型直接返回的图片，使用同一写入路径存为 PNG，并在回复后附本地图片链接。真实服务与真机显示待验证。

## 0.34 风格统一

- C17 已逐页统一字号、间距、列表和关闭按钮。新增写死字号与直接色值检查。聊天主页面、正文和宠物目录继续由 Claude 处理。分支编译通过，见 [GitHub Actions](https://github.com/lllhr94/Clio/actions/runs/44855383786)。[PR #17](https://github.com/lllhr94/Clio/pull/17) 待合入，深浅配色和字号效果待集成包真机走查。

## 统一打磨清单

- 所有弹出页关闭方式一致（右上「好了」），标题、返回、分组标题、说明文字同一套样式。
- 空状态、加载中、出错提示同一个样子（`EmptyNote` 等）。
- 搜索框统一放在标题下面。
- 设置里功能图标考虑统一成墨色淡底（现在是五种颜色），品牌图标保留原色。——待主人定。
- 首页（窗前）去掉大鲸鱼和大片空白，节奏和侧边栏一致。
- 聊天页顶部旅伴胶囊和右侧圆钮减重；计划卡和输入框收紧。
- 拿同一段回复和 Claude 并排对比，调字距、段距、标题、列表、表格、代码块。
- 所有可点元素按下有一致的缩放和变淡；展开收起用同一套动画速度。
- 深色模式逐页检查。

## 旅伴静态图

- C5：欢迎页、接好模型、空状态、批准单、日课和旅伴头像已接入宠物包的首帧。小组件和灵动岛改用通用对话图标。待合入后统一编译和真机核对。

## 0.34 自动检查

- C11：CI 在编译前检查两份称谓词典的完整键和 SwiftUI 字体、颜色规则。当前源码通过本地检查。

## 已知问题

- 搜索工具有时返回完全不相干的结果（动漫、陌陌），需要查搜索源。
- 截图流程在模拟器里偶尔启动慢，个别截图是白屏，等待时间已调长。
- 设置子页（连接器、外观、权限、添加服务）在截图模式下有时打不开（sheet 叠在 fullScreenCover 上的时机问题），已加延迟，待验证。

## 0.34 聊天规则测试

- C14 已把分段、跟随和发送时合并滚动接入独立 Swift 测试。测试运行实际聊天规则，夹具提供可控时钟和界面边界。macOS 规则测试及 iOS 编译已通过，见 [GitHub Actions](https://github.com/lllhr94/Clio/actions/runs/44857874821)。
- 列表和表格中的空行会触发提前定稿，测试记录了现有行为。独立的输入框高度补位尚未实现。真机滚动和掉帧验证待集成包，细节见 `docs/CHAT-SMOOTH.md`。

## 0.34 记忆夜里整理

- C18 已接入 iOS 夜间后台任务和前台十分钟空闲整理。常记保留新增或合并的记录，手写和手改条目受保护。小模型可在「模型 › 默认和备用模型」选择，未选时沿用默认模型。自动手札沿用用户开关。
- 本地核对了旧数据、去重、调用限额、失败回退、重复触发和已有夜间请求。分支 iOS CI 通过，截图关闭。[GitHub Actions](https://github.com/lllhr94/Clio/actions/runs/44865771192)
- 待合入 0.34。真机核对 iOS 后台派发和实际模型响应。

## 0.34 宠物画中画

- C12：已提交调研 `docs/C12-PET-PIP.md`。等待产品决定，原型、自签实测和能耗测量尚未开始。

## 0.34 常亮黑屏

- C20 的常亮窗口已提供 `AlwaysOn.show(chat:)` 和 `hide()`。显示宠物像、当前步骤和真实耗时，每 15 秒微移。触摸或离开前台会关闭并恢复原锁屏设置。
- 分支 iOS CI 通过，截图关闭。待 Claude 接入聊天按钮后，在真机确认亮屏、微移和恢复。[GitHub Actions](https://github.com/lllhr94/Clio/actions/runs/44869904430)

## 协作分工建议

- **Claude / Codex**：写代码、修 bug、跑 CI、截图核对。一次只一个人在 `batch-*` 分支上推，开工前 `git pull`，收工更新本文件。
- **Gemini**：外援做设计（App 图标、宠物素材、文案润色），要求见 `docs/DESIGN-BRIEF.md`。产出放 `design/incoming/`，由写代码的一方接入。

## C7 宠物预览

- 肉包已定稿并打成内置包 `App/Pets/roubao/`，共 14 个状态、42 帧，署名「lllhr94」、授权「仅限 Clio 使用」。GitHub Actions iOS 编译已通过（`shots=false`）。
- 小克（宠物包 ID `xiaoke`）的闲坐与思考共六帧已定稿，以调成橘发的最早版本为底。睡觉已通过，按反馈把右上飘的 z 换成 4×4；等批准已通过。完成和工作已通过，工作按反馈下移瞳孔并整理第三帧书页。出错已通过，七个必做状态齐全。醒来、左侧被戳、右侧被戳、被连戳已交单次 GIF，全部 11 组共 33 帧汇入总预览。全部 11 组通过，已打入 `App/Pets/xiaoke/`。本轮用 `shots=false` 跑一次 iOS 编译。
- C9 的小克引导插画等宠物状态定稿后再按柔和初版调整。C5 的头像接入可用已定稿的肉包验证。

## 0.34 正文阅读排版（C27）

默认正文按主人在交接中选定的方向排版。默认行高用现有「舒展」档（1.65 倍），已存的行高和字面偏好继续生效。标题用正文字号加粗，二级列表用小实心圆，行内代码用正文墨色和淡底圆角。选字复制仍用系统选区。

## 0.34 审查第二批（C31）

- #22–27、#29–31 已在 `codex/c31-review-perf` 完成。首开聊天、用量估算和图片准备减轻 UI 线程工作。流式回复限制刷新并保留稳定段落，历史向上可继续分页，搜索只执行最新查询。终端输出按对话限量，掉帧记录按累计事件写盘，静止弹层停止宠物帧采样，长粘贴在后台转存。
- 本地聊天流程与 lint 已验证。真机仍需确认分页和流式回底的位置、弹层拖动以及相同场景的掉帧时长。之前的 29.593 秒停顿尚未归因。本地夹具仍标记流式列表和表格遇内部空行提前定稿的问题。

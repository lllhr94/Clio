# Clio DS 2.0：SwiftUI / UIKit 混合原生工程落地方案（Deliverable #19）

> **核心承诺**：所有设计视觉与交互机制均以 iOS 26 原生 SwiftUI / UIKit 可编译代码为最终设计尺度，**零网页伪特效**，且 **100% 保护 0.36 已落地高难度工程架构，不发生任何功能或性能退化**。

---

## 一、0.36 重大架构护城河与零退化红线

| 0.36 底层架构 | 设计系统 2.0 如何兼容并保护它 | 绝对禁止的做法 |
|---|---|---|
| **1. `UICollectionView` + `ChatTextTileRenderer` CoreText 瓦片** | 所有正文排版变更（H1-H3 阶梯、CLREQ 光学字距、段距、表/代码块圆角色盘）**仅作为不可变值注入 `ChatResolvedMetrics` / `ChatResolvedColors` / `ChatProseBuilder`**，在后台线程预测量后生成 CoreText 瓦片，`cellForItemAt` 主线程零文本测量。 | ❌ 严禁退回 SwiftUI `ScrollView + LazyVStack` 聊天正文；❌ 严禁在滚动 Cell 里挂 `.glassEffect`。 |
| **2. `ChatState` 状态域拆分 (`ClioRootGate`, `ChatChrome`, `ChatFollowState`, `ChatAwayCardView`)** | DS 2.0 新增的统计卡片、思考耗时秒表与全局搜索状态，均独立封装在局部 `@Observable` 容器内，**绝不污染核心 `TeamModel` 大广播导致聊天流高频整页重绘**。 | ❌ 严禁把每秒刷新的思考计时器绑在 `ChatPage` 顶层导致长列表 diff。 |
| **3. SQLite 四层记忆 + `FTS5` + 文档/PDF 检索** | `UnifiedGlobalSearchSheet` 直接并行调用已有三个轻量异步索引查询（对话 FTS5 `clio-index.db` + 记忆 FTS + `clio-docs-fts.db`），前台做 Tab 聚合排序。 | ❌ 严禁在主线程同步全盘扫描沙盒文件。 |
| **4. Agent 只读工具并发执行 (0.36)** | 升级 `ChatTrace` 面板结构，使并行的只读调用（如同时读 4 个文件 + 1 次检索）在组头显示「并发完成 5 项查阅 · 0.6s」并垂直列出，避免单行滚播互相覆盖。 | ❌ 严禁把并发调用降级回缓慢的 UI 串行等待。 |
| **5. MCP 图片输出 + `WorkspaceFileRef` 预解码** | 通过 `ImageIO` (`CGImageSourceCreateThumbnailAtIndex`) 按预算 `maxPixelSize` 后台解码缩略图；点击大图启用 iOS 26 `.matchedTransitionSource` 一镜到底。 | ❌ 严禁主线程解大 PNG 撑爆内存；❌ 严禁跳过 `Workspace.isInsideRealRoot` 检验。 |
| **6. `InlineAsk` 非密直答 vs `FormSheet` 涉密隔离** | 优化 `InlineAsk` 外观与超限计数徽章时，严格维持 `AskSheetLogic` 的 `field.secret \|\| form.requiresVault` 硬分支路由。 | ❌ 严禁把密码/API key 表单塞进聊天内联卡 `InlineAsk`！ |
| **7. `Taint` 外网风险卫士 & `Vault` 钥匙串隔离** | 方向 A/B/C 审批 UI 变化只影响视觉容器与确认滑轨仪式；`readOutside`、`canTrustThroughWeb`、`Taint.hardExits`、`forced == true` 逻辑在 Swift 层零改动直接复用；备份保留 `BackupCrypto` 与 `Vault` 物理隔离。 | ❌ 严禁给 `Taint.hardExits` 增加「以后都允许」按钮；❌ 严禁未加密备份导出 API 密钥。 |
| **8. `PetPerch` 透明窗 + 水平限位拖拽** | `PetStage` 维持独立透传窗口，遵守输入框上沿限制与 `replyActionsRight` / `keepOutRight` 避让；跨对话冒泡仍走 `PetNews.shared`。 | ❌ 严禁让宠物随意拖放到屏幕中上部或盖住消息气泡按钮。 |

---

## 二、核心 SwiftUI / UIKit 工程技术设计细节

### 1. Liquid Glass 安全分级策略（对照 Apple WWDC25 284 / 323 & HIG Materials）
- **交互浮层 (`Chrome Layer`)**：继续复用且收敛 [Ink.swift:678-704](../../../App/Sources/Design/Ink.swift#L678-L704) 的 `glassFace` 与 `glassBacking`（含透明穿透触摸补丁层 `opacity(0.001)`），应用于 `ChatTopBarView`、悬浮 `ChatComposerBarView`、右下跳转圆钮与 `ApproveView` 顶部完成按钮。
- **渐隐垫层（防硬切割边）**：悬浮顶栏下方垫 `LinearGradient([Ink.paper, Ink.paper.opacity(0)], .top → .bottom)`（`12pt` 高）；悬浮底栏上方同样垫向上纸色渐隐，彻底杜绝内容滚动穿过透明玻璃边缘产生的系统硬割线。
- **内容层 (`Content Layer`)**：聊天 AI 回复、用户气泡、代码块、`RowCard`、记忆卡、设置表单 **100% 不使用真玻璃**，用纯色 `surface / surfaceSubtle` + 0.5pt `rule` + 用户气泡轻量 `glassBubble` 渐变实现 120Hz 满帧手感。

### 2. 可随时打断手势 & 键盘 1:1 帧同步
- **抽屉 (`DeskSlideHost`) 与图片缩放**：
  - 使用 UIKit `UIViewPropertyAnimator` 搭配 `UISpringTimingParameters(dampingRatio:initialVelocity:)` 管理侧栏开合进度 `fractionComplete`；当手势发生 `began` 时立刻调用 `stopAnimation(false)`，手指松开按 `UIPanGestureRecognizer.velocity` 归一注入弹簧续跑，达到真正「手指随时抢回控制权」。
- **键盘与 `ChatListViewController`**：
  - 延续现成 `keyboardSpacerView` + `CADisplayLink`（已在 `ChatListViewController` 实现），统一将 `activeKeyboardDuration` 与输入区增高同步到 `insetDisplayLink` 插值，确保键盘弹起瞬间零白缝、零跳回顶部。

### 3. W3C CLREQ 排版微距的纯渲染实现（零剪贴板污染）
- 在 `ChatProseBuilder` 构建 `NSAttributedString`（供 `CoreText` 绘制与 `UITextView` 原生选字）时，扫描 CJK（`\p{Han}`）与 ASCII/数字（`[A-Za-z0-9]`）紧邻交界处，给前一个字符附加微小 `.kern: NSNumber(value: readingSize * 0.14)`；
- 在文本段落 `NSMutableParagraphStyle` 上配置正确的中文断行边界策略与行首行尾避头尾习惯，并且 **由于 `.kern` 是属性而非字符插入，用户全选复制出来的文本依然 100% 原汁原味**（绝不出现复制到多余空格污染代码或命令的问题）。

### 4. SwiftUI 编译器友好约束（严守 `AGENTS.md`）
- 按 `AGENTS.md` Swift 5 / Xcode 26.3 坑点清单：拆分复杂 View 为独立 `private var` 子视图，避免 `unable to type-check in reasonable time`；绝不在三元表达式内放闭包；避免非隔离代码调 MainActor 静态属性；继续由 `tools/lint.py` 静态扫描阻断违规。

### 5. `Core Haptics` 语义引擎重构与录音静默守卫
- 扩展 `Haptics.swift`：
  - 将 `PressStyle(haptic:)` 默认设为 `false`；
  - 新增 `lastTickAt: CFTimeInterval` 加 `35ms` 节流防马达共振；
  - 订阅 `Voice` 录音状态，只要麦克风输入通道开启即暂停触觉播放，录音结束后无缝恢复；
- **跟底滚动状态保护 (`ChatFollowState`)**：流式输出绝不允许无条件强制 `scrollTop = bottom`；当用户主动向上浏览历史或开启长按选字时，立刻暂停自动跟底并在输入框上方亮出「↓ 回到最新（生成中）」胶囊，点按再恢复跟底锁定。
- **审批手势取消护栏 & 无障碍等效路径 (`ApproveView`)**：使用 `@GestureState`（系统手势被通知中心/来电中断时自动回弹归零）搭配 `.onChange(of: scenePhase)` 中断校验，**仅当同一活跃拖动手势在 `onEnded` 超过 `84%` 阈值且应用处于 `.active` 前台时方可执行批准**；同时保留完整 Taint/命令展示的无障碍等效点按确认按钮供 VoiceOver 与全键盘操作使用。

### 6. `FontOpticalProfile` + 无重复计算 `SafeLineBox` 单一排版引擎
- 直接替换 [Pref.swift:81](../../../App/Sources/Design/Pref.swift#L81) 与 [Ink.swift:573](../../../App/Sources/Design/Ink.swift#L573) 的旧 `leading` 算法（严禁并存两套计算引擎）：
  1. `SafeLineBox` 严格令 `lineSpacing = 0`、`maximumLineHeight = 0`、`lhOffset = 0`，普通文本行高 `= max(readingSize * contentMultiplier, ceil(ascender - descender))`，绝不对普通中文无条件叠 `+2pt fallbackSafePadPt` 或 `*0.35` 双倍行距，仅靠 `maximumLineHeight = 0` 让含 Emoji/数学分式的单行自然撑开；
  2. 将 `ChatResolvedMetrics.headingSize(level:)` 收敛至克制阶梯（H1 `21.5pt`、H2 `19pt`、H3 `17pt Semibold`、H4 `17pt Medium`），并修复 [ChatListModels.swift:300](../../../App/Sources/Reading/ChatListUIKit/ChatListModels.swift#L300) `userBody` 使 7 处阅读面字号/字体/行框比例完全同步；
  3. 收敛 `codeBlockFonts` 至 `Ink.mapleWithChinese` 单一 `1:2` 对齐方案；`ClioKai-Medium` 保留内部 `1.045×`、`0.002em`、描边粗体 `-2.2`（表格 `-1.8`）；
  4. `FontShelf` 随选字体（宋体/楷体）加载成功或阅读配置切换时递增 `fontEpoch` 全量清缓存。

### 7. Clean-Room Telegram 级流式渐显与 `ChatChromeCoordinator` / Scroll-Aware Chrome
- **Clean-Room 渐显管线（GPL-3.0 原创 Swift 实现，仅借鉴构思、零抄代码）**：
  - `ClioRevealController` 独立维护 EWMA 到词间隔（`gapEwmaAlpha = 0.4`, `velocityTau = 0.12s`, `finalizeTime = 0.28s`, `frameDtCap = 0.05s`）与图素安全计数；
  - 底层以**宽容增量块协调**（已闭合前序块保持对象恒定零重排，当前活跃选区块延迟替换）配合 CoreText 行矩形 + `CALayer` 前沿线性遮罩实现平滑推进，严格受 `Pref.fade`、`UIAccessibility.isReduceMotionEnabled`、后台退避与 `velocity > 80` 图素/秒突发直出护栏控制。
- **`ChatChromeCoordinator` 与 `UICollectionView.contentInset` 协调**：
  - 统一协调 `TopBar / ModelMenu / BottomDock / PlanCard / InlineApproval / InlineAsk / RoamSlip / JumpLatest / SelectionToolbar / PetStage / Keyboard / SafeArea` 共 12 个表面；
  - `BottomDock` 顶部配纸色 Paper Scrim + ≈92% 纸色玻璃防透字；`Scroll-Aware Chrome` 上滑历史超滞回阈值平滑收起、保留「恢复控件」与生成期「停止生成」，触碰输入/选字/审批/提问/接管/VoiceOver/程序性滚动立刻锁定为 `full` 且保持 `scrollHeight - scrollTop` 阅读锚点 `Δ = 0.0pt`。

---

## 三、独立网络兼容工程工单：Fake-IP TUN 代理环境下的 SSRF 检测冲突（单独立案，不改设计系统范围）

> **发现背景**：真机诊断发现网页检索在开启 Surge / Clash / Shadowrocket TUN Fake-IP 代理时误判阻断，经只读排查定位至 [Web.swift:753-759](../../../AgentKit/Sources/AgentKit/Web.swift#L753-L759) 与 [Web.swift:2054-2106](../../../AgentKit/Sources/AgentKit/Web.swift#L2054-L2106)。
>
> - **根因**：`LocalAddress.isLocalV4`（`Web.swift:2103`）将 RFC 2544 基准网段 `198.18.0.0/15` 列为内网禁用 IP；而在 iOS VPN/TUN Fake-IP 模式下，系统 DNS 为公网域名分配的虚构映射地址正落在 `198.18.0.0/15`。
> - **安全红线**：**绝不允许简单移除或整体放宽 SSRF 校验！** 私网（`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、`127.0.0.0/8`、`169.254.0.0/16`、`fc00::/7` 等）及 `Taint` 边界必须保持默认拦截。
> - **单列改造方向（纳入独立网络工单，不占用 UI 重构波次）**：① 明确诊断提示（识别 `198.18.0.0/15` + 检测到 utun 接口时，向用户明确解释可能为代理 Fake-IP 映射，而非泛报错）；② 由用户**显式在网络/代理高级开关中确认**或结合 DoH / 系统解析真实公网验证，仅对「高概率 Fake-IP 映射且通过外网协议校验」提供独立受控白名单策略并保留审计日志，与 SSRF 本地内网访问隔离完全分离。

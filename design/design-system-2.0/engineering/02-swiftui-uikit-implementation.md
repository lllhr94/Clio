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
- **交互浮层 (`Chrome Layer`)**：继续复用且收敛 [Ink.swift:678-704](file:///f:/work/Antigravity/Clio/App/Sources/Design/Ink.swift#L678-L704) 的 `glassFace` 与 `glassBacking`（含透明穿透触摸补丁层 `opacity(0.001)`），应用于 `ChatTopBarView`、悬浮 `ChatComposerBarView`、右下跳转圆钮与 `ApproveView` 顶部完成按钮。
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
  - 预加载 4 组 AHAP 模式（含低电量/不支持硬件时自动降级 `UIFeedbackGenerator`）。

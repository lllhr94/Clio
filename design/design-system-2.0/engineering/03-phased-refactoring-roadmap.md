# Clio DS 2.0 分阶段重构工程路线图（Phased Refactoring Roadmap · Deliverable #20）

> **执行原则**：**在当前正式设计方向获得主人确认之前，零改动生产代码**。获批后在 `batch-*` 分支按以下 5 个独立、可独立回滚的 Wave 分批合入并打包 `probe` 给主人真机验证（遵循 `AGENTS.md`「攒一批改动再编译，不每改一行跑 CI」）。

---

## Wave 1：设计 Token 基座 + 触觉纠偏 + 双语与 Lint 护栏（基础设施先行，零布局破坏）
- **改动文件**：`App/Sources/Design/Ink.swift`, `App/Sources/Design/Pref.swift`, `App/Sources/Design/Kit.swift`, `App/Sources/Haptics.swift`, `App/Sources/Design/StopPicker.swift`, `App/Sources/Tone/*.json`, `tools/lint.py`
- **交付内容**：
  1. 落盘选定视觉语言的 WCAG AA ≥ 4.5:1 全量色彩 Token（修复 `inkFaint 2.26:1 / warn 2.69:1` 等对比度问题）。
  2. 将 `PressStyle(haptic:)` 默认改为 `false`，修正 `Haptics.light()`，加入 `Selection / Success / Error / Detent` 语义与 `35ms` 拖拽节流及麦克风静音期避让；`StopRuler` 基准档位补齐圆点提示和 `detent` 触觉。
  3. 扩展 `Pref` 持久化键支持 `headingWeight / paragraphGap / readingWidth / uiDensity / hapticIntensity`。
  4. 补充 `tools/lint.py` 检查规则，确保双词典 1,075+ 键完全对等、禁止滚动 Cell 引入真玻璃。
- **验证方式**：跑 `python3 tools/lint.py` + GitHub Actions `publish=true, shots=false` 出第一个底层兼容测试包。

## Wave 2：排版与阅读引擎（`CoreText` + `ProseView` + 9 控排版页）
- **改动文件**：`App/Sources/Reading/ChatListUIKit/ChatListModels.swift`, `ChatProseRenderer.swift`, `ChatBlockViews.swift`, `ChatAssistantCell.swift`, `App/Sources/Design/LookPage.swift`, `App/Sources/Design/FontPage.swift`, `App/Sources/Design/Ink.swift`
- **交付内容**：
  1. 更新 `ChatResolvedMetrics` 的 H1–H3 阶梯尺度、段距、表格单元与代码复制完成微状态。
  2. 在 `ChatProseBuilder` 注入无剪贴板污染的 CJK–Latin `.kern` 光学字距及 W3C CLREQ 禁则调优。
  3. 升级 `ReadingSizePage` 暴露全部独立可调 `StopRow`（带真实现场 Markdown 混合预览样张）。
  4. **零破坏检查**：逐行对比流式生成至定稿瞬间高度 `delta == 0.0pt`、120Hz 向上翻页锚点无漂移。

## Wave 3：信息架构重构 & 全局统一搜索 & `CarePage` 拆解
- **改动文件**：`App/Sources/Reading/DeskSidebarView.swift`, `DeskHomeView.swift`, `Desk.swift`, `App/Sources/SettingsView.swift`, `App/Sources/Care/CarePage.swift`, 新建 `App/Sources/Reading/UnifiedSearchSheet.swift` 及拆解后的 `BackupWebDAVPage.swift` / `DiagStoragePage.swift`
- **交付内容**：
  1. 侧栏升级为 DS 2.0 统一 IA：提亮 **记忆（拾遗 1 tap 直达）**、文件与知识库（PDF 索引标牌）、工作台快达；移除首页重复顶栏圆钮。
  2. 上线 `UnifiedSearchSheet` 对接 `clio-index.db + MemoryIndexService + clio-docs-fts.db`。
  3. `SettingsView` 重组为 8+1 分组并全面统一 `NavigationStack` 右推进入；提亮密码匣/语音/生图位置；扩展双语+英文+别名关键词搜索；保持 `clio://settings/<page>` 深链全数兼容；彻底拆解 1,583 行 `CarePage`。

## Wave 4：对话与 Agent 工作流精雕（工具 / 审批 / 提问 / 用量）
- **改动文件**：`ThinkingBox.swift`, `ChatTrace.swift`, `PlanCard.swift`, `InlineAsk.swift`, `ApproveView.swift`, `InlineApproval.swift`, `ChatSources.swift`, `UsageSheet.swift`, `VoiceSettings.swift`
- **交付内容**：
  1. `ThinkingBox` 增加等宽秒数；`ChatTrace` 支持 0.36 并发只读工具清晰结构化显示与产物集合。
  2. `ApproveView` 移除硬编码 `.fontDesign(.rounded)`，应用选定设计语言的审批卡排版与对应滑轨解锁仪式，同时加复核单元测试保护 `Taint` 边界不可旁路。
  3. `InlineAsk` 优化选项分布与超限计数徽章；`SourcesSheet` 补充摘录预览；`UsageSheet` 补全用量环与状态摘要。

## Wave 5：系统表面收口、全状态无障碍自查与 60Hz/120Hz 真机回归
- **改动文件**：`StudyPage.swift`, `InteractivePreview.swift` (Zoom Hero 过渡), `DenPage.swift`, `HillsPage.swift`, `PetStage.swift`, `AlwaysOn.swift`, `TurnActivity.swift`, `docs/STATUS.md`, `docs/FEEDBACK.md`
- **交付内容**：
  1. 为照片与 `InteractivePreview` 接入 `.matchedTransitionSource` 一镜到底缩放。
  2. 按 **Deliverable #21 真机验收清单** 在实体 60Hz 与 120Hz ProMotion 设备分别实测滚动掉帧、键盘跟手、AX3 大字号、VoiceOver、减动效/减透明与 OLED，合格后由主人下令才可合入 `main`。

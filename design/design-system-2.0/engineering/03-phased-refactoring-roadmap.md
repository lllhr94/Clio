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

## Wave 2：排版引擎（`SafeLineBox` + `ClioRevealController` + 9 控排版页）
- **改动文件**：`App/Sources/Reading/ChatListUIKit/ChatListModels.swift`, `ChatProseRenderer.swift`, `ChatTextTileRenderer.swift`, `ChatBlockViews.swift`, `App/Sources/Design/LookPage.swift`, `App/Sources/Design/FontPage.swift`, `App/Sources/Design/Ink.swift`, `App/Sources/Reading/ProseView.swift`
- **交付内容**：
  1. 彻底替换旧 `Pref.leading`/`Ink.leading`，上线单源 `SafeLineBox`（`lineSpacing = 0`, `maximumLineHeight = 0`, `lhOffset = 0`）+ H1–H4 阶梯；同步修复 `userBody` 使 7 处阅读面完全一致。
  2. 上线干净增量不死循环 Markdown 解析器与 `ClioRevealController`（方案 C EWMA 渐显，受 `Pref.fade` / Reduce Motion / 后台暂停 / 突发熔断门控，选区稳态保护）。
  3. 升级 `ReadingSizePage` 暴露独立可调 `StopRow`（带真实样本预览）。
  4. **零破坏检查**：逐行对比流式生成至定稿瞬间高度 `delta == 0.0pt`、120Hz 向上翻页锚点无漂移。

## Wave 3：信息架构、`ChatChromeCoordinator`、Scroll-Aware Chrome & 全局搜索 & `CarePage` 拆解
- **改动文件**：`App/Sources/Reading/DeskSidebarView.swift`, `DeskHomeView.swift`, `Desk.swift`, `ChatPage+TopBar.swift`, `ChatPage+Chips.swift`, `ChatPage+Dock.swift`, `Team.swift`, `App/Sources/SettingsView.swift`, `App/Sources/Care/CarePage.swift`, 新建 `UnifiedSearchSheet.swift` 及拆解后的页面
- **交付内容**：
  1. 建立 `ChatChromeCoordinator` 统一协调 12 项浮层 + `Scroll-Aware Chrome`（上滑收起/9 种强锁定/「恢复控件」+生成期「停止生成」）；落地 `TopBar` 短态防溢出、`ModelChip` 缩写、底栏 Paper Scrim 抗键盘穿透与消息垂直空间压噪。
  2. 侧栏升级为 4+1（提亮记忆/书案/工作台）；上线 `UnifiedSearchSheet`（`clio-index.db + MemoryIndexService + clio-docs-fts.db`，支持中文 IME 无损输入）。
  3. `SettingsView` 重组为 8+1 分组并全面统一 `NavigationStack`；彻底拆解 `CarePage`。

## Wave 4：对话与 Agent 工作流精雕（工具 7 态 / 审批 / 提问 / 用量 & 独立 Fake-IP 工单）
- **改动文件**：`ThinkingBox.swift`, `ChatTrace.swift`, `ToolTail.swift`, `PlanCard.swift`, `InlineAsk.swift`, `ApproveView.swift`, `InlineApproval.swift`, `ChatSources.swift`, `UsageSheet.swift`, `VoiceSettings.swift` *(另立独立网络兼容工单跟进 `AgentKit/Web.swift` Fake-IP `198.18.0.0/15`)*
- **交付内容**：
  1. 修复 `ChatTrace.swift:999` 失败步显绿勾问题，严格推行 **7 态聚合语义**与运行状态 4 处去重（任务条仅突显审批/提问/接管）。
  2. `ApproveView` 移除硬编码 `.fontDesign(.rounded)`，新增 `@GestureState` + `scenePhase` 取消保护与等效无障碍确认按钮，守死 `Taint` 边界。
  3. `InlineAsk`、`SourcesSheet`、`UsageSheet` 补全精修。

## Wave 5：系统表面收口、全状态无障碍自查与 60Hz/120Hz 真机回归
- **改动文件**：`StudyPage.swift`, `InteractivePreview.swift` (Zoom Hero 过渡), `DenPage.swift`, `HillsPage.swift`, `PetStage.swift`, `AlwaysOn.swift`, `TurnActivity.swift`, `docs/STATUS.md`, `docs/FEEDBACK.md`
- **交付内容**：
  1. 为照片与 `InteractivePreview` 接入 `.matchedTransitionSource` 一镜到底缩放。
  2. 按 **Deliverable #21 真机验收清单** 在实体 60Hz 与 120Hz ProMotion 设备分别实测滚动掉帧、键盘跟手、AX3 大字号、VoiceOver、减动效/减透明与 OLED，合格后由主人下令才可合入 `main`。

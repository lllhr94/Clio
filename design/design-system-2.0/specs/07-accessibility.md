# Clio Design System 2.0：Accessibility 无障碍与全环境包容性规范（Deliverable #17）

> 兼容基准：WCAG 2.1 AA（全数自动化公式 100% 校验）· Dynamic Type AX1–AX5 · VoiceOver · Reduce Motion · Reduce Transparency · Increase Contrast · Differentiate Without Color

---

## 一、色彩与非纯色编码铁律

1. **WCAG AA ≥ 4.5:1 硬门槛**：所有阅读正文、标题、副标题、脚注（`inkTertiary`）、链接、语义提示与按钮文字对自身背景对比度 **≥ 4.5:1**；大号标题及关键控件边界图标 **≥ 3.0:1**（`verify_design_system.py` 强制自动拦截不合格组合）。
2. **Differentiate Without Color（色盲与强光可读）**：任何状态严禁单靠颜色点区分——必须做到 **「色彩 + 清晰 SF Symbol 几何形状 + 直白中文文本」三重冗余**：
   - `Taint` 外网风险：琥珀洗底 + `exclamationmark.shield.fill` + 「读过网页需确认」；
   - 工具轨迹：成功勾 (`checkmark.circle.fill`) / 失败叉 (`xmark.circle.fill`) / 未知问号 (`questionmark.circle.fill`)；
   - 终端状态点：`绿/橙/红` 同排必然紧跟「就绪 / 正在运行 / 异常」文字。

---

## 二、Dynamic Type AX1–AX5 结构化断点重排

当系统进入无障碍超大字号（`dynamicTypeSize.isAccessibilitySize`）时，组件不允许直接被压扁或省略成 `...` 截断，必须执行布局重构：

| 组件 | 默认态布局 | AX1–AX5 重排规范 |
|---|---|---|
| **`RowLabel`** | 左徽标 + 单行标题 + 右侧值/箭头 | 切换垂直堆叠：图标顶对齐，标题与说明全面 `lineLimit(nil)`，右侧数值落于标题正下方 |
| **`ChatTopBar`** | 单行左胶囊 + 右「模型｜⋯」 | 首行旅伴名与按钮，**模型切换胶囊独立换行占满二行全宽** |
| **`ApproveView`** | 单页垂直居中 + `-4°` 倾角便笺 | 取消纸张倾斜 (`0°`) 与叠底卡，启用自适应 `ScrollView` + 底部选项全竖排 |
| **`InlineAsk / InlineApproval`** | 横排多按钮或紧凑芯片 | `ViewThatFits` 自动切单列竖排按钮，每项高度始终 `≥ 44pt` |
| **`StopRuler`** | 单卡展示完整刻度 | 嵌套 `ScrollView` 限制最大高度并放开档位名称换行空间；支持 VoiceOver 上下扫动 `.accessibilityAdjustableAction` |

---

## 三、VoiceOver · 减动效 · 减透明 · 增对比四重兜底

1. **VoiceOver 可达性**：
   - 所有纯图标按钮强制配置简明中文 `.accessibilityLabel`，如「打开全局搜索」「复制代码」「展开思考过程」；装饰性元素（`ClioSeal`、`IconBadge`、分割线）一律 `.accessibilityHidden(true)`；
   - UIKit `ChatTextTileRenderer` 异步位图瓦片必须持续维持 PR #93 已验证的 **无障碍元素代理与自定义动作**（读正文、点链接、复制、引用追问、朗读）。
   - 小克宠物播报当前真实工作状态与全部手势提示（「点一下逗它，左右滑改位置，长按设大小或暂躲」）。
2. **`Reduce Motion`**：停用弹簧过冲、停用宠物落地挤压与闲逛、关闭呼吸光晕脉动与纸片飞出动画，切为 `≤ 150ms` 纯透明切换。
3. **`Reduce Transparency`**：全部 `.glassEffect` 自动切为 98% 不透明 `surfaceElevated` + `1pt rule` 实框；方向 C 状态光氛切换 `1.5pt` 顶部实色状态线。
4. **`Increase Contrast`**：分割线与卡片边界升至 `1pt`，三阶灰字 `inkTertiary` 自动提级至 `inkSecondary`（≥ 7:1）。

---

## 四、审批手势安全与无障碍等效确认规范（ChatGPT 复审 P0 + P1）

1. **手势取消绝不批准（P0 防误批准底线）**：
   - 审批滑动轨道（无论是原型 `bindSlideTrack` 还是 Swift [ApproveView.swift](../../../App/Sources/ApproveView.swift) `DragGesture`）**严禁共用 `onEnded` 与取消/中断回调**：
     - 仅当**用户同一活跃触点主动抬起松手 (`pointerup` / `DragGesture.onEnded`) 且位移超过 `84%` 阈值**才可执行批准落款；
     - `pointercancel`、iOS 来电/通知中心打断、`@GestureState` 自动复位、`scenePhase != .active`（退后台/锁屏/切走焦点）一律强制安全回弹至起点，**绝对不得标记为允许**。
2. **滑动不可作为唯一确认路径（P1 无障碍等效确认）**：
   - `ApproveView` 必须同时提供可聚焦、可点击、标签清晰的无障碍等效确认按钮（**「确认并落款批准」**，支持 VoiceOver 激活、Switch Control、全键盘控制及减弱动态效果场景）；
   - 该按钮与滑动确认共用同一安全校验证明流水线：**完整命令预览、`Taint` 外网风险横幅、`forced == true` 限制同样 100% 展示与约束，绝不提供绕过安全审计的一键跳过**。

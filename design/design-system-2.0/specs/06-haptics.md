# Clio Design System 2.0：Haptics & Audio-Haptic 触觉反馈规范（Deliverable #16）

> **权威依据**：**Apple HIG Playing Haptics + Core Haptics WWDC21 10278** · **任务书第十五节语义标准** · **OPPO O-Haptics / CapWords / Darkroom / Cindy** 克制哲学。
> **现状批判**：`batch-0.36` 的 [Haptics.swift](file:///f:/work/Antigravity/Clio/App/Sources/Haptics.swift) 与 [Ink.swift:652](file:///f:/work/Antigravity/Clio/App/Sources/Design/Ink.swift#L652) 让 `PressStyle(haptic: true)` 默认每次点按钮都震（且 `Haptics.light()` 错用 `.medium 0.8` 强度）。DS 2.0 将其彻底纠偏为 **「普通按钮默认静默，只把震动留给高语义操作与品牌时刻」**！

---

## 一、统一触觉语义映射表（严格落实任务书第十五节）

| 交互场景 | DS 2.0 指定触觉原语 | 底层参数与实现建议 (SwiftUI / UIKit / Core Haptics) |
|---|---|---|
| **1. 普通按钮点击**（返回、关闭、`⋯` 菜单项、一般列表行、`PressStyle` 默认） | **`默认无` (`none`)** | 将 `PressStyle.haptic` 默认值从 `true` 改为 **`false`**，终结全局手麻问题（仅少数核心主按钮如「发送」显式触发） |
| **2. 模型切换** | **`Selection`** | `UISelectionFeedbackGenerator().selectionChanged()` |
| **3. 思考档位切换** | **`Selection`** | `UISelectionFeedbackGenerator().selectionChanged()` |
| **4. 发送消息** | **`Light`** | `UIImpactFeedbackGenerator(.light, intensity: 0.65 * scale)` *(现纠偏：不再错用 `.medium 0.8`)* |
| **5. 展开工具卡片 (`Trace / PlanCard / Thinking`)** | **可选极轻反馈** (`Optional Soft-Light`) | 默认静默或极轻 `intensity 0.35`（在长文展开阅读中不喧宾夺主） |
| **6. 批准执行 (`InlineApproval / ApproveView`)** | **`Medium` 或品牌专属 AHAP** | **方向 A**：招牌三段 `sealStamp` AHAP `thud()`；<br>**方向 B**：12.5% `tick` 棘轮 + 终点 `lock` 咬合；<br>**方向 C**：温和渐起释放波 |
| **7. 重要任务完成**（长后台 Agent 跑完、备份生成/恢复成功） | **`Success`** *(或专属轻量完成 AHAP)* | `UINotificationFeedbackGenerator().notificationOccurred(.success)`（**仅用户当前注视或前台收尾关键任务时触发**） |
| **8. 重要任务失败 / 安全阻断**（`Taint` 拦截、API 报错、命令失败） | **`Error` / `Warning`** | `UINotificationFeedbackGenerator().notificationOccurred(.error)` |
| **9. 侧边栏拖动 / `StopRuler` 刻度拖拽** | **阈值吸附反馈 (`Snap Detent`)** | 侧栏越过 `0.45` 开启/关闭阈值或 `StopRuler` 划过「推荐基准值（`1.0×` / `17pt` / `1.65×`）」给一记清晰 `detent` 吸合；其余刻度给极细 `tick` + **≥ 35ms 节流** |
| **10. 宠物点击 / 戳醒 / 松手落地 (`PetStage`)** | **自定义轻触觉 (`petWake / petLand`)** | `CHHapticPattern` 极短柔和敲击 (`sharpness 0.25–0.45, intensity 0.45`) + 松手落地跟随压缩关键帧精准对齐 |
| **11. 删除或归档** | **按危险/可逆度分级** | 可逆 4 秒撤销的普通归档：`无` 或轻 `Selection`；不可撤销的清空对话 / 永久删除密钥：确认动作触发 `Warning / Medium` |

---

## 二、Core Haptics 专属标志性交互（4 个品牌级 AHAP 图谱规划）

> 严格声明：`CoreHaptics` AHAP 波形参数系基于 `Haptics.swift` 现有 `thud()` 与 WWDC21 `10278` 规范设计，真机 Taptic Engine 实际物理响度与音色共振属于 `[待真机实录补全]`，须经真机验证微调后方可定稿。

1. **`clio-seal-stamp.ahap`（朱印盖章，方向 A 核心）**：
   - `t=0.000s`: Transient (`intensity 0.95, sharpness 0.25`) — 印章刚着纸闷响
   - `t=0.000–0.140s`: Continuous (`intensity 0.80, sharpness 0.12`) — 用力按下纸毡阻尼感
   - `t=0.125s`: Transient (`intensity 0.72, sharpness 0.65`) — 提章瞬间清脆回弹 *(并可同步匹配一声极克制的短促纸墨木章轻音效)*
2. **`clio-pet-wake.ahap`（小克被戳醒/互动）**：
   - `t=0.000s`: Transient (`intensity 0.42, sharpness 0.30`)
   - `t=0.075s`: Transient (`intensity 0.55, sharpness 0.52`) — 形成一只小像素猫惊醒轻跳的双连微震，严格控制在 `0.6` 强度以内绝不吓人。
3. **`clio-task-complete.ahap`（高价值复杂任务交付）**：
   - 仅长多步 Agent 成功完成交付时播：上扬两阶柔和轻点（`0.45 → 0.70`），节奏明快愉悦（参考 Duolingo/CapWords 适度正反馈但去掉浮夸音效）。
4. **`clio-snap-detent.ahap`（侧栏与 `StopRuler` 基准点吸合）**：
   - `t=0.000s`: 单脉冲 Crisp Transient (`intensity 0.68, sharpness 0.78`)，与视觉弹簧撞击基准刻度的第 1 帧严格对齐。

---

## 三、视听触同步与「六不震红线」

- **Audio–Haptic 同步（WWDC21 Session 10278）**：若未来主人开启可选极克制交互音效（如盖章纸声、小克轻鸣），音频缓冲区与 `CHHapticEvent` 必须共用 `AVAudioEngine / CHHapticEngine` 同一条时间轴启动，误差控制 `< 15ms`；静音拨片或未开启声音时只走纯静音 Taptic。
- **6 条绝对不震红线（No-Vibration Redlines）**：
  1. **普通导航/设置/列表按钮默认不震**；
  2. **流式出字（每个 Token/每行输出）绝对不震**；
  3. **日常聊天列表滚动与小地图高速拖拽越界之外不连续轰震**；
  4. **后台静默执行的定时/记忆整理每步工具日志不震**；
  5. **连续高频率触发间隔必须 `≥ 35ms` 节流防浑浊嗡鸣**；
  6. **严禁用震动替代必需的视觉与无障碍提示**。
- **独立系统边界与语音避让**：提供独立设置的「触觉关闭 / 强度（关·轻柔·标准·清脆）」；遵循 **Apple HIG Playing Haptics 硬规范**：当 `Voice.swift` 处于麦克风连续录音/口述听写状态时，**自动静默挂起普通震动反馈**，防止马达物理震动灌入麦克风拾音失真。

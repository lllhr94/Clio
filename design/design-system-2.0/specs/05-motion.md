# Clio Design System 2.0：Motion & Interruptibility 物理动效规范（Deliverable #15）

> 参考体系：**Apple WWDC23 Session 10158 (`Animate with springs`) + Apple HIG Motion** · **OPPO ColorOS 极光引擎并行可打断** · **华为 HarmonyOS 空间一镜到底** · **vivo OriginOS 物理阻尼跟手性** · **Ant Design Motion（自然/高效/克制，退场快于进场）**。

---

## 一、四档官方 Motion Token 与精确弹簧物理参数（对齐任务书第十四节）

不仅设定参考时间窗口，更独立定义 **响应时间 `response` · 阻尼比 `dampingFraction` · 过冲率 `overshoot` · 速度继承倍率 `initialVelocityScale`**（全部数值写入 `tokens.v2.json`）：

| Motion Token 档位 | 目标时长窗口 | 核心用途 | 方向 A（素笺 2.0）参数 | 方向 B（清器）参数 | 方向 C（栖息）参数 |
|---|---|---|---|---|---|
| **`Motion.instant`** | **80–120 ms** | 按压缩放(`0.97`)、切换开关、复制 `✓`、图标切态 | `0.10s` (`resp 0.18, damp 0.88, overshoot ~1.2%`) | **`0.09s`** (`resp 0.14, damp 0.94, overshoot ~0.3%`) | `0.11s` (`resp 0.20, damp 0.84, overshoot ~1.8%`) |
| **`Motion.quick`** | **150–220 ms** | 悬浮菜单弹出、Thinking/Trace 折叠、Chip 状态滑移、轻量卡片消失 *(退场不慢于入场)* | `0.19s` (`resp 0.26, damp 0.85, overshoot ~2.0%`) | **`0.16s`** (`resp 0.21, damp 0.90, overshoot ~0.8%`) | `0.21s` (`resp 0.29, damp 0.80, overshoot ~3.0%`) |
| **`Motion.standard`** | **250–350 ms** | 侧栏抽屉开合、Push 页面转场、PlanCard 裁剪展开、Sheet 底板弹出 | `0.31s` (`resp 0.36, damp 0.84, overshoot ~2.5%`) | **`0.26s`** (`resp 0.27, damp 0.89, overshoot ~1.0%`) | `0.34s` (`resp 0.42, damp 0.79, overshoot ~3.5%`) |
| **`Motion.expressive`** | **400–600 ms** | 宠物松手落地挤压回弹 (`PetStage`)、朱印「克」砸纸定格 (`ApproveView`)、低频高价值仪式 | `0.48s` (`resp 0.48, damp 0.72, overshoot ~6.0%`) | **`0.42s`** (`resp 0.40, damp 0.82, overshoot ~3.0%`) | `0.54s` (`resp 0.54, damp 0.70, overshoot ~6.5%`) |

---

## 二、7 大不可妥协物理互动工程铁律

1. **全链路随时可打断与手势接管（Interruptibility）**：
   - **绝不允许**任何动效阻塞点击、输入、滚动或反向拖拽。侧栏滑出/关闭、图片 Hero 缩放、审批条滑动、`PlanCard` 展开到任意百分比时，手指一旦触碰即通过 `UIViewPropertyAnimator.pauseAnimation()` 或 SwiftUI `.spring` 状态重目标化直接按当前物理位置与瞬时状态反向接管（零闪现归位跳变）。
2. **手指离手速度继承（Velocity Preservation）**：
   - 用户快速一划侧栏或快速挥动浏览图片，必须将手指释放瞬间的手势速度换算成归一化 `CGVector` 初速度注入 `UISpringTimingParameters(mass:stiffness:damping:initialVelocity:)`，让界面依惯性丝滑飞入终态，杜绝“快速甩手却突然均速慢滑”。
3. **并行独立动画（Parallel Animation）**：
   - 如点击聊天通知条切换会话、关闭侧栏的同时唤醒输入框，多个关联属性动画并行异步推进，禁止串行队列“关完一个再等下一个打开”（Ant Design Motion：退场必须干脆同步且快于进场）。
4. **动画中途异常状态恢复（State Recovery）**：
   - 当网络出错、审批被他处处理（`ApproveView.onChange(of: team.approvals)`）或用户突然取消长任务时，正在展开或脉冲中的控件能在 180ms 内稳定退回合法静置态，不悬停在半中间残破状态。
5. **流式正文零动画与稳定布局（Streaming Stability）**：
   - `ThinkingBox` 与 `ChatTextTileRenderer` 流式增量渲染期间**严禁施加任何 text cross-dissolve / Fade 叠加动画**（实测教训：会导致文字三层重影和主线程掉帧），保持 `.transaction { $0.animation = nil }`；列表新消息追加、删除、历史向上分页采用确定性预测量行高 + `anchor` 锁定（上滑拉取历史 `viewport Δ = 0.0pt`）。
6. **键盘 ↔ 输入框 ↔ 小克严格帧同步**：
   - `ChatListViewController` 维持 `keyboardSpacerView` + `CADisplayLink` 精确追踪系统键盘弹窗与交互下滑轨迹，保证键盘动作期间最后一条回复、输入框顶沿与立于其上的 `PetStage` 三者同步升降、0 错位、0 穿模。
7. **一镜到底空间连续性 (`Spatial Continuity`)**：
   - 聊天中点击大图或互动 HTML 预览卡打开全屏查看器时，优先采用 iOS 26 原生 `.matchedTransitionSource(id:in:)` + `.navigationTransition(.zoom)`，关闭时精准缩回原卡片位置。

---

## 三、`Reduce Motion` 强制无条件降级规范

当检测到 `@Environment(\.accessibilityReduceMotion) == true` 时：
- 禁用所有弹簧过冲与位移弹跳（`PetStage` 停止随机巡游与落地压缩；`ApproveView` 纸片停止倾斜及飞出）；
- 全部状态切换与页面淡变收敛为 `≤ 150ms` 纯 `.opacity` 淡入淡出或直接瞬切，确保眩晕敏感人群 0 负担使用。
- 界面退出前台 (`scenePhase != .active`) 时立刻停掉所有 `CADisplayLink` / `KeyframeAnimator` / 连续循环脉冲。

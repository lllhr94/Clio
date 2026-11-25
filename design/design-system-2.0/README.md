# Clio Design System 2.0：全量 21 项交付物索引（Master Delivery Pack）

> **遵守底线**：当前阶段零生产代码改动（`git diff --name-only` 严守为空），所有研究、审计、信息架构、设计规范、工程落地方案及交互原型全部沉淀于 `design/design-system-2.0/`；等待正式设计方向获批后再分波推进 `batch-*` PR。

---

## 一、全量 21 项官方交付物地图（一一对应任务书第二十一节）

| # | 官方交付物要求 | 对应交付文件路径 / 在线交互地址 | 核心完成摘要 |
|---|---|---|---|
| **1** | **全球竞品研究报告** | [`01-china-indie-craft.md`](./research/01-china-indie-craft.md)<br>[`02-china-ai-productivity.md`](./research/02-china-ai-productivity.md)<br>[`03-mobile-os-systems.md`](./research/03-mobile-os-systems.md)<br>[`04-international-benchmarks.md`](./research/04-international-benchmarks.md)<br>[`05-matrix-and-clio-mapping.md`](./research/05-matrix-and-clio-mapping.md)<br>[`06-extended-global-china-and-standards.md`](./research/06-extended-global-china-and-standards.md) | 覆盖全球+中国独立+国产AI+国际AI+4家OS+Apple HIG/W3C CLREQ+20大Clio专项对标矩阵；含独立研究卡与借鉴/禁忌对照。 |
| **2** | **竞品截图与交互证据库** | [`research/00-evidence-audit-log.md`](./research/00-evidence-audit-log.md) | 严格执行 1–7 级证据分级标准，记录 50+ 宿主实测核验网址、ADA 奖项纠偏及超时/屏蔽如实台账，杜绝假证。 |
| **3** | **现有 UI 全量审计报告** | [`audit/01-current-ui-audit.md`](./audit/01-current-ui-audit.md) | 基于 `batch-0.36` 全量 179 个 Swift 文件：实测 `Ink` 对比度硬伤 (`2.26:1`)、`Haptics` 过度震动、聊天 20 要素审计与 6 大结构痛点。 |
| **4** | **功能地图** | [`audit/02-feature-inventory-map.md`](./audit/02-feature-inventory-map.md) | 全量能力严格切分：`L1 一级能力` vs `全局设置` vs `单会话局部选项` vs `系统集成表面`。 |
| **5** | **信息架构及导航结构** | [`ia/01-information-architecture-and-navigation.md`](./ia/01-information-architecture-and-navigation.md) | 批判审校第十节候选侧栏，提出 4+1 紧凑侧栏、统一全局检索（对话+记忆+PDF）与书卷称谓旁注策略。 |
| **6** | **设置分类树** | [`ia/02-settings-taxonomy.md`](./ia/02-settings-taxonomy.md) | 对比现状 6 组与候选 9 组，定案 **8+1** 全 `Push` 一致分类树、拆解 1583 行 `CarePage`、提亮记忆/语音/密码匣。 |
| **7** | **用户操作路径分析** | [`ia/03-user-flows-and-click-paths.md`](./ia/03-user-flows-and-click-paths.md) | API 配置、调行距、SSH 公钥、关记忆（`4→1 tap`）、权限、`WebDAV` 恢复、聊天换模型、全局搜索 8 大路径量化前后对比。 |
| **8** | **视觉方向提案与正式定稿** | [`languages/06-three-design-languages.md`](./languages/06-three-design-languages.md) | 对候选色板做 WCAG 校验，并经确认定稿为 **`AC`（素笺·栖息 / A 骨 + C 韵 + B 序）**，双头牌色盘（素笺黛蓝/栖息松绿）。 |
| **9** | **全页面高保真原型 (v15 收口)** | **Magpie 实机互动页 (`http://127.0.0.1:3425/a/pfrmwhcemcbess5bh7jvjcvisa/`)**<br>[`prototype/index.html`](./prototype/index.html) &amp; [`app.js`](./prototype/app.js) | **P0/P1 真机基线回归 & 选区保护流式收口**：直载仓库 `App/Fonts/*.ttf`、统一无重复 `SafeLineBox` + 用户气泡同步、顶栏缩写、输入栏防透字、`ChatChromeCoordinator` + Scroll-Aware Chrome、工具 7 态语义、原位定稿/停止选区不销毁及延迟补交（通过 [`test_prototype_behavior.mjs`](./scripts/test_prototype_behavior.mjs) 14/14 行为套组与 [`test_prototype_browser_e2e.mjs`](./scripts/test_prototype_browser_e2e.mjs) 6/6 Chrome E2E 实测）。 |
| **10** | **可交互的动效原型** | 同上，选择分组 **「动效与触觉实验室」**（`scene=motion_lab`） | 交互实测 **4 档弹簧阶梯**、**手势可打断**、**键盘锚点**、**Haptics 监视器**，以及 **⑤ Telegram 级流式揭示 A / B / C 同源对照实验室**（含 6 路 Trace、原版参数 `finalizeTime=0.30s` & `200ms` 渐显与零重建验证）。 |
| **11** | **Typography System** | [`specs/01-typography.md`](./specs/01-typography.md) | **W3C CLREQ** 禁则/挤压/混排规则 + 全 18 类 Markdown 度量矩阵（H1–H3/Code/Table）+ **9 项独立排版控制**。 |
| **12** | **Color System** | [`specs/02-color.md`](./specs/02-color.md) + [`specs/tokens.v2.json`](./specs/tokens.v2.json) | 全语义色阶表 + **117 组 Light/Dark/OLED 自动化校验 ≥ 4.5:1** + Liquid Glass 仅限 Chrome 红线。 |
| **13** | **Spacing &amp; Layout System** | [`specs/03-layout.md`](./specs/03-layout.md) | `4/8/12/16/24/32pt` 栅格、`18–24pt` 页边距、同心圆角、≥`44×44pt` 不可缩放热区、SE~iPad 断点与宠物位置红线。 |
| **14** | **Component Library** | [`specs/04-component.md`](./specs/04-component.md) | 覆盖 **通用组件 + 图标语言 + 插画宠物规范 + 全量 8 态统一契约**。 |
| **15** | **Motion Design System** | [`specs/05-motion.md`](./specs/05-motion.md) | **Instant(80-120ms)/Quick(150-220ms)/Standard(250-350ms)/Expressive(400-600ms)** 物理参数、可打断、速度继承与防闪。 |
| **16** | **Haptics Design System** | [`specs/06-haptics.md`](./specs/06-haptics.md) | **普通按钮默认不震**；11 场景完整语义映射 + 4 套专属 AHAP 图谱 + 视听触同步与听写期间强制静默保护。 |
| **17** | **Accessibility 规范** | [`specs/07-accessibility.md`](./specs/07-accessibility.md) | WCAG AA + AX1–AX5 结构化重排 + VoiceOver + 减动效/减透明/增对比与三重状态防色盲编码。 |
| **18** | **组件与源码映射表** | [`engineering/01-component-source-mapping.md`](./engineering/01-component-source-mapping.md) | DS 2.0 每个 Token 与模块 1:1 映射 `App/Sources/**/*.swift` 真实文件路径与结构体名称。 |
| **19** | **SwiftUI/UIKit 实现方案** | [`engineering/02-swiftui-uikit-implementation.md`](./engineering/02-swiftui-uikit-implementation.md)<br>[`engineering/05-telegram-porting-and-private-network.md`](./engineering/05-telegram-porting-and-private-network.md) | 保护 `batch-0.36` 全量底层护城河；补充 **Telegram `24638bc` 原版核心源码复用路线、许可证核查、5 列模块依赖表、`Points` 揭示成本 Model 与私人网络/Fake-IP 统一安全架构**。 |
| **20** | **分阶段重构路线图** | [`engineering/03-phased-refactoring-roadmap.md`](./engineering/03-phased-refactoring-roadmap.md) | 5 Wave 递进合入计划（Token → 阅读 → IA/搜索/Care拆解 → Agent/审批 → 动效真机验收）。 |
| **21** | **真机测试与设计验收清单** | [`engineering/04-device-qa-and-acceptance-rubric.md`](./engineering/04-device-qa-and-acceptance-rubric.md) | 任务书 20-20-15-15-15-5-5-5 加权验收表 + **11 项一票否决项** + 60Hz vs 120Hz ProMotion 双机实测流程。 |

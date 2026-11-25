# 全量竞品设计矩阵与 Clio 真实组件映射总表

> **文档目标**
> 1. 汇总全部 **49 个研究对象**（17 款中国区独立美学/阅读/效率产品 + 9 款国内 AI 与生产力应用 + 5 套手机 OS 与宿主规范 + 18 款国际标杆，外加 8 款海外 AI 客户端基线对照）的**三层分级总榜**与**12 维度对比矩阵**。
> 2. 将竞品底层设计原则逐项映射至 Clio `batch-0.36` 真实代码文件与 SwiftUI/UIKit 组件（覆盖 10 大核心域），并给出精确工程落地约束。
> 3. 明确列出 **反拼凑守卫（Design Synthesis Guardrails）**，防止把互相冲突的视觉、交互或性能要素硬塞进同一套产品。

---

## 一、三层证据分级总榜（核验后全量清单）

### A. 🏆 官方获奖产品（22 项）
*(经 `https://developer.apple.com/design/awards/` 2024–2026 实时页面及 `search_web` 逐项核验官方归档；含 Apple Design Awards、App Store Awards / 年度精选、Google Play 年度奖、Red Dot / iF；并已将实测查证未列 2024–2026 ADA 的 **Finch** 调回 B 类参考)*

| 类别 | 产品 / 系统 | 核验奖项与年份 |
|---|---|---|

*(完整 A/B/C 分级如下。)*

---

## 零、Clio 20 大专项模块对标矩阵（对齐任务书第七节）

| Clio 模块 | 优先标杆矩阵（经跨区扩库更新） | Clio DS 2.0 对应关键落地决策 |
|---|---|---|
| **1. 整体视觉** | Craft、Claude、潮汐、Bear、Linear *(Refresh)* | 三套原创方向（素笺 2.0 / 清器 / 栖息）均拒绝堆卡片，建立统一表面与 WCAG AA 对比度阶梯 |
| **2. 聊天页面** | Claude、ChatGPT、Raycast、Kimi | 内容占绝对C位；悬浮 Glass 只在顶底栏，滚动正文零实时玻璃 + 渐隐防割线 |
| **3. 中文正文** | 微信读书、Cubox、iDaily、**W3C CLREQ** | UIKit `CoreText` 注入防污染 `.kern` 中西视距 + CLREQ 避头尾 + 标点挤压 + 无卡片长文流 |
| **4. Markdown** | Bear、Craft、Typora | 18 类全元素统一度量（H1 22–24 / H2 19–20 / H3 17–18 / Code 13–14 / Table 14–15 pt）+ 流式定稿零闪跳 |
| **5. 输入框** | ChatGPT、Raycast、Claude、豆包 | 底部悬浮胶囊、长贴自动文件化、编辑/引用状态明确色条、集成录音波动与发送策略 |
| **6. 侧边栏** | Linear、Things 3、Claude | 减弱侧栏喧宾夺主感；顶放统一全域搜索、提亮记忆 L1、收敛工作台、保留随时打断手势 |
| **7. 设置分类** | iOS 设置、Raycast、Telegram、Obsidian | 现有 6 组重组为 8+1 清晰目录；统一 NavigationStack Push 跳转；中英别名秒查；拆解 1,583 行 Care |
| **8. 模型管理** | Raycast、Cherry Studio、Chatbox、openhanako | 区分「默认/备用/整理/生图」角色分配；支持不离开聊天的顶栏即时切模型与探测思考档 |
| **9. 功能导航** | Raycast、Linear、飞书 | 一级能力 vs 全局设置 vs 单会话选项严格边界，消除首页右上重复圆钮 |
| **10. Agent 执行** | Manus、Kimi、Codex、Claude Code、Flighty | 并发只读工具清晰结构化轨迹（非死板日志堆叠）+ 思考 3 行固定窗带秒数 + `PlanReveal` 裁剪展开 |
| **11. 权限审批** | iOS 系统权限、Raycast、Claude Code、飞书 Card 2.0 | 严防审批疲劳：高危外网 `Taint` 三重强制警告不可绕过 + 结构化左标签右等宽核查 |
| **12. 记忆系统** | flomo、Day One、Cubox、openhanako | 提亮至侧栏 1 tap 管理四层，清晰标记「AI 写入 vs 手写」，结合 `UnifiedSearch` 全局搜索 |
| **13. 文件与知识库** | Craft、Obsidian、Cubox、ima | 显示外部挂载授权与 0.36 PDF/文档 FTS5 入库态；支持 `.navigationTransition(.zoom)` |
| **14. 浏览器** | Arc Search、Cubox | `RoamChrome` 手交卡片提示清晰，不抢聊天重心；从工作台亦可预登录站点 |
| **15. 语音交互** | ChatGPT、豆包、Pi | 明确本地 vs 云端 STT 独立设置页、语音录入动画、且录音期间**物理强制静默震动** |
| **16. 数据统计** | Flighty、OffScreen、Apple 健康 | 大字指标 + 进度环 + 缓存命中人话解说（替换冷冰冰表格与混乱杂糅 CarePage） |
| **17. 宠物与陪伴** | Finch、CapWords、Gentler Streak、谜底时钟 | 唯一宠物包角色、禁止羞辱或体力打卡 PUA、严格贴输入框顶沿水平滑并避让按钮 |
| **18. 原生操作手感** | Things 3、Reeder、Apple HIG | SwiftUI + UIKit `UICollectionView` 混合极速，全量 `.continuous` 同心圆角与 44×44pt 热区 |
| **19. 物理动效** | OriginOS、HarmonyOS、Not Boring、Ant Design Motion、WWDC23 `10158` | 4 级 (`Instant/Quick/Standard/Expressive`) 精确弹簧参数 + 处处手势可打断 + 退场快于进场 |
| **20. 触觉反馈** | CapWords、Blackbox、Not Boring、Darkroom、Apple HIG | **普通按钮默认静默**；只为切模型(`Selection`)/发送(`Light`)/审批(`thud`/AHAP)/基准吸合(`detent`)/任务成功(`Success`)发声 |

### A. 🏆 补充核正表（接上文清单）
| 类别 | 产品 / 系统 | 核验奖项与年份 |
|---|---|---|
| 中国独立/生活 | **CapWords** | 2025 Apple Design Awards Winner（*Delight and Fun*，实测核验）+ 2025 App Store Awards 中国大陆年度 App |
| 中国独立/工具 | **谜底时钟 (MD Clock)** | 2022 Apple Design Awards「Visuals and Graphics」入围 (Finalist) |
| 中国独立/身心 | **潮汐 (Tide)** | 2016、2017 App Store 年度精选；2025 App Store Awards 中国大陆年度 App 入围 |
| 中国独立/阅读 | **微信读书** | 2017 App Store 年度精选（「为知识付费」趋势专题） |
| 中国独立/生活 | **iMuseum** | 2014 中国 App Store 年度精选 |
| 中国独立/记录 | **格志日记** *(跨平台主奖)* | 2020 Google Play 年度最具突破力应用（注：Apple 生态为编辑推荐，无 ADA / App Store 年度主奖） |
| 国产 OS 体系 | **华为 HarmonyOS Design** | 多次获德国 Red Dot 红点奖与 iF Design Award；官方完整设计规范发布 |
| 国产 OS 体系 | **OPPO ColorOS (水生设计)** | 多次获 Red Dot 红点奖与 iF Design Award |
| 国产 OS 体系 | **小米澎湃 OS (MiSans/Alive)** | MiSans 获 2019 Red Dot 与 2023 iF Design Award |
| 国际标杆 | **Bear** | 2016 Mac App of the Year；2017 Apple Design Award 获奖 |
| 国际标杆 | **Day One** | 2012 Mac App of the Year；2014 Apple Design Award 获奖 |
| 国际标杆 | **Ulysses** | 2016 Apple Design Award 获奖；多届 Mac App of the Year 提名/精选 |
| 国际标杆 | **Structured** | 2025 App Store Award Finalist (iPad App)；**2026 Apple Design Award Finalist（*Inclusivity*，实测官网核正）** |
| 国际标杆 | **Duolingo** | 2023 Apple Design Award 获奖 (Delight and Fun) |
| 国际标杆 | **Headspace** | 2023 Apple Design Award 获奖 (Social Impact) |
| 国际标杆 | **Endel** | 2020 Apple Watch App of the Year |
| 国际标杆 | **Portal** | 2023 App of the Year 入围 (Finalist)；App Store Editors' Choice |
| 国际标杆 | **Darkroom** | 2020 Apple Design Award 获奖 |
| 国际标杆 | **Fantastical** | 2015 Apple Design Award 获奖；Mac App of the Year |
| 国际标杆(补) | **Things 3** | 2017 Apple Design Award 获奖 |
| 国际标杆(补) | **Flighty** | 2023 Apple Design Award 获奖 (Interaction) |
| 国际标杆(补) | **Gentler Streak** | 2024 Apple Design Award Winner（*Social Impact*，实测核验；同团队 *The Outsiders* 入围 2026 ADA） |
| 国际标杆(补) | **Not Boring Habits (Andy Works)** | 2022 Apple Design Award 获奖（同系 *Camera* 入围 2026 ADA，实测核验） |

*(注：计格志日记为跨平台官方主奖则官方获奖项合计 23 项，仅计 Apple + Red Dot / iF 则为 22 项。)*

### B. 📐 业内设计参考（22 项 + 8 款国外 AI 客户端基线）
*(无 Apple ADA / App Store 年度主奖直接获奖核验记录，但具备官方开发者规范、设计团队深度公开复盘、或业内公认排版/交互/架构标杆)*
- **中国独立/阅读/效率**：小宇宙、OffScreen、flomo、iDaily、滴答清单、轻芒杂志（历史案例）、Cubox（补充）、锤子便签（历史案例，补充）
- **中国 AI 与生产力**：豆包、Kimi、Manus、DeepSeek、秘塔 AI 搜索、飞书 (Universe Design)、语雀（补充）
- **操作系统规范**：vivo OriginOS（开放平台规范）、Apple iOS 26 HIG & Liquid Glass（宿主基线）
- **国际标杆**：**Finch**（实测 `developer.apple.com/design/awards/` 2024–2026 未入围 ADA，调正为健康伴读设计参考）、Stoic（App Store Editors' Choice）、Reeder（无 ADA；作者 Silvio Rizzi *Mela* 实测入围 2025 ADA）、Linear Mobile
- **国外 AI 客户端基线**：Claude iOS、ChatGPT iOS、Perplexity iOS、Open Minis、HanaAgent、DSH Go、Cindy、Kelivo

### C. ✨ 主观审美与体验推荐（5 项）
*(无官方设计大奖核验记录，偏特定情绪调性、克制态度或拟物触觉探索)*
- 即刻、有知有行、谜底黑胶（补充）、ima (腾讯 ima.copilot)、夸克 AI 搜索（补充）

---

## 二、全量竞品 12 维度对比矩阵（核心指标速览）

> 图例：`★` 核心突出优势；`●` 稳健达标；`○` 一般/克制；`△` 存在明显短板或风险（需 Clio 引以为戒）

| 产品 / 系统 | 中文排版 | 信息密度 | 布局对齐 | 视觉层级 | 一致性 | 原生交互 | 微动效 | 触觉 | 动画打断 | 跟手性 | 无障碍 | 120Hz性能 | 最核心流程亮点 / 反面警示 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **CapWords** | ● | 低 | ● | ★ | ★ | ★ | ★ | ★ | ● | ● | ○ | ★ | 实景物体撕贴纸一步直达；Clio 借鉴物态反馈，不照搬游戏化 |
| **谜底时钟** | ○ | 极低 | ★ | ★ | ★ | ★ | ★ | ★ | ● | ● | ○ | ★ | 等宽数字稳固与低功耗静置；不照搬厚重金属反光拟物 |
| **潮汐** | ● | 极低 | ● | ○ | ★ | ★ | ★ | ★ | ● | ● | △ | ○ | 防误触长按蓄力停、自然渐隐；**警惕白字叠浅渐变对比度跌破 AA** |
| **微信读书** | ★ | 中 | ★ | ★ | ★ | ★ | ● | ● | ★ | ★ | ★ | ★ | 中西混排微距、标点挤压、选字原位工具栏；不照搬社交排名红点 |
| **iMuseum** | ★ | 低 | ★ | ★ | ★ | ● | ○ | ○ | ● | ● | ○ | ● | 衬线标题+发丝线杂志秩序；不照搬大图占用过多首屏空间 |
| **格志日记** | ● | 中(结构) | ★ | ● | ★ | ● | ○ | ○ | ● | ● | ★ | ★ | 填格引导消除空白页焦虑；不照搬死板九宫格硬切文本 |
| **小宇宙** | ★ | 中 | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ● | ★ | 精确到点的时间戳跳转、迷你条上拉全屏；不照搬社区热评喧闹 |
| **OffScreen** | ● | 中高 | ★ | ★ | ★ | ★ | ● | ★ | ● | ● | ○ | ★ | 大数字+人话对比统计卡；不照搬反扣手机阻塞审批 |
| **flomo** | ● | 中高 | ● | ● | ★ | ● | ○ | ○ | ● | ● | ● | ★ | 零摩擦输入与每日记忆回顾；不照搬阉割 Markdown 复杂排版 |
| **iDaily** | ★ | 极低 | ★ | ★ | ★ | ● | ○ | ○ | ● | ● | ○ | ● | 刊头细线与大图手势退场；不照搬低密度新闻流 |
| **滴答清单** | ● | 高 | ★ | ★ | ● | ★ | ● | ★ | ● | ★ | ★ | ★ | 左右滑手势、4秒撤销、VoiceOver 完备；不照搬全能功能膨胀 |
| **轻芒杂志(史)** | ★ | 低中 | ● | ● | ★ | ○ | ● | ○ | ○ | ○ | △ | △ | 马克笔划重点沉淀成卡；**警惕过度异形排版拖慢高频操作与帧率** |
| **Cubox** | ★ | 中 | ★ | ● | ★ | ★ | ○ | ● | ● | ● | ● | ★ | 网页净化快照与四色纸墨主题统一；不照搬多色荧光涂抹聊天流 |
| **即刻** | ● | 中 | ● | ★ | ● | ★ | ★ | ★ | ★ | ★ | ○ | ● | 深墨灰阶层次（非死黑）与有温度的彩蛋；不照搬广场热榜干扰 |
| **有知有行** | ★ | 低中 | ★ | ★ | ★ | ● | ○ | ○ | ● | ● | ★ | ★ | 反焦虑信任美学与敏感数字遮罩；不照搬低频静态节奏 |
| **谜底黑胶** | ○ | 极低 | ● | ★ | ★ | ★ | ★ | ★ | ★ | ★ | △ | ★ | 手指搓碟即时物理打断+段落触觉；不照搬重拟物玩具壳 |
| **锤子便签(史)** | ★ | 低 | ★ | ● | ★ | ○ | ○ | ○ | ○ | ● | △ | ○ | 纸墨落款长图与克制 Markdown；**严禁固定背景横线锁死行距（大字号会破格）** |
| **豆包** | ● | 低中 | ● | ○ | ○ | ★ | ★ | ★ | ★ | ● | ★ | ● | 语音通话低延迟打断（Barge-in）、滑移取消手势；不照搬广场推荐流 |
| **Kimi** | ★ | 中高 | ● | ● | ★ | ● | ○ | ○ | ● | ● | △ | ● | Bottom Sheet 原位溯源、文档胶囊；**警惕行内小角标 `[1]` 触控热区太小** |
| **Manus** | ● | 极高 | ● | ★ | ● | ○ | ● | ○ | ● | ○ | △ | △ | 透明步骤看板+沙箱产物聚拢+人机接管；**绝不把桌面双栏活监控硬塞进手机聊天** |
| **DeepSeek** | ★ | 中高 | ★ | ★ | ★ | ● | ● | ○ | ● | ● | ● | ● | 「已思考 N 秒」左竖线折叠块、不强夺视口、代码块复制反馈 |
| **秘塔 AI 搜索** | ★ | 高 | ● | ● | ● | ● | ○ | ○ | ● | ○ | △ | ● | 学术/网页来源元数据摘要卡、结构化大纲；手机不用双指缩放横向脑图 |
| **飞书** | ★ | 极高 | ★ | ★ | ★ | ★ | ★ | ● | ★ | ★ | ★ | ★ | **Universe Design 轻描边+双列字段扫读+Card 2.0 差量稳态刷新**；不照搬 B 端红点 |
| **ima** | ● | 中 | ● | ● | ○ | ● | ○ | ○ | ● | ● | ● | ● | 「仅查我的知识库 vs 全网」明确边界与沉淀笔记；不用云账号绑定 |
| **语雀** | ★ | 中 | ★ | ★ | ★ | ● | ○ | ○ | ● | ● | ● | ● | 开箱即好看的中文文档排版与「小记→文档」流；不用多级深树挤爆窄屏 |
| **夸克 AI 搜索** | ● | 高 | ● | ● | △ | ● | ○ | ○ | ● | ● | ○ | ● | 划词即问悬浮操作条与步骤卡；警惕业务膨胀导致的视觉碎片化 |
| **OriginOS** | ● | 动态 | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ○ | ★ | 原子岛形变与零层级直办；**禁大面积长列表实时渐进模糊** |
| **HarmonyOS NEXT** | ★ | 中 | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | **一镜到底空间连续性 + 150–250ms 短距响应纪律** |
| **ColorOS** | ● | 中 | ● | ● | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | **极光引擎并行可打断铁律 + O-Haptics 精密场景触觉** |
| **HyperOS** | ★ | 中高 | ● | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | **点按即有响应的物理阻尼 + 清晰现代无衬线中文可读性** |
| **Bear** | ★ | 低中 | ★ | ★ | ★ | ★ | ● | ○ | ★ | ★ | ★ | ★ | 调色盘整体联动（底色/分隔线/语法全校准）+ 最大舒适行宽 |
| **Day One** | ● | 中 | ★ | ★ | ★ | ★ | ○ | ○ | ● | ● | ★ | ★ | 历史记忆时间轴回顾 + 极简浅灰元数据脚注 + 后台隐私模糊 |
| **Ulysses** | ★ | 低 | ★ | ★ | ★ | ★ | ● | ● | ● | ● | ★ | ★ | 低饱和语法标记不抢正文、极简环形进度指示 |
| **Stoic** | ● | 极低 | ★ | ★ | ★ | ● | ● | ● | ● | ● | ★ | ● | 纯中性墨阶建立高级感；不照搬全无彩色（审批警示必须有语义色） |
| **Structured** | ● | 中 | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | **竖向时间轴圆点连线+当前步高亮+15m 刻度触觉吸合** |
| **Finch** | ● | 中 | ● | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | **无羞辱正向宠物陪伴**；绝不做体力养成与每日打卡绑架 |
| **Duolingo** | ● | 极低 | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ● | ★ | ★ | 并行飞入零阻塞+高可按压感；**坚决反对照搬 3D 游戏塑料与连胜 PUA** |
| **Headspace** | ● | 低 | ★ | ★ | ★ | ● | ★ | ● | ● | ● | ★ | ★ | **暖系低焦虑色板 + 顶级 Dynamic Type/VoiceOver 包容性** |
| **Endel** | ○ | 极低 | ★ | ★ | ★ | ● | ★ | ★ | ★ | ● | ● | ★ | 极其克制的单色状态映照 + 模式切换拨盘阻尼 |
| **Portal** | ○ | 极低 | ★ | ★ | ★ | ★ | ★ | ● | ★ | ● | △ | ○ | 内容 100% 主体 + 悬浮玻璃控件自动退让隐身 |
| **Reeder** | ★ | 中高 | ★ | ★ | ★ | ★ | ● | ★ | ★ | ★ | ★ | ★ | 靠墨色深浅区分已读/未读 + 双阈值左/右滑触觉 |
| **Darkroom** | ● | 高 | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | **滑过基准零点给更强一档 `detent` 触觉 + 全等宽调参数值** |
| **Fantastical** | ● | 高 | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ★ | 左窄语义色条+固定等宽信息列+自然语言输入标签高亮 |
| **Things 3** | ● | 中 | ★ | ★ | ★ | ★ | ★ | ● | ★ | ★ | ★ | ★ | 平静浅灰衬托微浮白纸卡 + 原地轻抬展开细节 |
| **Flighty** | ● | 高 | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ● | ★ | ★ | 灵动岛极简实时进度 + 大字态高密度数据卡不焦虑 |
| **Gentler Streak** | ● | 中 | ★ | ★ | ★ | ★ | ● | ● | ● | ● | ★ | ★ | 温和客观的异常/休息态文案与极高无障碍水准 |
| **Linear Mobile** | ● | 高 | ★ | ★ | ★ | ★ | ★ | ● | ★ | ★ | ● | ★ | 0.5pt 精密描边 + 状态小icon + 等宽元数据高速分拣 |
| **Not Boring** | ○ | 低 | ● | ★ | ★ | ★ | ★ | ★ | ★ | ★ | ○ | ● | 多段瞬态+连续 AHAP 物理手感（仅限高价值仪式使用，严防滥用） |

---

## 三、Clio 真实页面与 Swift 组件逐项映射表（10 大核心域）

> 以下映射全部基于仓库 `batch-0.36` 实际文件架构（含 PR #85–#93 的 UIKit `UICollectionView` + `CoreText` 异步瓦片 120Hz 引擎），绝不破坏既有安全边界与宠物位置红线。

| 核心域 | Clio 现有真实文件与组件 | 现状优势与痛点 | 核心参考原理（非拼凑） | Design System 2.0 升级目标 | 原生技术落地约束 |
|---|---|---|---|---|---|
| **1. 首页与侧边栏抽屉** | `Desk.swift`, `DeskHomeView.swift`, `DeskSidebarView.swift`, `DeskSlideHost.swift`, `NewChatSheet.swift` | 已有「置顶/对话/收起旧对话」、4秒归档撤销、颜色点与新对话选记忆；但首页与侧栏的视觉密度、图标徽标和「等你确认/晨信」存在跨页轻微不统一 | **Reeder**（墨色区分已读/未读，减少红点）+ **Linear**（等宽副元信息+高扫读行）+ **Things 3**（轻浮卡片） | ① 侧栏行按「状态微点 / 左色轨 + 标题 + 一行预览 + 相对时间」四元对齐；② 首页待签卡 `waitingCard` 与晨信 `letter` 采用更鲜明的语义区分；③ 抽屉侧滑全程 1:1 跟手、可随时反向打断 | `DeskSlideHost` 手势与 `ChatListViewController` 滚动互不抢占；未读靠墨色深浅与温和圆点区分 |
| **2. 长对话流与中文阅读** | `ChatPage.swift`, `ChatPage+TopBar.swift`, `ChatListViewController.swift`, `ChatProseRenderer.swift`, `ChatTextTileRenderer.swift`, `ChatRichTextView.swift`, `ChatSources.swift`, `NoteSheet.swift` | PR #85–#93 已实现 CoreText 异步瓦片、120Hz 小地图、`glassBubble` 轻量气泡、自由选字；痛点在长来源列表缺少摘录上下文、三套语言缺少清晰的视觉差异规则 | **微信读书**（中西文光学微距、标点挤压、原地选字栏）+ **DeepSeek**（不抢视口跟底）+ **秘塔/Kimi**（来源摘录预览）+ **锤子便签**（长图边距落款） | ① `ChatProseRenderer` 写入中文排版硬标准（段距 `0.72×`、列表 `0.25×`、中西混排视排微距不污染拷贝内容）；② `SourcesSheet` 展示网页标题+命中摘录；③ `NoteSheet` 规范三套语言导出长图样式 | **严禁在 `UICollectionView` Cell 内使用 SwiftUI 实时 `.glassEffect`**；严格保留 `ChatTextTileRenderer` 异步瓦片与 `drawGeneration` 复用防串图 |
| **3. 工具执行、思考与计划** | `ChatTrace.swift`, `ThinkingBox.swift`, `ToolTail.swift`, `PlanCard.swift`, `ChatWorkingBar.swift`, `ChatBlockViews.swift`, `Roam/Browser.swift` | 已有 3 行固定防跳思考窗、`PlanReveal` 自下而上裁剪展开、纯 UIKit 代码块/文件块；但思考块缺少明确耗时、展开时间线步数对齐可更清晰 | **DeepSeek**（思考左竖线+耗时）+ **Structured**（圆点竖轴连线+当前步高亮）+ **Manus**（全步骤产物聚拢）+ **Flyghty**（状态条简明） | ① `ThinkingBox` 增加「已思考 XX 秒」等宽计数与清晰 2pt 左轨；② `ChatTrace` 展开时间轴对齐左轴节点、标出各步耗时与结果状态（成功/失败/未知）+ 聚合「本轮产出文件」入口；③ `ChatBlockViews` 代码复制切换「✓ 已复制」 | 保持流式 `.transaction { $0.animation = nil }` 与 `PlanReveal` 裁剪零布局跳动；网页预览维持静态缩略图+离线 `WKWebView` |
| **4. 审批与人机确认（红线）** | `ApproveView.swift`, `InlineApproval.swift`, `InlineAsk.swift`, `Vault/FormSheet.swift`, `Grant/GrantsPage.swift`, `Vault/SecretsPage.swift` | 已有 `SlideTrack` 滑盖 `ClioSeal` 印章与触觉 `thud()`、`InlineApproval` 就地审批与 `Taint` 外网警告；痛点是部分长命令与原因排布还可更清晰、且需要适应 B/C 语言（非书卷印章）的仪式 | **飞书 Card 2.0**（字段左标签右数值双列扫读）+ **谜底黑胶/Darkroom**（滑动分段触觉增量）+ **格志日记**（结构化提问格子）+ **有知有行**（敏感遮罩） | ① 详情区升级「操作 / 工作地点 / 命令与风险」双列+等宽滚动框，Taint 警示保证图标+颜色+文字三重冗余；② 三套语言差异化确认仪式（A 朱印盖章 / B 精密棘轮滑锁 / C 温和推进确认）；③ `InlineAsk` 采用紧凑格志式选项组 | **绝不绕过 `Taint` / `Vault` / `AskUserRules` 任何安全规则**；AX 大字号自动切 `ApprovalViewport` 可滚动并取消倾斜旋转 |
| **5. 文件（书案）与互动预览** | `Study/StudyPage.swift`, `Study/InteractivePreview.swift`, `Study/DiffText.swift` | 已有本地+外部挂载文件夹标识、64KiB+ TXT 分片排版、离线 `WKWebView` 沙箱预览与 Diff 视图；痛点是文件列表与阅读器头部的版式可更统一、互动卡跳转不够「一镜到底」 | **Bear / 语雀**（开箱即好看的 Markdown 阅读器）+ **HarmonyOS 一镜到底**（`.navigationTransition(.zoom)`）+ **Cubox**（快照浏览） | ① 挂载目录与本地目录靠明确徽章/色边区分且提示失效重连；② `.md` 文件阅读继承正文排版轨；③ 点击文件/互动预览采用 iOS 26 `.matchedTransitionSource` 缩放过渡 | 严格维持 `WorkspaceFileRef` 软链接防越界与 `InteractivePreview` 断网 `WKContentRuleList` 沙箱 |
| **6. 记忆（拾遗）与手札** | `Memory/MemoryPageV2.swift`, `Memory/MemoryImportSheet.swift`, `Reading/MemoryReviewHistory.swift`, `Reading/Daily.swift` | PR #80/#83 已做四层（常驻/近期/较早/封存）、批量导入脱敏与夜间整理；页面内卡片层徽章、来源标签、回顾感偏功能列表风 | **flomo**（无摩擦快记一条 + 每日回顾感）+ **Day One**（时间轴回顾与安静元数据）+ **Things 3**（原地展开编辑） | ① 顶部四层筛选胶囊配清楚统计计数；② 记忆卡区分「AI 自动写入（可撤回） vs 用户手写（受保护）」，点击原地轻量展开编辑/升降层；③ `MemoryReviewHistory` 与 `Daily` 改造成安静的时间轴卡片 | 坚守 `MemoryAccessContext` 与 `LiveChatMemoryGate` 隐私隔离，绝不展示或导入未经脱敏的密钥 |
| **7. 终端（斗室）与远程主机** | `Study/DenPage.swift`, `Study/Inkstone.swift`, `Study/OutfitSheet.swift`, `Hills/HillsPage.swift` | 已有 Alpine Linux 状态点、2:1 中西等宽输出、停止钮、常用包清单；痛点是命令卡片视觉与其他页割裂、运行中停止防误触与状态对比可提升 | **Linear Mobile / Darkroom**（高反差精密状态栏 + 0.5pt 精密描边 + 等宽数字）+ **潮汐**（重要任务停止确认） | ① 头部状态点升级为「图标+颜色+文字」三重冗余状态胶囊（睡眠/准备/就绪/运行/异常）；② 命令输入与输出卡片维持 Maple Mono + Clio Mono CN 2:1 严格对齐；③ 运行中点停止给二次确认或清晰提示 | 保留 SwiftTerm / iSH 底层逻辑不变；严格限制非正文区不使用花哨衬线字体 |
| **8. 模型切换与服务配置** | `ChatPage+Chips.swift` (`ChatModelMenuView`), `ServicePage.swift`, `DefaultModelsPage.swift`, `SetupView.swift`, `UsageSheet.swift`, `ModelInputPage.swift`, `BrandIcon.swift` | C34/A4 已整理成服务商图标+角标、默认模型统一页、请求日志查看与探测思考档位；痛点是 `UsageSheet` 与 `ModelInputPage` 数据呈现可更清晰 | **OffScreen / Flighty**（大字指标+人话解读卡）+ **飞书**（清晰表单分组） | ① 聊天顶栏模型胶囊收进 `GlassEffectContainer`，与旅伴名胶囊视觉等高对称；② `UsageSheet` 顶部展示 Token/上下文比例微环；③ 思考档位图标+文字说明（不靠颜色单独表示） | 坚持 `BrandIcon` 运行时抓取、不往仓库塞商业 Logo；保证思考档位逐档探测实测逻辑不变 |
| **9. 设置、外观与数值控件** | `SettingsView.swift`, `Design/LookPage.swift`, `Design/FontPage.swift`, `Design/StopPicker.swift`, `Design/Ink.swift`, `Design/Kit.swift`, `Care/CarePage.swift`, `Tone/ToneViews.swift`, `Design/AppLock.swift` | 已有 6 分组首页、常驻搜索、独创竖向 `StopRow`/`StopRuler`、四档底色与六色盘；痛点是 `StopRuler` 缺默认基准点的强一点触觉、`LookPage` 缺三套语言一键预览样张、`CarePage` 掉帧卡略朴素 | **Darkroom**（基准零点 `detent` 触觉+等宽刻度）+ **Bear**（整套调色盘联动预览）+ **有知有行**（隐私安全锁质感） | ① 保留 `StopRow`/`StopRuler` 唯一数值调节规矩（禁止 Stepper/Slider），在默认值刻度加入更明显的 `detent` 触觉与「长按小样对比默认」手势；② 严格统一所有弹出页右上「完成」、填表「取消/保存」与 6 组 `RowCard` 规范 | 遵循 `tools/lint.py` 规则（不写 `.system(size:)` 硬编码数字、不写 `design: .monospaced`、颜色全走 `Ink` 语义 Token） |
| **10. 宠物、旅伴与系统表面** | `Pet/PetStage.swift`, `Pet/PetPerch.swift`, `Pet/PetPage.swift`, `Reading/Glance.swift`, `Reading/NameCardView.swift`, `Design/AlwaysOn.swift`, `Shared/TurnActivity.swift` | 已有像素小克/肉包 11–14 状态、水平防遮挡拖拽、跨对话冒泡、一眼卡、名帖正反面、常亮黑屏与极简灵动岛；需要在三套设计语言下保持一致融合感 | **Finch**（无内疚情感陪伴）+ **CapWords**（物理贴纸抬起落回感）+ **Flighty**（灵动岛超紧凑进度）+ **Endel**（黑屏静气） | ① `PetStage` 严格维持「输入框上沿水平拖拽+微浮+落地压扁回弹」，在 A/B/C 三套语言分别匹配「纸感气泡 / 仪器时间胶囊 / 温润微光气泡」；② `GlanceCard` 与 `TurnActivity` 精简为三行黄金层级；③ `AlwaysOn` 强制 `monospacedDigit` 防每15秒微移抖动 | **绝对不碰 `PetStage` / `PetPerch` 的水平拖拽限制与不可钉到其他高度的产品红线** |

---

## 四、反拼凑守卫（Design Synthesis Guardrails）

把 50 个产品的优点直接全装进 Clio 只会做出四不像。Clio 2.0 必须严守以下 **5 条互斥边界**：

1. **情绪节律互斥**：不能一边采用 **Duolingo 式** 高饱和塑料 3D 按钮与连续打卡焦虑，一边宣称 **有知有行 / Bear 式** 安静阅读陪伴。**取舍**：所有语言一律采用「低焦虑、不催促」交互语调，只吸收其可按压感与并行响应机制。
2. **渲染性能互斥**：不能一边要求 **ChatListViewController 120Hz 满帧（8.33ms 预算）**，一边把 **OriginOS 长列表实时渐进模糊** 或 **Manus 双栏活网页监控** 塞进滚动 Cell 里。**取舍**：实时 `.glassEffect` 只给悬浮顶底栏与轻弹层；滚动列表气泡用轻量渐变描边（`glassBubble`），复杂图表用静态图+点开独立隔离预览。
3. **文字排印与背景纹理互斥**：不能学 **锤子便签** 画固定信纸横线背景，同时又支持 **微信读书/iOS AX1–AX5 动态字号** 与 4 档行距。**取舍**：以纯色纸面/中性底 + 发丝边构建质感，绝不画死横线锁死行距。
4. **平台手势互斥**：不能把安卓分屏小窗手势或边缘全向悬停球套进 iOS 26。**取舍**：全部遵循苹果原生侧滑返回、`NavigationStack` Sheet 下拉、`.matchedTransitionSource` 与 `UIViewPropertyAnimator` 可中断手势。
5. **触觉克制互斥**：不能一边学 **ChatGPT** 流式出字每字震动，一边做长文深度阅读工具。**取舍**：流式打字与列表滚动保持 100% 静默，仅在**主动操作**（点按、拖拽 `StopRuler` 刻度、审批滑锁/盖章、抓放小克、告警拦截）给出清晰分层的 `CoreHaptics` 反馈（同 **Cindy / Darkroom** 哲学）。

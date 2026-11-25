# Clio Design System 2.0：一手调研证据审计台账（Evidence Audit Log · Deliverable #2）

> 本文件如实记录本次调研中**浏览器实测访问的每一个站点与官方规范页面**、**实测核验到的奖项归属更正**、**访问受限/失效链接**，以及 **Windows 环境下 `[待真机实录补全]` 边界清单**。
> 纪律：**绝不将未实际打开或访问失败的页面标为已核验；未经历真机上手测试的震动与 120Hz 表现一律严守第 7 级标注。**

---

## 零、任务书第十八节「七级证据可信度分级」强制标注标准

全系列研究文档与研究卡统一按以下 **1–7 级标签** 显式标注每项依据来源：
- **`[1 官方设计规范]`**：Apple HIG / WWDC、W3C CLREQ、HarmonyOS / OriginOS / 飞书 Universe Design / Ant Design / TDesign 公开文档。
- **`[2 官方产品演示]`**：产品官网实机图、Changelog、App Store 官方预览截图与官方开发者访谈（如 CapWords Apple Developer CN 文章、Linear Design Reset 团队复盘）。
- **`[3 实际产品使用体验]`**：在当前环境真正打开交互并完成步骤检验的体验记录（如 Prototype v4/v5、`doubao.com/chat`、Clio `batch-0.36` 真实源码核验）。
- **`[4 设计奖项与评审]`**：经 `developer.apple.com/design/awards/2024..2026` 或官网/商店实测核对后的 ADA / App Store Award / Red Dot / iF 归属。
- **`[5 第三方评测]`**：经检索汇总或少数派等第三方公开测评观察到的跨版本特性（如 Arc Search 捏合总结、Claude Code 审批疲劳复盘）。
- **`[6 主观审美推断]`**：基于静态视觉或交互理念面向 Clio 做出的风格偏好推演（绝不冒充实测结论）。
- **`[7 未验证的假设]`**：包括 iOS 真机 120Hz ProMotion 实际掉帧曲线、Taptic Engine 实体马达共振手感，以及未访问/访问超时的站点推测。

---

## 一、浏览器实测通过的官方站点与设计规范（宿主验证来源清单）

### A. Apple 官方规范与 Apple Design Awards 2024–2026 实时页面
| 对象 / 文档 | 实测访问地址 | 核验结论与视觉要点 |
|---|---|---|
| **Apple Design Awards (2024 / 2025 / 2026)** | `https://developer.apple.com/design/awards/`<br>`https://developer.apple.com/design/awards/2025/`<br>`https://developer.apple.com/design/awards/2024/` | • 确认 **CapWords**（HappyPlan Tech）获 **2025 ADA Winner — Delight and Fun**。<br>• 确认 **Gentler Streak** 获 **2024 ADA Winner — Social Impact**（同团队 *The Outsiders* 入围 2026 ADA）。<br>• 确认 **Mela**（Silvio Rizzi，同作者 *Reeder*）入围 **2025 ADA Finalist — Interaction**。<br>• **纠偏 1**：**Structured** 为 **2026 ADA Finalist — Inclusivity**（集成 iOS 26 Foundation Models），更正初版误写为 Delight and Fun 得主。<br>• **纠偏 2**：**Finch** 在 2024/2025/2026 三年 ADA 名单中均未出现，已从获奖榜调回「业内设计参考」。 |
| **Apple HIG · Materials (iOS 26)** | `https://developer.apple.com/design/human-interface-guidelines/materials` | 官方明文红线：***"Don't use Liquid Glass in the content layer"***。浮动导航/控件用 `regular`/`clear` Liquid Glass；内容底卡使用 `ultraThin`/`thin`/`regular`/`thick` 标准材质。 |

### B. 国产 OS 官方设计规范页
| OS / 品牌 | 实测访问地址 | 实测观测 UI 与量化规范 |
|---|---|---|
| **华为 HarmonyOS Design** | `https://developer.huawei.com/consumer/cn/design/` | 观摩 HarmonyOS 7 空间美学、沉浸光感、智感握姿实况胶囊（左摄避让）、闪控球与闪控窗暗色高透光浮窗。 |
| **OPPO ColorOS** | `https://www.coloros.com/version/coloros17/` *(自 `coloros.com` 跳转)* | 观摩 ColorOS 17「新一代小布」事务提示卡（灰字`"先不用"` + 蓝底`"帮我打车"`成对胶囊）及暗色半透明「流体云」实时导航胶囊。 |
| **小米澎湃 OS (HyperOS)** | `https://hyperos.mi.com/` | 观摩 HyperOS 4 柔光玻璃锁屏时钟 `0856`、悬浮白色胶囊底栏 + 独立圆 `+` 钮，以及「小米超级岛」顶部「思考中」发光涡旋态。 |
| **vivo 开放平台 (OriginOS)** | `https://developer.vivo.com/`<br>`https://developer.vivo.com/doc/detail?id=236` | 拿到组件视觉规范量化指标：支持 `2×1 / 2×2 / 4×2 / 4×4`；**统一 `20 dp` 圆角（`60%` 平滑曲率）与 `14 dp` 内安全边距**，遵循动态色系自适应。 |

### C. 中国区独立美学、效率、阅读与 AI 产品官网 / 规范 / App Store
| 产品 | 实测访问地址 | 实测可见形态与核心视觉证据 |
|---|---|---|
| **CapWords** | `https://capwords.app/` | 有手持 iPhone 实机画面；暗炭底 `#262626` + 日期印章 + 磨砂底栏 + `20–24px` 纸纹白描边贴纸卡。 |
| **谜底时钟 (MD Clock)** | `https://apps.apple.com/cn/app/%E8%B0%9C%E5%BA%95%E6%97%B6%E9%92%9F/id1536358464` | 4 张真机截图，明确标示 **iOS 26 新特性「Liquid Glass 时钟小组件」**、苹果设计大奖徽章、翻页/像素钟及 `16:42` 番茄计时玻璃按钮。 |
| **潮汐 (Tide)** | `https://tide.fm/` | 展示 Home 与睡眠 iPhone 真机画面：全幅海景 + 4 个半透明磨砂圆形模式按钮 + 竖向滚轮时钟。 |
| **flomo** | `https://flomoapp.com/` | `#f7f8f7` 灰白底 + 白色轻量细边笔记卡 + 浅蓝 `#Tag` + 热力图 + 官网直接展示的 iOS 深色桌面每日回顾小组件与长按上下文菜单。 |
| **微信读书** | `https://weread.qq.com/` | `#f4f5f7` 冷灰门户底、高圆角全胶囊搜索条、克制灰字标签与 2×2 卡片网格（Web 门户无 iOS 内页截图）。 |
| **小宇宙** | `https://www.xiaoyuzhoufm.com/` | `#fbf7f4` 暖白海报配 2 部 iPhone 真机画面（三列订阅节目方图 + 深色单集播放器）。 |
| **有知有行** | `https://youzhiyouxing.cn/` | 纸白编辑式信件排版 + 纯白卡嵌绿色市场温度章（`"32°"`）+ 淡薰衣草导读卡 + 底部四栏 Tab。 |
| **即刻** | `https://okjike.com/` | 白底配明黄笔刷与 3 部 iPhone 真机画面（含浅色信息流中央醒目明黄圆形 `+` 钮与飘浮状态气泡）。 |
| **滴答清单** | `https://www.dida365.com/` | 三栏任务工作台（含蓝标内嵌时间 `07:00`/`09:00`）、暗色翻页钟（`24:59`）与 LED 点阵专注钟展示。 |
| **格志日记** | `https://griddiaryapp.com/` | 展示 Mac/iPad/iPhone 真机：`1px` 细灰线隔开的 2×2 结构化提问格子与极简底栏图标。 |
| **飞书 / Universe Design** | `https://open.feishu.cn/document/design-specification/written-in-advance`<br>`https://open.feishu.cn/document/design-specification/design-language/color`<br>`https://open.feishu.cn/document/feishu-cards/feishu-card-overview` | 拿到精确 Token：`#FFFFFF` 卡衬于 `#EFF0F1` 底面、品牌蓝 `#1456F0` 十阶、四级中性字色（`#1F2329 / #646A73 / #8F959E / #BBBFC4`）及 Card 2.0 对比样张。 |
| **Manus** | `https://manus.im/` | `#f8f8f7` 暖白底 + 中文衬线 `"我能为你做什么？"` + `20px` 细边输入盒 + 6 颗轻量胶囊（无移动端实机图）。 |
| **DeepSeek** | `https://www.deepseek.com/` | 淡蓝白方格渐变底 + `#3b6ff5` 强调色 + 输入盒左下内嵌开关胶囊（`深度思考` / `智能搜索`）。 |
| **Kimi** | `https://www.kimi.com/` | `#171717` 深炭工作台 + 双层输入区 + 「灵感库」多列圆角模板墙。 |
| **秘塔 AI 搜索** | `https://www.metaso.cn/` | `#FFFFFF` 纯白画布 + 极浅冷灰左窄栏 + 居中无广告搜索框内嵌范围胶囊。 |
| **腾讯 ima** | `https://ima.qq.com/` | 关闭登录框后可见深灰侧栏、内嵌 `"DS 快速"` + `@` 芯片与两列圆角「精选示例」产物预览卡。 |

### D. 国际设计标杆官网
| 产品 | 实测访问地址 | 实测观测核心特征 |
|---|---|---|
| **Bear** | `https://bear.app/` | 纯白纸底 + 深海蓝灰抽屉 + 珊瑚红点缀 + 行内 `#tag` 胶囊 + 带 1px 细边 callout 卡 + 顶角圆弧浮钮。 |
| **Day One** | `https://dayoneapp.com/` | `#44C0FF` 天蓝顶渐变过渡进纯白时间轴、汉堡菜单+日志切换+右下圆 `+` 浮钮。 |
| **Ulysses** | `https://ulysses.app/` | 暗炭灰三栏侧栏 + 左侧弱化 `##` 标记 + 悬浮字数圆环目标卡（`4,833字 / 6,000字`）+ 行内校对浮泡。 |
| **Structured** | `https://structured.app/` | `#F4F5F7` 浅灰底 + 纯白时间轴卡 + 珊瑚红 `#F28B82` + 7 日条 + `19 min remaining` + 虚线空闲提示卡 + 右侧空心圆环。 |
| **Darkroom** | `https://darkroom.co/` | `#121214`/`#1C1C1E` 暗房灰黑 + 蒙版药丸切换（`A/B/C`）+ 垂直亮度滑杆 + RGB 直方图 + 三圆调色轮。 |
| **Things 3** | `https://culturedcode.com/things/` | 纯白底 + 浅灰今日日程横条 + 圆角空心方框 + `today` 小红旗 + 亮天蓝右下 `+` 浮钮。 |
| **Flighty** | `https://flighty.com/` | 上半实时地图 + 下半可拖白色圆角 `"My Flights"` 底卡 + 地图右侧圆形雷达浮钮 + 红/绿延误与准点徽标。 |
| **Linear Mobile** | `https://linear.app/mobile` | `#000000` 纯 OLED 黑 + 头像/蓝点/两行副标高扫读行 + 右滑 Unread/左滑删除 + 底部 `Comment` 胶囊组。 |
| **Gentler Streak** | `https://gentlerstories.com/gentlerstreak` *(自 `gentler.app` 跳转)* | 暖珊瑚橙角色问候 + `30 days v` 下拉 + 薄荷绿 `Activity Path` 趋势带 + 底部浮动圆角胶囊导航栏。 |
| **!Boring Software** | `https://notbor.ing/` *(自 `andy.works` 跳转)* | 暖石质圆角方块衬托 3D 物理材质图标与多季皮肤标签（Debug/Artist/Creator）。 |
| **Finch** | `https://finchcare.com/` | 明快插画落地页 + 翠绿底栏（首页无内嵌 iOS 截屏）。 |
| **Portal** | `https://portal.app/` | `#0B0D10` 深曜石底 + 全幅高清自然风景 + 衬线主标题 `"Nature Powered"` + 极简环形半透明顶栏。 |
| **Endel** | `https://endel.io/` | `#000000` OLED 黑 + 白细线生成式正弦波纹 + 4 圆声景发射线 + `#141414` 卡片右上圆形播控钮。 |
| **Duolingo** | `https://www.duolingo.com/` | `#FFFFFF` 底 + `#58CC02` 3D 立体底边按压质感按钮 + 圆角进度条与 2×2 卡片示意图。 |
| **Headspace** | `https://www.headspace.com/` | 太阳黄/日落渐变/暖米 `#F8F4F0` 胶囊 + **Ebb AI 伴读气泡（`You` + 闭眼橙粉渐变球）** + iPhone 横滑情绪芯片屏。 |

---

## 二、访问受限 / 失效 / 跳转异常链接清单（诚实如实记录）

1. `https://open.feishu.cn/document/client-docs/design-guidelines/overview` 与 `/card-design-specification` — 原文档路径已下线（「文档不存在」），改为从 `https://open.feishu.cn/` 导航实测最新 **Universe Design**（`written-in-advance`、`color`）与 **飞书卡片** 文档。
2. `https://miidii.tech/` — 访问 10 秒超时未响应；已由 App Store 中国区官方页面 `id1536358464` 补全 4 张真机截图核验。
3. `https://apps.apple.com/cn/app/%E5%8D%B3%E5%88%BBapp/id1154534969` 与 `id6479633634`（秘塔）— App Store Web 返回 404 / 限流 429；已分别由 `okjike.com` 与 `metaso.cn` 实测补全。
4. `https://apps.apple.com/cn/app/%E8%B1%86%E5%8C%85-.../id6444638752` — 该 App ID 当前在 web 端跳转指向无关页面，已排除不采用其截图。
5. `https://apps.apple.com/us/app/stoic-.../id1312926036`、`reeder/id6477273749`、`fantastical-calendar/id718043190` — 美区页面在当前网络环境下自动重定向回中国区 App Store `today` 首页。
6. `https://imuseum.com/` 与 `https://idaily.com/` — 访问跳转域名停放页或超时，未能在本机浏览器加载到有效产品展示页（该系列以 `[公开交互演示/评测]` 与 2014 App Store 官方获奖归档为准）。

---

## 三、原型自身实测迭代与 `[待真机实录补全]` 边界

- **原型实测 QA（`http://127.0.0.1:3425/a/pfrmwhcemcbess5bh7jvjcvisa/`）**：
  - 经历 **v2 盲区揭露**（`sharpnessBias`/`defaultTone` 崩溃、顶栏折行、`StopRuler` 拖拽销毁 DOM）→ **v3 实测复盘**（1280×800 首屏、单行顶栏、`StopRuler` 连续拖、发送/重写/引用/菜单/AlwaysOn/方向 A B C 对比全通过，揪出 `renderViewport` 先于挂载执行 `document.getElementById` 导致场景 2/3/5 断链问题）→ **v4 彻底根治并终验**。
- **`[待真机实录补全]` 严格声明**：
  - 本工作环境为 Windows，所有涉及 **iPhone 120Hz ProMotion 实际渲染帧耗时（`CADisplayLink` ≤ 8.33ms）** 与 **Taptic Engine 实体线性马达共振波形** 的指标均依赖 Apple HIG / Clio 已有 PR #67–#93 代码约束与浏览器可视化波形推导，待正式方向确认并打包进 `probe-<分支>` 后在主机真机复测完成最后闭合。

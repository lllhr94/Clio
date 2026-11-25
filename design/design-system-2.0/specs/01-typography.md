# Clio Design System 2.0：Typography 与中文排版规范（Deliverable #11）

> 兼容基准：W3C CLREQ（`https://www.w3.org/TR/clreq/` 实测验证规则）· iOS 26 UIKit `CoreText` + `NSAttributedString` · SwiftUI `Theme` · `tokens.v2.json`

---

## 一、9 项独立排版控制、快捷预设与渐进披露

遵循清晰解耦原则，正文参数与界面大小严格分离，**调数值统一走 `StopRow`/`StopRuler`（禁用 Stepper/Slider）**；同时不把普通用户变成专业排版师——高频参数直露，进阶细调收纳，**全部字体光学校准由内部引擎自动吸收**：

| 层级 | 控制项 | 取值与默认 | 渐进披露与交互边界 |
|---|---|---|---|
| **快捷预设（4 选 1，可选起点）** | **阅读预设** | `标准`（苹方 17pt / 1.65×）· **`书卷`**（衬线+苹方 17pt / 1.65×，**AC 默认**）· `紧凑`（苹方 15pt / 1.50×）· `舒阅`（文楷 19pt / 1.80×） | 一键联动设置推荐起步参数；不构成第二套主题系统，切主题色盘（黛蓝/松绿）绝不强改字体 |
| **一级高频** | **正文字体 (`readingFace`)** | 书卷 (New York+苹方) · 苹方 · 文楷 (`ClioKai-Medium`) · 圆体 · 宋体 · 楷体 | 切换行内实时显示真实排版小样，与聊天正文共用同一字体解析规则 |
| **一级高频** | **正文字号 (`readingSize`)** | `15` / `16` / **`17`（默认）** / `19` / `21` / `24 pt` | 同时作用于 AI 正文、用户消息（修复旧版 `userBody` 脱离正文字号问题）与书案长文 |
| **一级高频** | **正文行高 (`lineHeight`)** | `1.35×` 紧凑 · `1.50×` 适中 · **`1.65×` 舒展（默认）** · `1.80×` 宽松 | 经 `SafeLineBox` 统一光学校准与安全边界 |
| **一级高频** | **段落间距 (`paragraphGap`)** | `10pt` · **`13pt`（默认）** · `16pt` · `20pt` | 控制 Markdown 连续段落呼吸感 |
| **一级高频** | **界面字号 (`UIScale`)** | 紧凑 `0.88×` · 偏小 `0.94×` · 标准 `1.00×` · 偏大 `1.08×` | 明确区分「界面控件大小」与「正文阅读大小」，两者独立不互相绑架 |
| **折叠进阶** | **标题字重 (`headingWeight`)** | 适中 (`Medium`) · **清晰 (`Semibold`, 默认)** · 凝重 (`Bold`) | 默认 **Semibold (600)** 降低中文粗黑视觉负担；收进「更多版式细调」 |
| **折叠进阶** | **代码字体 (`codeFace`)** | **`Maple Mono + Clio Mono CN`**（2:1 默认） / 系统等宽 (`SF Mono`) | 收进「更多版式细调」 |
| **折叠进阶** | **标点挤压 (`clreqSqueeze`)** | 开（默认）/ 关 | W3C 标点压缩与中西微距 |
| **大屏专属** | **阅读宽度 (`readingWidth`)** | `560pt` / `640pt` / `700pt` | **仅在 iPad / 横屏宽视口显示**；窄屏 iPhone 自动隐藏，避免无意义设置项 |
| **列表密度** | **UI 密度 (`uiDensity`)** | 舒适 / 标准 / 紧凑 | 仅影响列表行距与摘要密度，不改变正文阅读排印 |

---

## 二、克制编辑式 Markdown 排版与内容差异化密度

> 对照微信读书、Claude、Bear 与 iA Writer：AI 回答经常在一条消息内连出多个标题、列表、表格和代码块。**去掉过重标题膨胀、厚框引用与组件割裂感，让整轮回复读起来像一篇精心编辑的连续文档**。

### 2.1 克制编辑式标题阶梯与正文元素规范（`17pt` 默认基准）

| Markdown / 内容元素 | 定稿取值 (`17pt` 正文) | 字重与样式规范 | 间距与结构约束 |
|---|---|---|---|
| **一级标题 H1** | **`21.5 pt`（`1.26×`，范围 `21–22pt`）** | `Semibold (600)` | 上 `1.0em`，下 `0.36em`，行高 `1.32×`；明确识别度而不过度肥大，不加装饰底纹/横线 |
| **二级标题 H2** | **`19 pt`（`1.12×`，范围 `18.5–19.5pt`）** | `Semibold (600)` | 上 `0.85em`，下 `0.30em`，行高 `1.35×`；承担主要章节分隔 |
| **三级标题 H3** | **`17 pt`（`1.00×`，仅在放大字重与上下节奏）** | `Semibold (600)` | 上 `0.62em`，下 `0.22em`，行高 `1.42×`；靠独立成段与前后留白区分普通加粗词，比强行拉到 `18pt+` 更耐看 |
| **四级及以下 H4+** | **`17 pt`（同正文）** | `Medium (500)` | 上 `0.45em`，下 `0.16em`，自然融入段落脉络 |
| **AI 正文 / 用户消息** | **`17 pt`（同步 `readingSize`）** | 正文 `Regular`；加粗 **`Semibold (600)`**（不硬用特黑 700 破坏中文灰度） | AI 正文无外框卡片；用户轻气泡随 `readingSize` 与 `readingFace` 统一调度 |
| **有序 / 无序 / 多级列表** | `17 pt`（等宽序数 `.monospacedDigit()`） | 严守悬挂缩进；二级列表用细圆/空心圆区分 | 独立列表行高 **`1.50×`**（略紧凑于普通长文），子项间距 `0.25×` |
| **引用块 (`Blockquote`)** | `16.5 pt`（`readingSize - 0.5pt`），色降 `inkSecondary` | **轻量化去盒化**：`2pt` 左竖线 + 极浅 `35% surfaceSubtle` 淡洗底（不再强加硬描边圆角厚卡） | 行高 **`1.70×`**，引文从容耐读 |
| **分割线 (`<hr>`)** | `0.5pt` 细线 (`rule`) | 低存在感，不抢段落主视觉 | 上下留白各 `12–16pt` |
| **行内代码 (`inline code`)** | `max(12, readingSize - 2)` | `Maple Mono + Clio Mono CN`，圆角 `5pt` `surfaceSubtle` 底 | 与基线对齐，不注入中英文额外空距 |
| **多语言代码块 (`Code`)** | `max(12, readingSize - 3)` (`14pt`) | `1:2` 等宽对齐，行高 **`1.30×`**，去首尾空行 | 单层小圆角 `inkBlock`（`14pt`），禁止双层叠框；>18 行可折叠 |
| **来源与脚注 (`Sources`)** | `12.5 pt` | 单颗轻量胶囊附带微圆标点名（降低至辅助阅读权重，不压过正文和复制/引用栏） | 严禁 `< 44pt` 小角标按钮误触 |

### 2.2 内容差异化密度表（基于字体自然度量裁决，不机械套公式）

| 内容类型 | 定稿参考行高 | 设计机理与边界说明 |
|---|---|---|
| **普通长文段落** | **`1.55–1.70×`（默认 `1.65×`）** | 保留长篇阅读透气感与行尾视线回扫精度 |
| **操作步骤与列表** | **`1.42–1.55×`（默认 `1.50×`）** | 列表项本已自带 `leading`，适当收紧单行高使多行条目成为整体视觉单元 |
| **Markdown 表格** | **`1.35–1.45×`（默认 `1.40×`）** | 单元格内容简洁，紧密行高避免窄手机屏幕一次只看清 2 行 |
| **多行代码块 / 终端** | **`1.25–1.38×`（默认 `1.30×`）** | 与 `Ink.swift` 代码行距哲学一致，保证屏幕同屏代码结构可见度 |
| **工具执行轨迹** | **`1.30–1.45×`（默认 `1.38×`）** | 执行步骤信息属高频扫读日志，需紧凑有序不抢正文 |
| **文学性长引用** | **`1.65–1.78×`（默认 `1.70×`）** | 轻底浅灰配合微舒展行高，强化引语与正文的节奏张弛 |

### 2.3 移动端表格精细化评估与定稿准则

- **保留结构语义**：保留原生表头（`Semibold` + 柔和 `surfaceSubtle` 底）与清晰单元格分割（`0.5pt rule`）。
- **数字列强制右对齐 + 等宽数字**：含百分比、对比度、延迟毫秒（`ms`）、Tokens、金额等数值列，自动右对齐（`text-align: right` / `.trailing`）并启用 `tabular-nums`，一眼比大小；中文说明列允许合理折行（`maxWidth` 限制后换行，不把全表拉成一条无限横向长条）。
- **横向滚动清晰提示**：容器超宽时右边缘展示极轻 `paper` 渐隐遮罩提示可横滑，不破坏无框纯洁感。
- **专项取舍评估结论**：
  - **全屏查看 / 复杂手势切纵卡**：仅超宽大表（列数 `>= 5` 或横滑超视口 `1.6×`）按需考虑全屏横向展开；常规 3–4 列表直接依靠合理的**短表头 + 数值右对齐 + 右缘渐隐横滑**已经够快、够轻，避免强行把表格拆成难比对的竖卡，也不在无超宽场景硬叠吸顶表头造成滚动遮挡。

---

## 三、W3C CLREQ 中文排版规则工程规范（已核验 `https://www.w3.org/TR/clreq/`）

1. **行首行尾禁则（§6.1.1 严守避头尾）**：
   - 行首禁止出现句号、逗号、顿号、分号、冒号、感叹号、问号、后括号/书名号/引号（如 `，。、：；！？）》」』】`）；
   - 行尾禁止出现前括号/书名号/引号（如 `（《「『【`）。
   - 采用 **「先挤进后推出」** 优先策略，防止某行出现巨型缺口或孤零零一个标点挂在下一行首；双 em 破折号（`——`）、双省略号（`……`）、数字+单位（`16.5 ms` / `120 Hz`）禁止跨行截断（§6.1.2）。
2. **标点宽度压缩（§6.3.2）**：
   - 连续出现的全角标点（如 `”，`、`。）`）总宽由 `2em` 视觉挤压至 `1.5em`（CoreText `kern` 自动微调），行尾半角留白适度收紧而不使用简体出版不推荐的边缘悬挂（§6.1.3）。
3. **中西文混排光学微距（§6.3.3）**：
   - 汉字与拉丁字母/数字相邻边界注入约 `1/4 em`（实际画面 `0.12em–0.20em`）光学 `kern` 间距；
   - **仅在渲染层 `NSAttributedString` 生效，绝不修改原始字符串、绝不污染剪贴板**；行首行尾、紧邻中文点号（`、` `，` `。`）与成对括号内侧不额外加距。
4. **2:1 等宽代码块对齐引擎收敛**：
   - `App/Sources/Design/Ink.swift` 目前并存 `mapleWithChinese(_:bold:)`（使用 `MapleMono` + `.cascadeList: [ClioMonoCN-Regular]`，本身即为 `0.60 : 1.20 = 1:2`）与 `codeBlockFonts` / `ChatListModels.swift` 的 `alignedCodeFonts`（对数字测宽 `scaleX = size * 0.5 / advance` + 系统中文）。**工程落地时应收敛为以 `mapleWithChinese` 为首选单一对齐引擎**（当用户切为系统等宽 `SF Mono` 时再使用 `scaleX` 微校），消除双路代码对齐维护负担。

---

## 四、字体光学校准体系（Font Optical Calibration）

### 4.1 仓库内置字体实测二进制度量（直读 `App/Fonts/*.ttf` `head/hhea/OS/2` 表）

> 以下数据从仓库真实字体文件二进制头读取，不靠字体名字猜参数（均基于 `UPM = 1000`, `lineGap = 0`）：

| 字体文件 / 体系 | 大小 & 许可/来源 | `hhea` (Asc / Desc / 自然行高比) | `OS/2 Typo` / `Win` 行高比 | `xHeight` / `capHeight` | 源码实测现象与光学校准诊断 |
|---|---|---|---|---|---|
| **`ClioKai-Medium.ttf`** *(默认文楷)* | 3.59 MB · 霞鹜文楷 GB 子集 | `928 / -256` (**`1.184×`**) | Typo `1.000×` · Win `1.317×` | `468` / `695` | **无原生粗体字重**：`Pref.swift:48` 正粗都返回 `ClioKai-Medium`，靠 `ChatProseRenderer.swift:835` 加 `.strokeWidth = -3.0` 合成假粗体（在 14pt 表格里偏粗偏堵）；字面框与 `xHeight (0.468)` 小于苹方，同号切入文楷会显得缩水 |
| **`ClioKai-Regular.ttf`** | 3.65 MB · 霞鹜文楷 | `928 / -256` (**`1.184×`**) | Typo `1.000×` · Win `1.317×` | `468` / `695` | `Pref.swift` 明确在手机屏幕使用 `Medium`，保留不破坏既有打包策略 |
| **`MapleMono-Regular / SemiBold.ttf`** | 134 KB each · SIL OFL | `1020 / -300` (**`1.320×`**) | Typo `1.320×` · Win `1.320×` | `550` / `730` | 仅含拉丁与数字、已裁连字；单字步进 `0.600 em` |
| **`ClioMonoCN-Regular.ttf`** | 5.21 MB · Maple Mono CN GB2312 | `990 / -270` (**`1.260×`**) | Typo `1.260×` · Win `1.320×` | `550` / `730` | 中文等宽字宽 `1.200 em`，与 `MapleMono` 构成精确 **`1:2` 栅格** |
| **`ClioSeal-Regular.ttf`** | 3.02 MB · 马善政毛笔字 | `880 / -120` (**`1.000×`**) | Typo `1.000×` · Win `1.373×` | `506` / `760` | **严格专用于朱印「克」等印章落款**，严禁作为正文或 UI 控件字体 |
| **`New York` + `PingFang SC`** *(系统)* | iOS 系统自带 | `[待真机 CoreText 实测]` | iOS 约 `~1.40×` | `[待真机测量]` | 中文现代极清（苹方）+ 英文与数字优雅出版衬线（New York），无缺字与性能负担 |
| **`STSongti-SC` / `STKaiti-SC`** | 苹果随选下载 (`FontShelf`) | `[待真机 CoreText 实测]` | `[待真机测量]` | `[待真机测量]` | 首次选用时后台下载，加载完毕**必须**立即失效排版缓存并触发重算 |

**源码同步发现的两个待修复一致性问题**：
1. [ChatListModels.swift:300](../../../App/Sources/Reading/ChatListUIKit/ChatListModels.swift#L300) 中 `userBody` 直接使用 `UIFont.systemFont(ofSize: metrics.sizeBody)`，**未跟随 `readingSize` 与 `readingFace`**；应并入统一阅读指标校准。
2. [Pref.swift:81](../../../App/Sources/Design/Pref.swift#L81) 与 [Ink.swift:573](../../../App/Sources/Design/Ink.swift#L573) 仅算 `max(0, size*m - natural)`：无法放大 `ClioKai` 偏小视觉字面，也无法应对紧凑行高 (`1.35×`) 被自然行高 (`~1.40×`) 顶死以及 Emoji/数学块抬高单行导致的节奏断裂。

---

### 4.2 衬线与非衬线 5 组对比实验及 AC 最终默认组合

基于 **4.6 统一验收样本** 对 5 组实验组合展开视觉对照（原型内置可即时切换对照面板）：

| 编号 | 实验组合 | 中文长文耐读性 | 标题气质 | 技术内容清晰度 | 中英数字协调度 | 加粗节奏与 AC 契合度 |
|---|---|---|---|---|---|---|
| **A** | 无衬线标题 (`PingFang Semibold`) + 无衬线正文 (`PingFang/SF Pro`) | 清爽工具感强，极耐长篇技术阅读 | 偏理性工具，文气稍弱 | ★★★★★ 最清 | ★★★★ | 加粗干净，近 Direction B |
| **B** | 衬线标题 (`New York + 苹方`) + 无衬线正文 (`PingFang`) | 中文极耐读 | ★★★☆ 有英文刊物感，中文字标题仍是黑体 | ★★★★★ | ★★★★★ | 与 AC 很契合 |
| **C** | 全宋体 (`STSongti-SC`) 标题 + 正文 | 书卷味浓，但小屏高密代码/表格略累眼，首次需等待下载 | ★★★★ 传统出版感 | ★★★ 略显复古 | ★★★☆ | 原生粗体偏重，连续多标题负担较重 |
| **D** | **霞鹜文楷 (`ClioKai-Medium`) 正文 + 光学校准标题** | 温润亲切、有人文手写温度（校准 `1.045×` 后不发虚） | ★★★★ 独特温厚 | ★★★☆ 需收柔假粗体 (`-2.2` 描边) | ★★★★ | **极佳的长文伴读可选字体，但不作为所有技术重度用户唯一强制默认** |
| **E** | 原书卷设定 (`Pref.Face.serif`: New York 英数 + 苹方中文 + 文楷专属 `mark`) | ★★★★★ **既有「克」印章人文气息，长文又是最高清晰度苹方+最美衬线数字** | ★★★★ 克制 `H1 21.5 / H2 19 / H3 17 Semibold` 后最耐看 | ★★★★★ | ★★★★★ | **定稿采用作为 AC「素笺·栖息」默认搭配**（文楷 `ClioKai-Medium` 保留为一等可读字体随时一键切换，且与黛蓝/松绿配色完全解耦） |

---

### 4.3 内部 7 维光学校准表（只内部消化，不暴露任何额外设置给用户）

```text
FontOpticalProfile {
  opticalScale       // 视觉字面大小补偿（如 ClioKai-Medium = 1.045×，避免 17pt 下显小；NewYork 英数 = 1.02×）
  lineHeightOffset   // 基于实测 naturalRatio 对基线节奏的微小补偿，不改变用户选择的 1.35~1.80 倍意图
  trackingEm         // 仅针对特定偏紧字体做 ≤ 0.005em 呼吸字距（严禁影响 code/URL/数学）
  latinBaselineShift // 中英基线对齐补偿（New York + PingFang 上抬 +0.25pt，避免英文字脚略沉）
  boldStrategy       // 原生有粗体则用 Semibold(600)；仅单字重文楷在正文描边 -2.2、表格内降为 -1.8 防糊
  fallbackSafePadPt  // Emoji / 生僻字 / 数学符号回退字框安全边距 (+2.0pt)，只保护不强制裁剪
  paragraphScale     // 换大字面/紧凑字体时按比例保持段落间白，确保呼吸节奏不断
}
```

---

### 4.4 替换旧 `extraSpacing`：统一 `SafeLineBox` 安全行框计算器

**直接替换** [Pref.swift:81](../../../App/Sources/Design/Pref.swift#L81) 与 [Ink.swift:573](../../../App/Sources/Design/Ink.swift#L573) 的 `max(0, size * m - natural)`（禁止同时保留两套职责相同的排版计算引擎）：

```swift
// 单一真理排版行框解析器（伪代码契约，正式工程合入时直接替换 Pref.leading / Ink.leading）
let profile = FontOpticalProfile.resolve(for: face)
let effectivePt = (userReadingSize * profile.opticalScale * 2).rounded() / 2   // 半点步进锁定清晰栅格
let resolvedFont = Ink.uiFace(effectivePt, face: face)

let naturalBox = ceil(resolvedFont.ascender - resolvedFont.descender)          // 实测字面物理安全下限
let targetLineHeight = userReadingSize * contentMultiplier + profile.lineHeightOffset
let safeMinimumLineHeight = max(targetLineHeight, naturalBox + profile.fallbackSafePadPt)

paragraphStyle.minimumLineHeight = safeMinimumLineHeight
paragraphStyle.maximumLineHeight = 0   // 严禁设小额 maximumLineHeight！允许个别复杂数学/Emoji自然撑开绝不裁切头脚
paragraphStyle.lineSpacing = max(0, (safeMinimumLineHeight - resolvedFont.lineHeight) * 0.35)
```

---

### 4.5 全场景渲染一致性与缓存失效铁律

以下 **9 处全部共用同一个 `ChatResolvedMetrics + FontOpticalProfile` 解析结果**：
`CoreText 瓦片正文` · `ChatProseBuilder` · `ChatResolvedMetrics` · `ProseView (SwiftUI)` · `用户消息气泡 (userBody)` · `正文长按选字模式` · `流式 Markdown 渲染` · `定稿态 Markdown` · `设置 › 字体与版式实时小样`。

**硬性禁止与缓存失效规则**：
1. 严禁流式阶段用系统字体、定稿再切自定义字体导致高度/字重跳变；
2. 严禁选字模式下文字大小或行距发生变化；
3. 按需字体 (`FontShelf`: 宋体/楷体) 下载完成、或切换 `readingFace / readingSize / lineHeight / paragraphGap / DynamicType` 时，**必须递增 `fontEpoch` 并清理文本高度与瓦片缓存**（缓存键必须包含 `face.rawValue + fontEpoch + sizeKey + lineHeightKey + widthKey + axKey`，绝不让旧字体缓存串用到新字体上）；
4. 禁止在滚动主线程（`cellForItemAt`）临时测算字框；
5. 代码、路径、URL、命令、数学公式内**禁用中西混排 `.kern` 光学微距**，确保等宽与语义精确。

---

### 4.6 字体光学校准统一验收样本（原型对照基准）

> 以下样本原字作为原型「5 组字体光学对照」面板与未来真机 QA 的固定测试语料。**注意：Web 原型字体度量不能等同 iOS CoreText 真机度量，最终参数一律以实机 CoreText 渲染裁决。**

```markdown
Clio 使用 SQLite FTS5 实现长期记忆检索，并通过 UICollectionView 与 CoreText 优化长对话渲染。支持 120 Hz ProMotion，目标单帧预算约为 8.33 ms。当前模型 Claude Sonnet，已调用 3 个 MCP 工具，累计使用 12,840 Tokens。「中文引号」、“英文混排”、数字 0123456789、全角标点、**粗体**、*斜体*、Emoji 🐱、特殊符号 ≈ ± √，以及 `API.status = 200`。
```

（原型内已同步附带真实 H1–H3 标题、3 级列表、数值右对齐 Markdown 表格、数学公式、`swift` 代码块与长 URL：`https://github.com/lllhr94/Clio/blob/batch-0.36/App/Sources/Reading/ChatListUIKit/ChatListModels.swift`）

# 扩库深度研究卡：全球 AI 客户端、开发者规范与国产 OS 深度补充（Deliverable #1/#2 扩编）

> 严格执行任务书第十八节研究卡结构（18 个规范字段）与 7 级证据标签（`[1 官方规范] / [2 官方演示] / [3 实际使用] / [4 官方奖项] / [5 第三方评测] / [6 主观推断] / [7 未验证假设]`）。本卷与前卷 `01`–`04` 合并构成 Clio DS 2.0 完整全球+国内+系统级研究卡库。

---

## 卡 1：Linear Mobile & Design Refresh (`2024–2026`)
- **产品及版本**：Linear iOS + Web UI (2026-03 Refresh) · **调研日期**：2026-11-25
- **官方来源与实际观察**：`https://linear.app/mobile`, `https://linear.app/now/a-design-reset`, `behind-the-latest-design-refresh` (`[1][2]`)
- **排版/色彩/布局/层级**：极克制 LCH 微暖中性灰/纯黑，去除了团队图标的彩色衬底与繁重分割线（“Structure should be felt not seen”）；等宽副元数据精确对齐；移动端高密度但行距洁净。
- **操作路径与动效**：侧栏 Chrome 降噪让位给工作区；滑动操作跟手流畅；专门为「人+Agent 并行协同」重整界面结构。
- **优缺点**：优点是全站一致性与零噪音高效率；缺点是全暗偏理性冷峻，缺长期生活陪伴感。
- **Clio 借鉴与忌抄**：学其「Chrome 退让给正文」「0.5pt 轻边框」「为 Agent 而生的简洁结构」用于 **侧栏与方向 B 工具轨**；忌照抄冰冷工单感进入日记/晨信。
- **对应页面 & SwiftUI 可行性**：`DeskSidebarView.swift`, `ChatTrace.swift`, `HillsPage.swift` · 原生完全可行。

## 卡 2：Raycast iOS & Raycast AI
- **产品及版本**：Raycast for iOS · **调研日期**：2026-11-25
- **官方来源与实际观察**：`https://www.raycast.com/ios` (`[2]`)
- **排版/色彩/布局/分类**：极深炭黑底 (`#070707 / #141416`)，顶部悬浮大圆角搜索栏带左右单图标（过滤/头像），下拉即搜；下方 4 格圆角方砖 (`AI / Notes / Quicklinks / Snippets`) + 单行高密 Favorites 列表。
- **操作路径与动效**：支持按住 Whisper 语音速记、Shortcut/Control Center 直达；不离开聊天切换多模型。
- **Clio 借鉴与忌抄**：学其「顶部跨库统一搜索」「清晰的功能快捷键阵」用于 **`UnifiedGlobalSearchSheet`** 与设置别名秒搜；忌照搬极暗单调黑灰底作默认阅读模式。
- **对应页面 & SwiftUI 可行性**：侧栏头部、模型切换、设置搜索 (`SettingsView.swift`) · 原生完全可行。

## 卡 3：Halide (Mark III)
- **产品及版本**：Halide Mark III (iOS) · **调研日期**：2026-11-25
- **官方来源与实际观察**：`https://halide.cam/` (`[2]`)
- **排版/色彩/布局**：OLED 纯黑外框衬出主题取景框，定制等宽刻度技术字体；底部三层拇指热区精确排布。
- **手势与触觉**：单指上下滑控曝光、左右滑控对焦的实体拨盘隐喻，真机 Taptic 反馈在实机未测前标为 `[5][7]`。
- **Clio 借鉴**：Clio 的 **`StopRow / StopRuler`** 已深得真传——DS 2.0 为其加入「默认推荐档位加重一档 `detent`」即可比肩。

## 卡 4：iA Writer / Typora / Craft / Obsidian（正文、文档与知识库四大标杆）
- **调研日期**：2026-11-25 · **来源**：`craft.do/zh-CN`, `ia.net/writer/zh-hans`, `typora.io`, `obsidian.md` (`[2]`)
- **核心拆解**：
  - **Craft**：浅色圆角文档卡片内直接预览嵌套 checklist 与排版（借用于 Clio 首页精选与书案笔记卡）；
  - **iA Writer**：零干扰纯白排版 + 聚焦模式调暗非当前段 + 人类/AI 段落标注（映射 Clio 记忆来源标识 `AI 自动 vs 用户手写`）；
  - **Typora**：无预览分栏的所见即所得流式排版（与 Clio 追求「流式到定稿零闪跳」完美一致）；
  - **Obsidian**：1px 线框划分多栏知识库 + 移动端干净的两端顶栏按钮，忌把复杂桌面图谱直接搬上手机。
- **对应页面**：`ChatProseRenderer.swift`, `StudyPage.swift`, `MemoryPageV2.swift`。

## 卡 5：Claude / ChatGPT / Claude Code / Codex / Perplexity / Gemini / Pi / Open WebUI / Cherry Studio / Chatbox / openhanako
- **调研日期**：2026-11-25 · **来源**：`doubao.com/chat/`, `chatboxai.app/zh`, `github.com/CherryHQ/cherry-studio`, `open-webui`, `openhanako` (`[2][3]`) + `Claude Code / Codex` `[5]`
- **核心机制汇总**：
  1. **Claude Code 审批疲劳教训 (`[5]`)**：频繁弹窗审批会导致 90% 用户麻木乱点「允许」，从而彻底架空安全！因此 Clio 0.36 已做 `GrantsPage` 四档预设 + `Taint.hardExits` 外网读后强截，DS 2.0 再以左标签右等宽结构提升“单次扫一眼风险即懂”的速度，**绝不靠减少真高危审批来换省事**。
  2. **Codex / Manus 任务产物视角 (`[2][5]`)**：不把终端 stdout 和文件修改散落成 20 条碎气泡，将命令输出裁剪折叠 (`ToolTail` + `ChatTrace` 产物流清单汇总)。
  3. **Cherry Studio / openhanako 分类启发 (`[2][3]`)**：`Cherry Studio` 把「模型(云/Ollama) / 助手 / MCP / Skills / 知识库 / 语音」拆出清晰边界；`openhanako` 提出「Chat + Small Tool + Large Tool」模型按角色分配与「书桌+笺」暖色概念。Clio DS 2.0 在模型设置分组清晰采用「默认 / 备用 / 记忆整理 / 生图」四角色映射。
  4. **Doubao / ChatGPT / Pi 语音交互 (`[2][3]`)**：长按/单点语音波形状态清晰直接、随时可打断、且遵循 HIG 语音开启时强制物理停振。

## 卡 6：Arc Search / Fantastical / Reeder / Sofa / Blackbox / CARROT / Monument Valley / Sky 光·遇 / 终末地 / B站 / 小红书 / 微信
- **证据等级说明**：其中 `Fantastical / Blackbox / CARROT / Monument Valley / Sky / Arc Search` 以官网及 Apple 获奖/公开交互解析为依据 `[4][5]`；`Reeder / Sofa` 同理 `[5]`；`终末地 / 微信 / B站 / 小红书 / 通义千问` 为行业特征分析与公开评测总结 `[5][6]`。
- **逐项吸收与克制守卫**：
  - **Arc Search**：单手底部控制与「捏合/一键总结」（启发光速召唤内嵌 `RoamChrome`）；
  - **Reeder**：靠字色深浅区分状态而非堆砌红点徽章；
  - **Fantastical / Figma / Vercel**：极度克制的左窄语义竖线 + 等宽信息列（映射方向 B 左轨时间轴与 `UsageSheet`）；
  - **Blackbox / CARROT / Not Boring**：极具个性的硬件/声音彩蛋与情绪文案（Clio 只取小克戳醒的极克制瞬间与低频率幽默，绝不把核心 AI 工具变成喋喋不休的吐槽机）；
  - **《明日方舟：终末地》/ 小红书 / B站 / 微信**：终末地体现「极强工业 HUD 字体与物理声效同步哲学」，Clio 不抄其科幻游戏壳，但方向 B 可借鉴其精准等宽仪态；微信的对话极简置顶与小红书高密度图文混排（提示书案文件网格可参考更清晰图题分离）。

## 卡 7：W3C CLREQ & 四大 OS & 三大国内工程设计体系 + Apple WWDC 21–25 规范
- **来源 (`[1]`)**：`w3.org/TR/clreq/`, `vivo.com.cn/originos/`, `developer.huawei.com/consumer/cn/design/`, `coloros.com`, `hyperos.mi.com`, `ant.design/docs/spec/motion-cn`, `tdesign.tencent.com`, Apple HIG Motion/Haptics & WWDC23 `10158`, WWDC21 `10278`, WWDC21 `10252`, WWDC25 `284 & 323`。
- **最关键的工程与设计合流**：
  1. **W3C CLREQ**：中文标点禁则「先挤进后推出」+ 相邻标点缩窄至 `1.5em` + 中西字符 `≤1/4em` 视图层纯视觉字距；
  2. **OriginOS + ColorOS + HarmonyOS + Ant Design Motion**：处处手势打断、释放速度无缝继承、退场更快于进场且无排队滞后、`150–250ms` 短距微反馈；
  3. **Apple WWDC25 `284/323` & Materials**：**`Don't use Liquid Glass in the content layer`** —— 保护 `ChatListViewController` 120Hz `CoreText` 瓦片管线只把实时玻璃放在悬浮顶部与底部控制栏，正文字海完全纯净快速。

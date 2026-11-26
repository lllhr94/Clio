# Clio DS 2.0：Telegram 原版源码移植方案与私人网络/Fake-IP 统一安全架构

> **基线锚点**：设计分支 `design/v2-review` · 生产分支 `batch-0.36` (`ee034ac857169090f6f972a6103f0c02201628ab`) · Telegram 上游仓库 `https://github.com/TelegramMessenger/Telegram-iOS` 固定提交 `24638bc69bd083981b178dd1e7f921eebbf7fc46`。
> **核心方针**：本文件确立 **Telegram 原版核心渐显源码移植路线** 与 **个人 Agent 私人网络及 Fake-IP 统一授权安全模型**，不修改生产 Swift 代码，不另建平行权限体系或平行重构路线图。

---

## 第一部分｜Telegram 上游源码许可证核查与模块移植架构

### 1.1 固定提交 `24638bc69bd083981b178dd1e7f921eebbf7fc46` 许可证与依赖核查

| 核查项目 | 实测事实（经 GitHub API 与源码全文核对） | 对 Clio (`GPL-3.0`) 的合规含义 |
|---|---|---|
| **仓库根许可证字段** | `gh api repos/TelegramMessenger/Telegram-iOS` 返回 `"license": null`；根目录无 `LICENSE` / `COPYING` 文件，仅存 `README.md` 与 `third-party/` 下 34 个第三方许可证。 | 不能仅按“仓库根目录有 GPL 文件”推定全部子模块一致，必须逐模块核验上游条款。 |
| **根目录 `README.md`** | 第 12 行明确写明 *"Please remember to publish your code too in order to comply with the licences."*，其余为应用名称/图标/`api_id`/安全指南。 | Clio 为开源 `GPL-3.0` 客户端并完整发布源码，满足发布源码义务；Clio 仍禁用 Telegram 名称与纸飞机图标。 |
| **目标 7 份核心 Swift 文件头** | 已检查 `TextRevealController.swift`、`InstantPageV2RevealCost.swift`、`InstantPageRenderer.swift`、`InstantPageV2Layout.swift`、`InteractiveTextComponent.swift`、`ChatMessageTextBubbleContentNode.swift`、`ChatMessageRichDataBubbleContentNode.swift`：文件头均无独立 SPDX/版权注释，首行即 `import`。 | 需依据官方声明与模块级 `BUILD` 依赖树判定兼容性。 |
| **官方文档声明** | Telegram 官方客户端页 (`telegram.org/apps`) 明确标注 Telegram for iOS 采用 **`GNU General Public License v. 2 or later` (`GPL-2.0-or-later`)**。 | **`GPL-2.0-or-later` 可升级兼容 `GPL-3.0`**（依 GPLv2 第 9 条及 GPLv3 第 7 条），在保留来源说明与修改记录前提下允许移植进入 Clio。 |
| **`StreamingTextReveal` `BUILD` 依赖** | `submodules/TelegramUI/Components/StreamingTextReveal/BUILD` 声明 `deps = []`，仅 `import Foundation`，**零 TelegramCore / SwiftSignalKit / ASDK / 第三方依赖**。 | **100% 清爽可直接原版复用**，无传递许可证污染风险。 |
| **`InstantPageUI` 与 `InteractiveTextComponent` `BUILD`** | `InstantPageUI/BUILD` 依赖 33 个内部/第三方 Bazel 目标（含 `TelegramCore`、`AsyncDisplayKit`、`SwiftSignalKit`、`Display`、`third-party/SwiftMath`、`InvisibleInkDustNode` 等）；`InteractiveTextComponent/BUILD` 依赖 12 个目标。 | **严禁整包或整文件直接搬入 Clio**：必须只抽离纯算法与局部遮罩/层结构，并将外部辅助能力转为向 Clio `CoreText` / `ChatListUIKit` 适配器注入。若某一关联辅助模块的传递许可存疑，暂停复制该辅助代码。 |

**独立隔离存放与维护规范**：
- 原版复用源码统一落于 `App/Sources/Reading/ThirdParty/TelegramReveal/`，并附 `UPSTREAM.md` 固定记录：上游仓库 URL、固定 Commit `24638bc69bd083981b178dd1e7f921eebbf7fc46`、原文件路径、官方 `GPLv2 or later` 授权依据、在 Clio `GPL-3.0` 下兼容声明，以及相对原版的逐行改动清单。
- **优先零改动保留原版文件名与核心算法**（如 `TextRevealController.swift`），通过 Clio 外部协调适配器注入布局与渲染数据，严禁无意义重命名以便日后比对和同步上游修复。

---

### 1.2 Telegram 原版核心模块 5 列依赖与可复用性分析表

| 原版模块（固定提交 `24638bc`） | 直接依赖 | 可直接复用范围 | 需要适配的范围 | 不能整文件复用的原因 |
|---|---|---|---|---|
| **`TextRevealController.swift`** *(L1–90, StreamingTextReveal)* | 仅 `Foundation`（`deps = []`） | **全部直接原样复用**（EWMA 间隔 `gapEwmaAlpha = 0.4`、`velocityTau = 0.12s`、`initialGap = 0.5s`、`stallFloor = 0.10s`、`finalizeTime = 0.3s`、`frameDtCap = 0.05s`、`initialInputRate = 40.0`、`durationMultiplier`、`observeUpdate` / `finalize` / `tick`） | 在外部创建轻量协调器驱动 `CADisplayLink`、注入后台暂停 (`scenePhase`)、`Reduce Motion` / `Pref.fade` 直出与 `停止生成` | 本身无阻塞或无关依赖，唯独不含调度循环、中断状态与设置开关，应放外部适配层 |
| **`InstantPageV2RevealCost.swift`** *(L1–570, InstantPageUI)* | `Foundation`, `UIKit`, `QuartzCore` 及同模块 `InstantPageTextItem` / `InstantPageV2LaidOutItem` 等内部模型 | 宽度揭示成本模型：`textInkWidth` 按字符边界框宽度累加、`itemWidthCost` 非文本块取框宽、思考块 0 成本、`charCountForWidthBudget` 将 `points` 预算折算为可见字符索引 | 将输入结构从 `InstantPageV2LaidOutItem` 适配为 Clio 的稳定语义块（`ChatProseBuilder` 文本/代码/表格/数学块与 `CTLine` 字符框表） | 强耦合 `InstantPage` 页面模型、`InstantPageV2TableView` 与新闻折叠块类型 |
| **`InstantPageV2Layout.swift`** *(`computeRevealCharacterRects` L4645–4718)* | `CoreText`, `UIKit`, `Display`, `TelegramCore`, `TextFormat` 等 | **核心字形墨迹框算法**：使用 `CTRunGetGlyphs`、`CTRunGetPositions`、`CTRunGetStringIndices` 与 `CTFontGetBoundingRectsForGlyphs` 在行内坐标计算每个 UTF-16 位置的精确 `characterRects`，并区分连字延续槽（`CGRect.zero`）及内嵌 Emoji/图片全宽格 | 适配到 `ChatProseBuilder` / `ChatTextTileRenderer` 预排版线程产出的行结构，同时加挂 `Swift` `Character` / 图素簇（`emoji` + ZWJ + 组合音标）防半截切分守卫 | 整文件 5,000+ 行绑定 Telegram 网页排版与媒体实体体系 |
| **`InstantPageRenderer.swift`** *(`SnippetLayer` L1944–1965, `computeRevealedLines` L1526–1570, `updateRevealMask` L1704–1760, `updateRevealCharacterCount` L1625–1698)* | 20 个 `InstantPageUI` 依赖（含 `AsyncDisplayKit`、`TelegramCore`、`Display` 等） | **核心图形遮罩机制**：将行内已完全揭示部分与跨多行全亮前缀合并为最少数量的 `revealMaskLayer`（单图层收拢全亮前缀）；前沿未满字符通过 `SnippetLayer` (`contentsRect` 裁出纹理子块) 在 **`0.20s` Alpha/位移/缩放 + `0.22s` Blur (`2.0 -> 0`)** 动画完成后并入遮罩并移出子图层 | 将 `renderView.layer.contents` 替换为 Clio `CoreText` 瓦片 `CGContext` 位图或文本图层，用纯 `UIKit` / `CoreAnimation` 替换 `ComponentTransition` 与 `SimpleLayer`，并在速度突变/减动效下跳过 `SnippetLayer` | 直接耦合 `ASDisplayNode`、`ComponentFlow`、Telegram `WallpaperBackgroundNode` 与网页媒体引用 |
| **`InteractiveTextComponent.swift`** *(`SnippetLayer`, `revealMaskLayer`, `updateRevealMask` L2870–3150)* | 12 个依赖（含 `ASDisplayKit`, `Display`, `ComponentFlow`, `TextFormat`） | 普通文本容器遮罩降本方案与 `updateRevealMask` 逐行合并优化 | 与 `InstantPageRenderer` 同理，只提取无第三方 UI 框架绑定的 `CALayer` 前沿遮罩逻辑 | 强绑定 `ComponentFlow`、`AppBundle` 与 Telegram 文本交互组件树 |
| **`ChatMessageTextBubbleContentNode.swift`** *(L1014–1089) & **`ChatMessageRichDataBubbleContentNode.swift`** *(L1615–1741)* | 31 / 21 个高层聊天 UI 依赖（`ASDK`, `AccountContext`, `TelegramCore`） | **接入时机与高度边界策略**：草稿流属性变动驱动 `TextRevealController`、`SharedDisplayLinkDriver`、`isFinalizing` 收尾清理；仅当揭示前缀跨越行高边界时才触发容器高度重算；普通文本传 `durationMultiplier: 1.0`、富排版按需调整倍率 | 以 Clio `ChatListViewController` 与 `ChatTextTileRenderer` + `ChatResolvedMetrics` 接入，配合 `ChatFollowState` 与 `Scroll-Aware Chrome` 协调选区和锚点 | 绑定 `AsyncDisplayKit` 消息气泡节点与 Telegram `TypingDraftMessageAttribute` |

---

### 1.3 揭示成本单位纠偏：Points（墨迹/盒宽）取代单纯字符簇计数

1. **原版为何用 `points`（字体墨迹与布局宽度）而非“字符簇数”**：
   - 在 v14 原型中，`ClioRevealController` 为适应无 CoreText 的浏览器 DOM，使用了 `Intl.Segmenter` 图素簇数量作计量单位；而 Telegram 上游在 `InstantPageV2RevealCost.swift` 与 `ChatMessageRichDataBubbleContentNode.swift` 中使用 **真实布局宽度（`points`）**：
     * 文本行按 CoreText 实际字形墨迹框 (`CTFontGetBoundingRectsForGlyphs`) 累加真实水平跨度；中文全宽、英文窄字符、代码等宽与数学符号自然消耗不同“成本”，**视觉推进速度（`points/s`）因此稳定均一**；
     * 代码块与非文本块取框宽（`frame.width`）；思考指示成本 `= 0` 不卡文本节奏。
2. **原生实现边界保护**：
   - 保留图素簇/UTF-16 边界映射：先以 `Character`（扩展字形簇，覆盖 ZWJ 家庭 Emoji、肤色修饰、组合音标与连字槽）映射到连续 UTF-16 `NSRange`，取该簇首字形到末字形的联合宽度成本，**绝不从多字节字符或连字中间切断渲染或遮罩**；
   - **参数再校准警告**：
     * `TextRevealController.swift:8` 的 `finalizeTime = 0.30s` 是速度分母而非“硬等 300ms 才完成”；原生直接保留 Telegram 原值 `0.30`，除非真机 A/B 实测证明需调整；
     * `ChatMessageRichDataBubbleContentNode.swift:1666` 对宽度成本传入了 `durationMultiplier: 10.0`（因 1 字在 `17pt` 下约占 `10–17pt` 宽，`points / durationMultiplier` 才能将速度量化到相近视觉步幅）；
     * 原型曾设 `80 图素簇/秒` 自动关闭模糊柔边，这相当于约 `800–1360 points/s` 而非 `80 points/s`——**严禁将 `80 图素/秒` 机械写成 `80 points/s`！** 必须在真机 CoreText 上以中英代码实测 `TTFT`、积压（`backlog`）、`points/s` 分布再敲定模糊熔断阈值。

---

### 1.4 Clio 原生正式接入管线（100% 保护 0.36 UIKit 架构）

```text
LLM / SSE Chunk Stream
        ↓
Clio 容错增量 Markdown 解析器（前缀安全 · 不死循环 · 原文零丢失）
        ↓
Stable Blocks / Layout Snapshot（与 FontOpticalProfile + SafeLineBox 一致；已闭合块保持 ID 稳定）
        ↓
Telegram RevealCost Adapter（Points 宽度成本映射 + 图素簇/连字不切断守卫）
        ↓
Telegram TextRevealController（App/Sources/Reading/ThirdParty/TelegramReveal/ 原样核心）
        ↓
Telegram Glyph Reveal / revealMaskLayer + 可降级 SnippetLayer（Pref.fade / ReduceMotion / 突发 / 后台门控）
        ↓
Clio CoreText Rendering Adapter（前沿遮罩层合入瓦片绘制与选中文本状态锁）
        ↓
ChatListViewController (UICollectionView) + ChatTextTileRenderer + ChatFollowState + ChatChromeCoordinator
```

**严禁事项**：不得退回 WebView 渲染正文；不得每 token 重建整条 Cell；不得每帧重解析全文 Markdown 或全量重栅格化；不得对已揭示稳定字符重复播动画；不得用顶层 `@Observable` 高频广播触发整个 `UICollectionView` 整表重刷。

### 1.5 最小可丢弃原生验证工程设计（`experiments/TelegramRevealSpike/`）

已在设计分支建立完全独立、可丢弃（零接入、零修改 `App/Sources/` 与 `AgentKit/Sources/`）的 Swift Package 实验工程 [`design/design-system-2.0/experiments/TelegramRevealSpike/`](../experiments/TelegramRevealSpike/Package.swift)，并配置独立 macOS + iOS Simulator CI 工作流 `.github/workflows/ds2-reveal-spike.yml`：

1. **上游原样核查隔离**：[`Sources/TelegramRevealUpstream/TextRevealController.swift`](../experiments/TelegramRevealSpike/Sources/TelegramRevealUpstream/TextRevealController.swift) 逐字节原样复制自 Telegram-iOS `24638bc69bd083981b178dd1e7f921eebbf7fc46`（仅 `import Foundation`），并在 [`UPSTREAM.md`](../experiments/TelegramRevealSpike/UPSTREAM.md) 登记许可证依据、上游路径与最小改动清单；
2. **CoreText `Points` 成本与遮罩适配实测**：`ClioRevealSpike` 在 macOS (`swift test`) 与 iOS Simulator (`xcodebuild test`) 双平台验证 `CTFontManagerCreateFontDescriptorsFromURL` 加载仓库真实 `App/Fonts/ClioKai-Medium.ttf`、`SafeLineBox`、`ClioMixedScriptKerning`（已有空格零叠加）、`computeRevealCharacterRects`（中文 / 英文 / ZWJ Emoji / 肤色 / 组合音标 / `fi` 连字 / 代码 / 表格 / 公式不切断）、`revealMaskLayer` 整行合并与 `SnippetLayer` 降级、完整流式生命周期与阅读锚点锁；
3. **可复现执行入口与真机分界**：
   - macOS 单元测试：`cd design/design-system-2.0/experiments/TelegramRevealSpike && CLIO_REPO_ROOT="$(git rev-parse --show-toplevel)" swift test`
   - iOS Simulator 集成测试：`gh workflow run ds2-reveal-spike.yml --ref design/v2-review`（或推送触发运行 `xcodebuild test`）；
   - 本节在 macOS CI 与 iOS Simulator 验证完成后回填实测编译通过率、`Points/s`、`durationMultiplier`（`1.0` vs `10.0`）与帧耗时分布；**Simulator 实测仍不等同于实体 iPhone 120Hz ProMotion 真机最终体验，真机验证另见 Deliverable #21**。

---

## 第二部分｜Fake-IP 与私人网络访问统一权限与安全架构

### 2.1 `batch-0.36` 全仓库网路与授权现状核查

对仓库 `App/Sources` 与 `AgentKit/Sources` 全量搜索 `LocalAddress`、`SearXNGEndpoint`、`PermissionGate`、`Taint` 与 `Hills`（共定位 **8 组网络防线调用点** + **SearXNG 局域网特例**）：

| 代码模块与精确位置 | 当前安全检查 | 与私人网络 / Fake-IP 的真实冲突与可复用基础 |
|---|---|---|
| [Web.swift:549-591, 740-789, 2022-2136](../../../AgentKit/Sources/AgentKit/Web.swift#L2022-L2136) | `LocalAddress.isLocal` / `resolvesToLocal` 拦截内网 hostname（含无点号/ `.local` / `.lan` / `.internal`）及 `isLocalV4` 包括 **`198.18.0.0/15`** 与 **`100.64.0.0/10` (CGNAT/Tailscale)**、私网与链路本地 | ① 开启 Clash/Mihomo/Surge TUN Fake-IP 时，公网域名经系统 `getaddrinfo` 解析落入 `198.18.0.0/15`，导致 `web_search` 与 `web_read` 误报本机/局域网拒绝；② 访问 NAS、局域网 Hermes/MCP/HTTP API 或 Tailscale (`100.64.0.0/10`) 目标也被无差别一刀切拦截 |
| [Web.swift:600-689, 818-1058](../../../AgentKit/Sources/AgentKit/Web.swift#L818-L1058) & [SearchSettings.swift](../../../App/Sources/SearchSettings.swift) | **`SearXNGEndpoint` 已存在受控局域网例外模型**：显式区隔 `isAllowedLANHost`，仅对用户配置并绑定 `originKey` (`scheme://host:port`) 的私网 SearXNG 放行同源请求与 HTTP，且禁止含认证头走明文 HTTP、禁止跳转他域 | **直接可借鉴与收拢的模式范本**：证明仓库已认同“用户明确配置并绑定 Origin 的局域网服务可放行”，而非粗暴删除内网校验 |
| [Hills.swift:639-650, 748-763](../../../App/Sources/Hills/Hills.swift#L639-L650) & [MCPAuth.swift:135-138, 299-308](../../../App/Sources/Hills/MCPAuth.swift#L135-L138) | 未走远山 SSH 隧道的 MCP 服务硬要求 `https://` 且禁 `LocalAddress.isLocal` / `resolvesToLocal`；经 SSH 隧道 (`Tunnels.swift`) 则允许映射到本地 loopback | 连接内网自托管 HTTPS 或明确授权内网 MCP（如家庭 NAS / Hermes）目前若不开 SSH 隧道会被 `LocalAddress` 拦截 |
| [Roam/Browser.swift:263-271, 618-669](../../../App/Sources/Roam/Browser.swift#L263-L271) | 浏览器 Agent 工具操作中禁止跳转/打开 `LocalAddress.isLocal` / `resolvesToLocal` | 保护公网浏览不被脚本引流到路由器/NAS 管理后台；若用户明确授权访问某内网管理端，应有显式、有范围、受 `Taint` 保护的放行途径 |
| [SkillInstaller.swift](../../../App/Sources/SkillInstaller.swift) / [BrandIcon.swift](../../../App/Sources/Design/BrandIcon.swift) / [ProseView.swift:2058](../../../App/Sources/Reading/ProseView.swift#L2058) / [ChatBlockViews.swift:1992](../../../App/Sources/Reading/ChatListUIKit/ChatBlockViews.swift#L1992) | 分别保护技能安装 URL、品牌图标拉取、外链图片预加载不落入内网 | 保持默认严格 SSRF 防护；外链图片与图标拉取永不允许借用私人网络权限 |
| [Grants.swift](../../../App/Sources/Grant/Grants.swift)、[PermissionGate.swift](../../../AgentKit/Sources/Craft/PermissionGate.swift)、[Taint.swift](../../../AgentKit/Sources/Craft/Taint.swift) | 已有统一 `Grant`、`LiveGatedTool`、`HostBindingBook`（切换工作地点立刻失效旧工具实例）、`PendingApprovalQueue.reconcile`（政策收紧即时唤醒拒批）、`TaintGuard` (`hardExits`) | **核心可扩展基座**：严禁新建第二套平行权限机制，直接扩展 `PermissionGate` 目标作用域与 `Grant` 体系 |

---

### 2.2 五类网络访问域模型与严格分级定义

将“私人代理”、“用户私人设备”与“公共互联网络”彻底解耦为 **5 个独立访问域**：

| 网络域类别 | 典型场景 | 路由与身份特征 | 默认安全策略 |
|---|---|---|---|
| **1. 正常公网访问 (`public`)** | `web_search`、`web_read`、公网 API/MCP、`BrandIcon`、远程图片 | DNS 返回真实公网 IP，HTTPS 优先 | 允许直接访问；重定向锁同源或公网（`StayPublic`），严禁跳入私网/IMDS |
| **2. 代理感知 Fake-IP 公网访问 (`fakeip_proxy`)** | 用户手机开启 Clash / Mihomo / Surge TUN Fake-IP 节点做公网搜索与网页读取 | URL 为公网域名（含合法 TLS SAN 证书校验），系统 `getaddrinfo` 返回 **`198.18.0.0/15`**（偶含 RFC 6598/IPv6 代理占位或混合 DNS） | **绝不直接删除 `198.18.0.0/15` 防护**；按 §2.3「可信代理兼容模式与目标验证契约」核验或明确诊断 |
| **3. 用户授权私人设备与内网服务 (`authorized_private`)** | 家庭 NAS、局域网 Hermes、自托管 SearXNG、内网 MCP、私人 HTTP/HTTPS 服务 | 目标处于私网 IP、`100.64.0.0/10` 或 `.local` / `.lan` / `.home.arpa` / 自定义私有域名 | **默认全部拒绝**；仅命中用户显式登记的**持久作用域授权项**（目标+端口+动作等级）时按策略放行/询问 |
| **4. 私有组网环境 (`private_mesh`)** | Tailscale (`100.64.0.0/10` + MagicDNS `*.ts.net`)、WireGuard 内网 | 经 VPN 虚拟网卡走加密 Overlay 点对点可达 | 归入受授权管理的私人端点池（可按组网网段/特定服务白名单独立授权，提示大范围网段风险） |
| **5. 远山 SSH 与跳板机 (`ssh_workplace`)** | 内网 SSH 主机、Tailscale SSH、经 Bastion/跳板机进目标服务器、SSH 本地端口转发隧道 | `Hills` + `Citadel` + `HostKeyKeeper` 公钥指纹 + `HostBindingBook` | 已授权的 SSH 主机**不受公网 `Web` 工具地址限制机械阻断**；命令/文件工具绑定具体工作地点与主机指纹 |

---

### 2.3 Fake-IP 可信代理兼容契约（禁止削弱 SSRF 边界）

**明确否决的伪安全做法**：
- **禁止**仅凭 `utun` 网卡存在、外部 DoH 解析拿到公网 IP 或 TLS 域名/证书验证通过，就宣称已经验证了最终连接目标的真实网络位置（普通系统 VPN/公司内网 VPN/iCloud 专用代理也会挂 `utun`；若代理分流规则将该公网域名内部改指局域网 IP，客户端 DoH 与实际流向依然可能不一致；TLS SAN 校验也只能证明对端持有证书，无法在用户空间反查 VPN 内部分流表）；
- **禁止**直接把 `198.18.0.0/15` 从 `LocalAddress.isLocalV4` 删掉。

**工程可行且诚实的设计**：
1. **双通道预检与严格特征识别**：
   - 将 **`198.18.0.0/15`** 与普通内网私网（`10/8`、`172.16-31/12`、`192.168/16`、`127/8`、`169.254/16`）在分类函数 `LocalAddress.classify(...)` 中显式拆分为 `.fakeIPRange` vs `.privateLAN` vs `.cgnatMesh` vs `.loopbackOrMetadata`；
   - **明确识别范围上限与安全隔离**：在 iOS 沙盒 + `URLSession` 下，App 无法读取第三方 VPN/`NEPacketTunnelProvider` 的内部分流表，因此客户端不声称密码学证明 `198.18.x.y` 在 TUN 内部绝不回环；**真实内网设备授权（Domain 3/4）与可信公网 Fake-IP 兼容（Domain 2）保持严格架构隔离**。
2. **显式「可信代理兼容模式（Fake-IP 公网访问）」安全契约**：
   - 当用户（在设置中经明确风险说明）**主动开启「我在使用代理 Fake-IP（允许公网域名经 198.18.0.0/15 通道联网）」**：
     * **仅适用于**：原始 URL 拥有**非私有公网格式域名**（非 IP 字面量、`localhost` 或 `.local`/`.lan`/`.internal`/`.home.arpa`）、采用 **`https://`（或按需公网 `web_read` 受控 HTTP 且禁发凭证）**，且 **`getaddrinfo` 仅在 `198.18.0.0/15` 内返回占位地址**（若混合 DNS 同时混入 `10.x` / `192.168.x` / `127.x` / `169.254.x` / IPv6 ULA，立即判定混合 DNS 风险拒绝！）；
     * **强约束校验**：保留系统原生 `URLSession` 强制 TLS 证书链与 SAN **公网域名匹配校验**（内网设备通常无法伪造受信任公共 CA 对该公网域名签发的有效 TLS 证书）；每一跳 **HTTP 重定向必须经委托重检**，一旦跳往字面私有 IP、云元数据 `169.254.169.254` 或私有域名立即拦截，跨域强制剥离 `Authorization` 与 `Cookie`；
     * 若目标并非上述情形，或在未开启 Fake-IP 兼容时命中 `198.18.0.0/15`，**不得静默失败**，而是输出清晰的 **6 分类精确诊断**（见 §2.6）。

---

### 2.4 基于现有 `PermissionGate` 的私人网络分级持久化授权

**直接扩展现成底座（零平行权限架构）**：
1. **作用域资产描述 (`PrivateNetworkGrant`)**（纳入现成持久化设置 + `PermissionGate` 审批与即时撤销队列 `PendingApprovalQueue.reconcile`）：
   - **允许授权形态**：① 已配 `Hills.Host` / `Hills.Server` (MCP) / 已配 `SearXNGEndpoint`；② 明确指定的 **`host[:port]`**、私有域名（如 `nas.local`、`hermes.ts.net`）；③ 受控范围 **CIDR**（配置宽网段如 `192.168.1.0/24` 时必须弹显式高风险提示，禁止一键默认放开整张 `0.0.0.0/0` 或全部私网）。
   - **能力正交拆分与副作用独立判断**：每个授权独立表达允许或需询问的动作：`reach`（网络可达与连接） · `read`（只读查询） · `write`（修改状态） · `exec`（SSH/远程脚本） · `credential`（由 `Vault` 按绑定 origin 精准注入，严禁跨域泄漏） · `crossNetworkExfil`（跨网络外传，一旦涉外部 Web `Taint` 标记必须独立强制确认）。**严禁仅依据 HTTP 方法（如 `GET` vs `POST`）判定操作是否具有副作用**：许多私有设备控制端点与 Webhook 会在 `GET` 上触发开关、重启或写操作，必须结合工具语义、请求体/查询意图与主机授权级别共同决策。
2. **与已有安全边界的关系（不可削弱条款）**：
   - **已授权常规读/用不再反复弹窗**：如用户已将「家庭 NAS Web API (只读)」或已接入「局域网 Hermes MCP」设为 `.allow`，日常工作流免重复打扰；
   - **权限撤销诚实边界**：用户随时可在设置一键撤销授权，撤销后**立即阻止所有后续操作，并经 `PendingApprovalQueue.reconcile`、`HostBindingBook` 与 `URLSession`/SSH 会话取消机制尽可能取消在途任务**；但**不宣称可以撤销远端服务器已经发生的副作用**（已发出的远端写入/指令如实记录于日志与 `Trace`）；
   - **外部提示注入零越权**：哪怕在读取外网网页后或读取私人 NAS 文档后，外部文本中的任意指令**均不可**：① 自动新建私人网络授权；② 扩大已有 `reach/read` 至 `write/exec/credential`；③ 绕过 `Taint.hardExits` 或跨网络将数据外发到未经授权外网服务器（即“私人设备可信，不代表设备上读取到的任意内容或网页摘录能成为可信指令”）；
   - **永久不可放行项**：云厂商元数据地址 `169.254.169.254`（及 `fd00:ec2::254` 等）、未明确的本机未知服务端口 `127.0.0.1`、带账号密码直嵌的 URL 等，无论开启什么兼容模式均强制拒绝。

---

### 2.5 远山 SSH、Tailscale 与跳板机（Bastion / ProxyJump）工作流演进

1. **已核验 `batch-0.36` 现成能力（直接保留不重写）**：
   - `Hills.swift` 与 `Tunnel.swift` 已使用 SwiftNIO + Citadel 原生实现：SSH 公钥 (`ssh-ed25519 clio@iphone` 存 `Vault`) 与密码认证、`HostKeyKeeper` 首次信任 + SHA-256 指纹校验（公钥变更立即中止报错并提示到远山重新信任）、`hostRevisions` UUID 绑定防切主机误执行、`Tunnels` 本地 `127.0.0.1` <-> 远端 `DirectTCPIP` 端口转发隧道（把只监听远程 loopback 的 MCP / Hermes / Playwright 接进手机）、以及 `Shell.maskedClip` 输出密钥脱敏。
   - 只要用户在「远山」配置好主机的局域网 IP、`*.local`、`.ts.net` 或 Tailscale `100.x` 地址，`ssh_run` / `ssh_job_*` 本身即走 Citadel 直连而**不受公网 `Web.swift` 地址限制阻断**。
2. **明确补充演进项（Wave 3–4）**：
   - **多段跳板 (`jumpHostID` / ProxyJump 链)**：在 `Hills.Host` 增可选 `jumpHostID: String?` 与跳板链防环检测；先经 `HillPool` 连入跳板机建立到目标主机的 `DirectTCPIP` SSH 通道，再在其上运行目标机 `SSHClient` 会话；
   - **跳板链与主机指纹绑定加固**：`HostKeyKeeper` 对“经由某跳板机直连”与“直连”使用严格作用域 key，任一跳指纹变化即拒连并清空工作地点绑定缓存；
   - **iOS 系统外部限制诚实标注**：若用户未在 iOS「设置 › 隐私与安全性 › 本地网络」授予权限，或第三方 VPN 未路由私网/CGNAT 网段，手机底层 socket 本身会被系统阻断；诊断页必须如实提示「系统本地网络未授权」或「VPN 路由未包含该私有网段」，不得虚构已连通。

---

### 2.6 UI 收口进既有 8+1 设置与精确诊断分类

不单起平行控制台或堆新设置开关，完全利用现有 3 个入口协同：
1. **设置 › 权限与隐私安全 (`GrantsPage`)**：新增紧凑「私人网络与代理兼容」分组入口（含「Fake-IP 代理兼容开关」及已授权 NAS/私有域名/MCP/网段列表，支持单行查看权限范围 `读/写/凭据` 与一键撤销）；
2. **工具与扩展 / 远山工作地点 (`HillsPage`)**：展示主机、跳板链、`DirectTCPIP` 隧道健康状态及对应私钥指纹；
3. **Fake-IP 与私网 6 维人类可读失败诊断**（杜绝笼统报错）：
   - `① 代理映射占位地址 (Fake-IP 198.18.x)` -> 提示打开 Proxy Fake-IP 兼容模式或检查代理 HTTPS 证书
   - `② 未授权真实私网 / 私有组网目标` -> 提供直达授权说明或仅针对该主机的单次/持久授权卡片
   - `③ 越权操作边界拒绝` -> 仅授权只读或遇外网 Taint 风险，按 `PermissionGate` 请求升级审批
   - `④ 网络不可达 / iOS 本地网络权限未开` -> 检查系统本地网络弹窗或 VPN 路由
   - `⑤ TLS 证书域名不匹配` -> 警告可能的代理/中间人劫持并拒绝校验证书放行
   - `⑥ DNS 解析或混合返回异常` -> 明确展示返回中混杂了公网与 `127/10/192.168` 记录

---

## 第三部分｜Telegram 其他技术 10 项差异化只读审计（Section 24）

核验当前生产仓库 `App/Sources/Reading/ChatListUIKit/*` 与 `App/Sources/Pet/*` 实际实现（不猜不编），将 10 项列为有序结论，避免不必要的大拆大建：

| # | Telegram 技术方向 | Clio `batch-0.36` 实查现状 | 处置结论 |
|---|---|---|---|
| **1** | 富文本稳定 Block ID 与完成复用 | [ChatProseRenderer.swift](../../../App/Sources/Reading/ChatListUIKit/ChatProseRenderer.swift#L275-L278,L1695-L1698) 已建多级 `BoundedLRUCache` (`blockCache 800`, `richTextSliceCache 1200`, `codeSliceCache 400`, `tableSliceCache 256`, `assistantFinalizedCache 1000`) | **核心机制已实现**；只需配合流式阶段稳定 `BlockKey` 增量提交，无需重写引擎 |
| **2** | 长代码增量语法高亮 | `ChatCodeHighlighter.highlight`（`ChatProseRenderer.swift:95`）+ `codeSliceCache` 已覆盖代码块缓存 | **延后按需优化**（仅当单块 >300 行代码卡顿实测出现时做按行切片高亮） |
| **3** | 图片分级加载与后台解码 | [ChatAccessoryControls.swift:360-368](../../../App/Sources/Reading/ChatListUIKit/ChatAccessoryControls.swift#L360-L368) 已用 `CGImageSourceCreateThumbnailAtIndex` + `maxPixelSize` 后台缩略解码 | **无需修改** |
| **4** | 媒体下载取消与缓存预算 | `ChatRichTextView.swift:61` 与 `ChatProseRenderer` 已接 `UIApplication.didReceiveMemoryWarningNotification` 及 `BoundedLRUCache` | **无需额外大改**（仅结合多图长列表核查图片解码内存峰） |
| **5** | 草稿、引用与输入编辑器一致性 | `DictationDraftMerger.swift` + `ChatPage+Dock.swift` 已落地 | **结合 Wave 3 Paper Scrim 与 ChromeCoordinator 对齐交互**，不重构草稿引擎 |
| **6** | 自适应预取与渲染资源调度 | [ChatListViewController.swift:2686,2777](../../../App/Sources/Reading/ChatListUIKit/ChatListViewController.swift#L2686) 已完整实现 `prefetchItemsAt` / `cancelPrefetchingForItemsAt` | **无需重复建设** |
| **7** | 长按菜单、原文定位与手势转场 | [ProseView.swift:3317,3351](../../../App/Sources/Reading/ProseView.swift#L3317) 与 `ChatOtherCells.swift:324` 已配自定义 `UIMenu` 与 `.navigationTransition(.zoom)` | **在 Wave 5 补齐图片与 `InteractivePreview` 转场连贯性即可** |
| **8** | 动态贴纸对 Clio 宠物动画借鉴 | [PetPack.swift:759-783](../../../App/Sources/Pet/PetPack.swift#L759-L783) 已按 `scenePhase == .active`、睡眠 `4fps` / 活跃 `12fps` 节流播放 | **已达低功耗基准，无需引入 RLottie 套件** |
| **9** | 离屏动画暂停与功耗控制 | 宠物与主流程已听从 `scenePhase`；`TextRevealController` + `SharedDisplayLink` 需确保仅对可视且正在流式生成的最近气泡激活 DisplayLink | **在 Wave 2 渐显适配层明确“离屏 Cell 摘除 DisplayLink 监听，回屏无缝续传/直接定稿”** |
| **10** | 60Hz/120Hz 及内存压力降级 | 现成 `FrameMeter` 监测 + `MemoryWarning` 缓存修剪 | **纳入 Wave 2/5 真机量化验收**（若掉帧/低电量模式自动关闭 `SnippetLayer` 仅保纯 `CALayer` 行进） |

---

### 3.2 与并行技术审计任务的性能/能效协作边界与防重复缓冲契约

> **协作分工边界**：另有独立 Agent 正在开展 Telegram 其他功能与底层技术的全量差异化源码审计；**本文件及 `TelegramRevealSpike` 不接管、不重复该审计**，仅在原生架构与实验适配器（[`StreamRevealAdapter.swift`](../experiments/TelegramRevealSpike/Sources/ClioRevealSpike/StreamRevealAdapter.swift)）中为其后续经确认的实施任务预留以下 7 个清晰接口边界：

| 预留扩展点 / 协议名 | 对应未来协同方向 | Wave 2 现成对齐约束（不锁死未来实现） |
|---|---|---|
| `StableBlockCaching` | 长正文稳定块复用 | 已闭合 Markdown 块保持不可变 `blockID`，与 [ChatProseRenderer.swift](../../../App/Sources/Reading/ChatListUIKit/ChatProseRenderer.swift#L1695-L1698) 多级 `BoundedLRUCache` 键体系对齐 |
| `IncrementalCodeHighlighting` | 增量代码高亮 | 超过单块阈值的长代码支持按行切片高亮并沿用稳定 `blockID`，不每 token 重亮全块 |
| `RevealAnimationScheduling` | 动画统一调度 | 单一共享调度器（生产可收敛 `SharedDisplayLink`），**静止、定稿、停止、切后台或离屏后必须立刻卸载 DisplayLink，严格做到 0 无意义 120Hz 空转刷新** |
| `PowerThermalPolicyProvider` | 低电量与发热降载 | 接入 `ProcessInfo.processInfo.isLowPowerModeEnabled` 与 `.thermalState`，高热/低电自动旁路 `SnippetLayer` 并降低重绘频率 |
| `MemoryPressureHandling` | 内存告警治理 | 响应 `UIApplication.didReceiveMemoryWarningNotification`，立即清剪块缓存与临时位图后备缓冲，不丢失已接收文本 |
| `AdaptivePrefetchCoordinating` | 自适应预取 | 对接 `ChatListViewController` 的 `prefetchItemsAt` / `cancelPrefetching`，预布局已定稿历史块但不预生成 `SnippetLayer` |
| `MediaCacheBudgeting` | 媒体资源缓存 | 图片/缩略解码预算与流式文字遮罩池分离配额，避免并发竞争主线程与纹理内存 |

**防重复缓冲强制契约（Eliminate Double Buffering）**：
- 核查 `batch-0.36` 现役实现：
  1. [Chat.swift](../../../App/Sources/Chat.swift#L164-L321) 中 `ChatModel.type()` / `step()` 采用固定 `16ms` 协程步进（`(goal - shown) / 10`）配合 `Self.redraws = 15.0` (15Hz) 向 `ChatLiveStreamState.text` 释放字符；
  2. [ChatProseRenderer.swift](../../../App/Sources/Reading/ChatListUIKit/ChatProseRenderer.swift#L414,L974-L992) 的 `applyStreamingTailFade` 会在最后 12 个字符静态重写 `.foregroundColor` Alpha 渐变，与旧批量刷新叠加形成抖动。
- **正式接入硬规则**：在 Wave 2 上线 `TextRevealController` 时，SSE 原始增量到达 `ChatModel` 后**必须直通 `StreamRevealAdapter`（绕过旧 `(goal - shown) / 10` `step()` 二次调速），并关闭 `applyStreamingTailFade` 属性重算**；全程由 `Telegram TextRevealController` 作为**唯一调速权威（Single Pacing Authority）**，严禁“旧 15Hz 字符释放器 + 新 EWMA DisplayLink”双重缓冲叠加导致延迟翻倍与不必要的全量排版重建。

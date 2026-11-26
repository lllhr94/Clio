# Clio

住在 iPhone 里的个人助手。你带上自己的模型密钥，几位「旅伴」直接在手机上和模型对话、替你动手：搜索、读网页、在手机里的小 Linux 跑命令、连远程主机、读写日历和提醒、接 Gmail 等连接器。对话和记忆都存在这台手机上，不经过别人的服务器。

名字来自希腊神话里掌管历史的缪斯 Clio，她手里总拿着一卷书。Clio 的风格是纸墨、书卷：安静、克制、耐看。

## 有什么

- **对话**：多位旅伴、群聊（雅集）、思考过程、步骤折叠、计划清单、搜索来源、引用追问、压缩前文
- **动手**：联网搜索与读网页、内置浏览器、手机里的 Linux（斗室，基于 iSH）、SSH 远程主机、MCP 连接器（谷歌官方、GitHub、Notion、高德等）、日历、提醒、相册、健康、位置
- **安全**：每项能力可设「不许 / 每次问 / 放行」；敏感操作先递批准单；密码存在信匣，模型看不到；面容锁
- **陪伴**：记忆（拾遗）、晨信、日记、宠物（站在输入框上、会动会冒气泡，可导入宠物包）
- **外观**：日常 / 书卷两套称谓、对话字号四档、界面大小四档、六种主色、深色与纯黑

## 仓库结构

| 目录 | 内容 |
|---|---|
| `AgentKit/` | 引擎：模型接口、agent 循环、工具、Markdown 解析。纯 Swift，带测试 |
| `App/` | SwiftUI App。Xcode 工程由 `App/project.yml` 经 XcodeGen 生成 |
| `App/Sources/Design/` | 设计系统：`Ink`（颜色、字号、间距、圆角）、`Kit`（列表行、卡片、标题等公用组件）、`Words`（称谓） |
| `App/Sources/Tone/` | 两本词典：`zh-CN.daily.json`（日常）和 `zh-CN.literary.json`（书卷），键完全相同 |
| `App/Sources/Pet/` | 宠物：状态、动作、气泡、宠物包导入 |
| `App/Den/` | 斗室（iSH）相关 |
| `tools/` | 辅助脚本，例如把动图做成宠物包 |
| `docs/` | 现状与交接（`STATUS.md`）、设计需求（`DESIGN-BRIEF.md`） |

## 构建与安装

本地没有构建环境，一切靠 GitHub Actions（`.github/workflows/build.yml`），手动触发：

```bash
gh api -X POST repos/lllhr94/Clio/actions/workflows/build.yml/dispatches \
  -f ref=<分支> -f 'inputs[runner]=macos-15-intel' \
  -F 'inputs[publish]=true' -F 'inputs[shots]=false'
```

- `publish=true`：在 `main` 上替换 `latest` 发布；在其他分支上发到 `probe-<分支>` 测试发布。
- `shots=true`：另外在模拟器里拍亮色、暗色各 8 张主要界面截图，推到 `shots/<运行编号>` 分支。

产物是未签名的 IPA，在手机上自签安装。

## 参与协作

不论人还是 AI（Claude、Codex、Gemini），动手前先读 [`AGENTS.md`](AGENTS.md)（规则和约定），再读 [`docs/STATUS.md`](docs/STATUS.md)（做到哪了、接下来做什么）。设计类工作看 [`docs/DESIGN-BRIEF.md`](docs/DESIGN-BRIEF.md)。

## 许可

GPL-3.0，见 `LICENSE`。

## 致谢

- 心绪（`App/Sources/Pulse.swift`）的 PULSE 思路和提示词改编自 [HanaAgent / openhanako](https://github.com/liliMozi/openhanako)（Apache-2.0）。
- 名帖卡片（`App/Sources/Reading/NameCardView.swift`）的版式参考了 HanaAgent 的人物角色卡：上图、名字、三格属性、背面（Apache-2.0），画法是 Clio 自己的。
- 斗室使用 [iSH](https://github.com/ish-app/ish)（GPL-3.0），终端画面使用 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（MIT），SSH 使用 [Citadel](https://github.com/orlandos-nl/Citadel)（MIT），宠物包解压使用 [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)（MIT）；网络和 SSH 底层用 [SwiftNIO](https://github.com/apple/swift-nio)（Apache-2.0）和 SwiftNIOSSH（Apache-2.0，目前用的是 [Wellz26 的分支](https://github.com/Wellz26/swift-nio-ssh)，原版在 [apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh)）；公式排版用 [SwiftMath](https://github.com/mgriebling/SwiftMath)（MIT）。
- 流式文字渐显控制器与 Points 宽度揭示算法移植/改编自 [Telegram for iOS](https://github.com/TelegramMessenger/Telegram-iOS)（`GPL-2.0-or-later`，提交 `24638bc`），隔离存放于 `App/Sources/Reading/ThirdParty/TelegramReveal/` 并附源码映射说明。
- 字体：题词和标题用的 Clio Kai 裁自 [霞鹜文楷 GB](https://github.com/lxgw/LxgwWenkaiGB)（LXGW WenKai GB，SIL OFL 1.1）；朱印「克」裁自 [马善政毛笔楷书](https://github.com/google/fonts/tree/main/ofl/mashanzheng)（Ma Shan Zheng，SIL OFL 1.1）。代码字体是 [Maple Mono](https://github.com/subframe7536/maple-font)（SIL OFL 1.1），代码里的中文用 Clio Mono CN，裁自 Maple Mono CN 的中文底（汉字来自 [Resource Han Rounded](https://github.com/CyanoHao/Resource-Han-Rounded)，SIL OFL 1.1）；天气数据来自 [Open-Meteo](https://open-meteo.com)（CC BY 4.0）；模型能力资料来自 [models.dev](https://models.dev)（MIT）。授权全文和裁剪说明见 `App/Fonts/`。
- 宠物包格式与 DSH Go、Clawd on Desk 的 schema 1 兼容；Clio 的实现是独立写的，没有使用它们的代码或素材。

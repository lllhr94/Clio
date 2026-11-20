# AGENTS.md

写给所有动手改 Clio 的人和 AI（Claude、Codex、Gemini……）。`CLAUDE.md` 是指向本文件的链接，两者是同一份。
先读完本文件，再读 `docs/STATUS.md`。

## 这是什么

Clio：iOS 原生（SwiftUI，iOS 26）个人 agent App，引擎是同仓库的 `AgentKit`。用户自带模型密钥，所有数据存在手机上。
主人是个人开发者，中文母语，用真机测试。

## 和主人打交道

- **用中文回复**，说人话，少术语。
- **攒一批改动再编译**，不要每改一处就跑一次 CI。
- **只有主人说「发」才发布到 `main` / `latest`**。平时在 `batch-<版本>` 分支上做，用 probe 发布给主人试。
- 主人发来的参考截图（其他 App）要**批判地看**：说哪里值得学、哪里不适合 Clio，不要照抄。
- 每个控件都要能用、都要能看懂它是干什么的；没做完的功能不要摆出来。
- **默认不截图**（`shots=false`），截图太慢。主人要求时才开 `shots=true`；平时主人在真机上看。

## 硬规则

- **不提交任何密钥、令牌**。用户的密钥在钥匙串（`Vault`），信匣里的秘密永远不给模型看；备份不含信匣。
- **许可**：Clio 是 GPL-3.0。
  - DSH Go 是 AGPL、Open Minis 是 GPL：**只学思路，不抄代码和素材**。
  - HanaAgent 是 Apache-2.0：可以改编，但要在 README 致谢里写明。
  - iSH 是唯一允许直接用代码的例外，已注明出处。
- **不往仓库里放公司 logo**。服务商图标在运行时从网上取，只缓存在手机上（`BrandIcon`）。
- **用户的图片只留在手机上**，不进仓库。
- **不要 force push**。不要改写已推送的历史。
- 新加第三方依赖前确认许可兼容 GPL-3.0（MIT、BSD、Apache-2.0 可以），并写进 README 致谢。

## 构建、验证

没有本地 Mac。只能用 GitHub Actions：

```bash
# 编译 + 发测试包到 probe-<分支>
gh api -X POST repos/lllhr94/Clio/actions/workflows/build.yml/dispatches \
  -f ref=batch-0.33 -f 'inputs[runner]=macos-15-intel' -F 'inputs[publish]=true' -F 'inputs[shots]=false'

# 看结果、找编译错误
gh api "repos/lllhr94/Clio/actions/runs?branch=batch-0.33&per_page=1" --jq '.workflow_runs[0]|.id,.status,.conclusion'
gh api repos/lllhr94/Clio/actions/runs/<run>/jobs --jq '.jobs[0].id'
gh api repos/lllhr94/Clio/actions/jobs/<job>/logs | grep "error:"
```

- 截图：加 `-F 'inputs[shots]=true'`。截图被推到 `shots/<run>` 分支：`git fetch origin shots/<run>` 后 `git archive FETCH_HEAD | tar -x -C <目录>`。截图模式用启动参数 `-clioShot <界面名>`，进演示数据并打开对应界面（见 `App/Sources/Shots.swift` 和 `Desk.swift` 里的 `Shots.name`）。
- 只读 Release 用 REST（`gh api repos/.../releases/tags/<tag>`），GraphQL 用不了。
- 版本号在 `App/project.yml`：`CFBundleShortVersionString` / `CFBundleVersion`。

## Swift 5 模式的坑（编译器版本见 CI 的 Xcode 26.3）

- 三元表达式里放闭包会类型推断失败，改成 if/else。
- 太长的 SwiftUI 表达式会「unable to type-check in reasonable time」，拆成小的计算属性。
- 闭包里 `let x = x(...)` 这种同名遮蔽会报错。
- 同一语句里对同一个可选值的重叠访问会报错，先取到局部变量。
- 从非隔离代码调用 MainActor 的静态成员要 `nonisolated` 或换写法。
- 元组类型字面量要带标签才能用 `.min` 之类的成员。

## 设计系统（必须遵守）

全部在 `App/Sources/Design/`：

- **字号只有五档**：`Ink.Size.micro 11 / small 13 / sub 15 / body 17 / title 20`。不要写 `.system(size: 16)` 这种数字。正文阅读字号另走 `Pref.size`（用户可调）。
- **间距**：`Ink.Space.xs 4 / s 8 / m 12 / l 16 / xl 24 / xxl 32 / page 20`。
- **圆角只有三种**：卡片 `Ink.Radius.card`（28）、卡片里的小块 `Ink.Radius.small`（14）、控件一律胶囊 `Capsule()`。所有圆角都用 `style: .continuous`。图标是圆角方块，比例统一用 `Kit.iconCorner(size)`。旅伴头像用圆形。
- **界面大小**：以上数值都乘 `UIScale.factor`（用户在「外观」里选紧凑 / 偏小 / 标准 / 偏大），所以它们是计算属性，不要缓存成常量。
- **公用组件**（`Kit.swift`）：列表行 `RowLabel`、图标 `IconBadge`、行间分隔 `Kit.divider`、分组标题 `SectionTitle`、主按钮 `WideButtonStyle`、装行的卡片 `paperCard()`、正文里的代码块和表格 `inkBlock()`（小圆角）。新页面用它们，不要再手搓一套。
- **弹出页按钮**：只看的页面右上角「好了」（`L.t("actions.done")`），其他操作（＋、菜单）也放右上；要填写的页面左上「取消」、右上「保存」。搜索框一律在标题下面常驻（`.navigationBarDrawer(displayMode: .always)`）。
- **颜色**只用 `Ink`：`ink / inkSoft / inkFaint / paper / paperRaised / rule / accent / accentWash / ok / warn / stop`。
- 浮在内容上的顶栏、输入框要垫纸色渐隐（见 `ChatPage` 的 header 和 composer），不要用系统的 hard scroll edge（会出现带横线的实心条）。

## 文字：称谓（日常 / 书卷）

- 界面上的名字和提示**从词典取**：`L.t("nav.settings")`。词典在 `App/Sources/Tone/`，两份 JSON 的键必须完全一致。
- 新加文字：两份词典都加同一个键。书卷说法要好懂，不要生造词；**按钮保持日常说法**（保存、取消、删除……）；删除类确认的后果提示固定写直白的（`errors.cannotUndo`）。
- **书卷词表里的词都是功能名**（书案＝文件，斗室＝终端，港湾＝连接器，更漏＝定时任务，良方＝技能，便笺＝批准单，手札＝日记……），只在说那个功能时用，不要拿来当装饰造句，比如断网别写「港湾失联」、超时别写「更漏已过」。
- `L.hint(key)`：书卷模式下开着「日常旁注」时，给出日常说法当灰色小字。
- 老代码里的 `Words.t("…")` 是用旧书卷名写的句子，会自动换成当前称谓下的名字；新代码优先用 `L.t`。
- 词表定稿（书卷）：窗前 书案 斗室 别馆 漫游 雅集 拾遗 旅伴 伴读 手札 集珍 日课 偶得 调弦；絮语 另起一叶 絮语录 沉吟 落笔 闲坐 思绪 文脉 收卷 夹页 出处 回笺；待签 落款 退回 便笺；诸艺 良方 港湾 更漏 寻访 行迹 晨信 来信 音信 样张；名帖 镇纸 入藏 未阅 常记 旧事；应许 密匣 封缄 笔庄 墨量 校音 设色 疏密 称谓。

## 宠物

- 代码在 `App/Sources/Pet/`。`PetStage` 站在输入框上沿；`PetMood` 由 `ChatPage.petMood` 算；别的对话的事件经 `PetNews.shared.post` 冒气泡（`TeamModel` 在做完、出错、递批准单时调用）。
- 内置宠物就是「形象」里选的那位（`PetFigure`）。形象有：卷卷（书卷精，默认）、墨团、天鹅、鲸鱼，或用户自己的画像。画法在 `Design/Figures.swift`，统一入口是 `Whale` 视图（名字是历史遗留），`Persona.kind` 决定画哪个。新形象：加一个 `Persona.Kind`，在 `Figures.swift` 画六种姿态（idle / thinking / writing / waiting / cheering / sleeping），给出 `FigureSpots`（眼、头顶、脖子的位置），只用两种颜色（ink 和 hole）画成剪影。截图里 `-clioShot figures` 会列出全部形象和姿态。
- 自定义宠物包：schema 1 格式（`pack.json` + PNG 序列帧），与 DSH Go / Clawd on Desk 兼容。解析在 `PetPack.parse`，导入在 `PetLibrary.install`。`tools/make_pet_pack.py` 能把动图或序列帧做成宠物包。

## 交接

- **分工和分支规则见 `docs/TASKS.md`**：`batch-*` 只由 Claude 合并推送；Codex 在 `codex/<任务名>` 分支上做，开 PR 合进去。

- 做完一段工作，更新 `docs/STATUS.md`：做了什么、没做完什么、下一步、已知问题。
- 提交信息用英文写清楚改了什么；一次提交只做一件事。
- 不确定的产品决定（命名、取舍）问主人，别自己拍板。

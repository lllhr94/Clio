# Claude 不在的这段时间怎么干（2026-11-23 起，约一个月）

> **0.34 已于 11-22 发布**（`main` = `ae7a7d6`，v0.34）。之后的活都在 `batch-0.35` 上做，PR 合到 `batch-0.35`。

主人的 Claude 订阅暂停，Claude 下个月才回来。这段时间 **Codex 临时当总管**（合并、打包、写状态），Antigravity 照常领任务。规矩没变的地方照 `AGENTS.md`。

## 谁做什么

| 事 | 谁 |
|---|---|
| 领任务、写代码、开 PR | Codex（`codex/<任务名>`）、Antigravity（`antigravity/<任务名>`） |
| 审 PR | **对方审**：Codex 的 PR 由 Antigravity 审，Antigravity 的 PR 由 Codex 审。审的人在 PR 下面写清楚看了什么、有没有问题 |
| 合进 `batch-0.35` | **Codex**，前提：作者贴了 CI 编译通过的链接，并且另一方审过、没提未解决的问题 |
| 合并后打测试包 | Codex 在 `batch-0.35` 上跑一次 CI（`publish=true`、`shots=false`），把结果告诉主人 |
| 更新 `docs/STATUS.md`、`docs/FEEDBACK.md`、`docs/TASKS.md` | 合并的人顺手更新 |
| 发正式版（`main` / `v0.35`） | **只有主人说「发」才发**。发之前 Codex 写好 `docs/releases/0.35.md`（中文、主人看得懂）。把 `batch-0.35` 快进合进 `main`（不要 force），在 `main` 上跑 CI（publish=true）。 |

## 现在排着的活（顺序）

1. **C32（Codex）流畅度、并发、后台**和 **A2（Antigravity）网络安全 + 引擎细节 + 单测**：可以同时做，两边不碰同一个文件（清单见 `docs/REVIEW-ANTIGRAVITY.md`「派出去的活」）。A1 已由 Claude 做完。
2. **C33（Codex）聊天页和侧边栏收尾**、**A3（Antigravity）文案扫尾 + 模型服务方案**：清单见 `docs/TASKS.md`「0.35」。C33 等 C32 交完再开。
3. 主人在真机上新发现的问题：主人截图或描述发给其中一个，记进 `docs/FEEDBACK.md`，再按文件分给不撞车的一方。

## 不要碰、要等 Claude 的

- 引擎主循环：`AgentKit/Sources/AgentKit/Agent.swift` 的 `run` / `perform`；工具关卡：`AgentKit/Sources/Craft/Taint.swift`、`Team.swift` 里的 `ask` / `answer` / 污点；`App/Sources/Care/Backup.swift`；`App/Sources/Vault/`（信匣）。这些是安全边界，真要改，先写进 `docs/FEEDBACK.md` 等 Claude 回来。
- 宠物位置（`Pet/PetStage.swift`、`Pet/PetPerch.swift`）：主人刚定了「只能左右拖、站在输入框上沿」，不要改回去。
- 产品取舍（命名、删功能、加大功能）：问主人，别自己定。

## 撞车了怎么办

- 两个 PR 改到同一个文件：后合的那个先把最新的 `batch-0.35` 合进自己分支、解决冲突、重新跑 CI，再合。
- **不要 force push**，不要改写已经推上去的历史。
- CI 编不过不合。编过了但主人真机说坏了：开一个新 PR 修，或者用 `git revert` 撤掉那次合并（不要删提交）。

## Claude 回来时

- 先读本文件、`docs/STATUS.md` 和这一个月合进来的 PR，复查合进来的安全相关改动，再接着当总管。

## 11-22 夜：主人定，接下来主要交给 Codex

**Codex 排队（按顺序）**
1. **C40**：计划清单展开顺滑（整张卡片从下往上一起长高）；顶栏下的模型名别压在正文上。
2. **C39**：照主人 11-22 18:52 的掉帧记录修卡顿（终端命令结束那 612 ms、终端输出流进来时的刷新、`doing` 之类高频状态、打开「养护」「调弦」的首帧）。
3. **审谷歌的 A9 / A10 / A11**（搜索服务、共享和存笔记、云端语音识别）。Claude 已看过，合之前要满足：A9 **默认搜索用「内置网页」**，第三方搜索由主人自己选（除非主人另有决定）；A11 云端识别**只有局域网地址才许 http**，别的一律 https；密钥都在钥匙串、不进备份。
4. 之后的新问题：主人截图 → 记进 `docs/FEEDBACK.md` → 按文件分给自己或谷歌。

**Codex 当总管要做的**
- 合并：谷歌的 PR 由 Codex 审，Codex 自己的 PR 由谷歌审；CI 编过、对方审过才合进 `batch-0.35`。
- 每合一批，在 `batch-0.35` 上跑一次 CI（`publish=true`、`shots=false`），把测试包告诉主人。
- 主人说「发」：写 `docs/releases/0.35.md`（中文、主人看得懂），把 `batch-0.35` 快进合进 `main`（不要 force），在 `main` 上跑 CI 发版。
- 每做完一段，更新 `docs/STATUS.md`、`docs/FEEDBACK.md`、`docs/TASKS.md`。

**仍然等 Claude 回来的**（安全边界，别动；真要改先写进 FEEDBACK）
- `Team.swift` 里的批准（`ask` / `answer`）、污点（`TaintGuard`、`Taint.swift`）、帮忙时带过去的标记；`AgentKit` 的 `Agent.run` 主循环。
- `Care/Backup.swift`（备份带上技能这件留给 Claude）、`Vault/`（信匣）。
- 宠物「只在输入框上沿左右动」的规矩。

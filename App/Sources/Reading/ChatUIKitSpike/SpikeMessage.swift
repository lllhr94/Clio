#if DEBUG
import Foundation

enum SpikeRole: Sendable, Equatable {
    case user
    case assistant
}

struct SpikeMessage: Identifiable, Sendable, Equatable {
    let id: UUID
    let role: SpikeRole
    let speaker: String
    var text: String
    let quote: String?
    var isStreaming: Bool
    let timestampText: String

    init(
        id: UUID = UUID(),
        role: SpikeRole,
        speaker: String,
        text: String,
        quote: String? = nil,
        isStreaming: Bool = false,
        timestampText: String = ""
    ) {
        self.id = id
        self.role = role
        self.speaker = speaker
        self.text = text
        self.quote = quote
        self.isStreaming = isStreaming
        self.timestampText = timestampText
    }
}

enum SpikeFixtureData {
    static let assistantName = "Clio UIKit 原型"

    static func makeInitialMessages() -> [SpikeMessage] {
        var out: [SpikeMessage] = []
        let templates = richTurns
        for turnIndex in 0..<12 {
            let pair = templates[turnIndex % templates.count]
            let turnLabel = String(format: "%02d:%02d", 9 + (turnIndex / 4), (turnIndex * 11) % 60)
            out.append(
                SpikeMessage(
                    role: .user,
                    speaker: "你",
                    text: pair.user,
                    quote: turnIndex == 10 ? "使用 single continuous UITextView + TextKit 2 渲染段落、列表、引用与代码块，可以彻底消除跨块选字中断。" : nil,
                    timestampText: turnLabel
                )
            )
            out.append(
                SpikeMessage(
                    role: .assistant,
                    speaker: assistantName,
                    text: pair.assistant,
                    timestampText: turnLabel
                )
            )
        }
        return out
    }

    static func makeEarlierBatch(batchIndex: Int, count: Int = 20) -> [SpikeMessage] {
        var out: [SpikeMessage] = []
        out.reserveCapacity(count)
        let templates = richTurns
        let pairCount = count / 2
        for i in 0..<pairCount {
            let globalIndex = (batchIndex - 1) * pairCount + i + 1
            let pair = templates[(i + batchIndex * 3) % templates.count]
            let minute = (i * 5) % 60
            let hour = max(0, 8 - batchIndex + (i / 12))
            let stamp = String(format: "历史 #%03d · %02d:%02d", globalIndex, hour % 24, minute)
            out.append(
                SpikeMessage(
                    role: .user,
                    speaker: "你",
                    text: "[前文第 \(batchIndex) 批 · #\(globalIndex)] \(pair.user)",
                    timestampText: stamp
                )
            )
            out.append(
                SpikeMessage(
                    role: .assistant,
                    speaker: assistantName,
                    text: "**[前文归档 #\(globalIndex)]** \(pair.assistant)",
                    timestampText: stamp
                )
            )
        }
        return out
    }

    static let streamingScript: String = """
### 一、为什么流式输出容易在定稿瞬间闪跳？

在传统的 SwiftUI 混合渲染路径里，**Streaming** 阶段和 **Finalized** 阶段往往对应两套不同的 View 树：流式时走增量 tail view，结束瞬间整段替换成 `SelectableProse` 或触发 `reloadItems`。只要行高、字体 fallback、代码块内边距有 `0.5 pt` 差异，就会出现肉眼可见的跳动与重绘闪烁。

> 核心原则：流式期间与定稿之后，必须复用**同一个 `SpikeRichTextView`**、同一套 `NSParagraphStyle` 度量参数，以及同一高度的底部状态栏。

### 二、UIKit 方案里的零闪跳管线

1. **Display-cadence 批处理**：由 `CADisplayLink` 按屏幕刷新节奏节流提交文本块，避免每个 token 都触发全量集合视图刷新。
2. **前缀块缓存（Sealed Prefix Cache）**：已经闭合的段落、列表、代码块直接复用缓存的 `NSAttributedString`，每一帧只增量解析正在生长的尾部 block。
3. **In-place 布局更新**：直接调用可见 `cell.updateContent(...)` 与 `collectionViewLayout.invalidateLayout()`，绝不走 `reloadItems` 淡入替换动画。

```swift
func commitStreamFrame(text: String, finalized: Bool) {
    let rendered = builder.build(text, style: style, streaming: !finalized)
    cell.apply(rendered) // In-place UITextView update, no reloadItems
    if abs(rendered.height - cachedHeight) > 0.25 {
        UIView.performWithoutAnimation {
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
        }
    }
}
```

---

### 三、真机验证要点

- **保持阅读偏移**：如果你在流式输出中途向上划动回看前文，`isPinnedToBottom` 会立刻置为 `false`，后续新字增长只会向下延伸，当前视口保持 `0.0 pt` 稳停。
- **跨段选字引用**：现在你可以长按任意汉字或代码标识符，把选区手柄直接从正文一路拖过列表、引用块与 `Swift` 代码块，再点菜单里的「引用」。
"""

    static func makeReplyScript(for prompt: String, quote: String?) -> String {
        let focus = quote.map { excerpt in
            let snippet = String(excerpt.replacingOccurrences(of: "\n", with: " ").prefix(48))
            return "针对你刚才引用的「`\(snippet)`」，"
        } ?? "收到你的问题「\(String(prompt.prefix(36)))」，"

        return """
### 跟进分析

\(focus)我们把当前 UIKit 原型的行为拆成三层来核对：

1. **Selection Range Continuity**：整条回复全部在单个 `UITextView` 内由 `NSTextLayoutManager` 统一排版，行内代码与围栏代码块都使用底层 `CALayer` / `CAShapeLayer` 绘制，不打断 `UITextInteraction` 的手柄拖拽。
2. **Anchor Lock Stability**：在 `Prepend-20` 插入前先锁定首个可见 cell 的 `frame.minY - contentOffset.y`，随后关闭隐式动画并用预测量高度同步更新布局。
3. **Zero-Flicker Finalization**：

```swift
// 结束时不切换视图类型，只去掉尾部渐隐透明度
let delta = finalFrame.height - streamFrame.height
assert(abs(delta) < 0.1, "定稿零跳动验证")
```

> 可以继续向上滚动触发自动预加载，或者再次跨段落拖拽选词测试「引用」菜单。
"""
    }

    private struct TurnPair {
        let user: String
        let assistant: String
    }

    private static let richTurns: [TurnPair] = [
        TurnPair(
            user: "长对话在真机上滑到顶部加载前 20 条时，怎么保证屏幕上原来那句话一像素都不跳？",
            assistant: """
### 一、前文插入时的 Y 轴锚点锁定（Anchor Lock）

在 `UICollectionView` 上方批量插入 20 条历史消息时，之所以常见「瞬间向下跳一大截」或「继续上滑时突然抽搐」，主要有两个根因：

- **估算高度失真**：新插入的 20 个离屏 cell 如果先用 `.estimated(120)` 占位，在用户上滑接近它们并触发 self-sizing 时，真实高度（比如 `480 pt`）会突然撑开 `contentSize`，把下面的消息整体往下推。
- **异步批更新打断惯性**：如果使用带动画的 `apply(snapshot, animatingDifferences: true)` 或 `setContentOffset(_:animated: false)`，既会产生位移插值，又会粗暴掐断 `UIScrollView` 的减速惯性。

> 正确做法：**预测量精确高度 + 无动画原子提交 + 直接回写 `contentOffset.y`**。

```swift
let beforeVisualY = anchorAttrs.frame.minY - collectionView.contentOffset.y
UIView.performWithoutAnimation {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    dataSource.apply(snapshot, animatingDifferences: false)
    collectionView.layoutIfNeeded()
    if let afterAttrs = collectionView.layoutAttributesForItem(at: newPath) {
        collectionView.contentOffset = CGPoint(
            x: collectionView.contentOffset.x,
            y: afterAttrs.frame.minY - beforeVisualY
        )
    }
    CATransaction.commit()
}
```

实测这套管线在 120Hz ProMotion 真机上可以将 `anchor Δ` 严格压在 **`0.0 pt`**，即使高速甩动触发自动预加载也丝滑无感。
"""
        ),
        TurnPair(
            user: "为什么在 SwiftUI 里没法把选区手柄从正文段落一路拖到代码块里面？改用 UIKit 要注意什么？",
            assistant: """
### 跨块连续选字与自定义「引用」菜单

SwiftUI 的 `Text` + `VStack` 会把段落、引用卡片与 `CodeBlock` 拆成各自独立的原生视图容器，iOS 的 `UITextSelectionInteraction` 无法跨越两个互不隶属的 `UITextView` 边界。

1. **Single Continuous `UITextView`**：将 Heading、Paragraph、List、Blockquote 与 Fenced Code Block 全部编进同一份 `NSAttributedString`，统一交给单个 `isEditable = false`、`isSelectable = true`、`isScrollEnabled = false` 的 `UITextView`。
2. **Underlying Card Layers**：代码块圆角底卡、引用块左侧竖线与行内代码胶囊都画在 `layer.insertSublayer(..., at: 0)` 的底层 `CALayer` 中，完全不遮挡文字与蓝色选区手柄。
3. **iOS 16+ / 26 `editMenuForTextIn`**：通过 `UITextViewDelegate` 把自定义 `UIAction(title: "引用")` 插到系统菜单首位，同时把列表前缀的 `\\t` 制表符整理成干净空格再送入底部引用条。

- [x] 支持正文 -> 列表 -> 引用块 -> 代码块连续拖选
- [x] 点击「引用」自动填充底部追问栏并弹出确认提示
- [ ] 支持更复杂的数学公式与横向滚动宽表格
"""
        ),
        TurnPair(
            user: "能不能给一段 Python 和 SQL 混排的诊断示例，方便我们顺便测试等宽列对齐和跨代码块拖选？",
            assistant: """
### 中英等宽列对齐与多语言混排示例

Clio 内置的 `Maple Mono` 搭配 `Clio Mono CN` 会让每个汉字严格占据两个 ASCII 字符宽度，因此在代码块里做中英文混排表格或对齐注释时，列边界始终笔直。

```python
def inspect_frame_budget(samples_ms: list[float], target_hz: int = 120) -> dict:
    budget = 1000.0 / target_hz  # 每帧预算（约 8.33 ms @ 120Hz）
    hitches = [ms for ms in samples_ms if ms > budget * 1.5]
    return {
        "total": len(samples_ms),
        "hitch_count": len(hitches),  # 超出 1.5 倍帧间隔的次数
        "worst_ms": round(max(samples_ms, default=0.0), 2),
    }
```

同时，下面是一段检查本地会话索引的 SQLite 查询语句，你可以试着从上面的 Python 注释一路向下拖选到这里的 SQL 语句里：

```sql
SELECT thread_id, count(*) AS msg_count, max(updated_at) AS latest
FROM chat_messages
WHERE archived = 0
GROUP BY thread_id
ORDER BY latest DESC
LIMIT 20;
```

---

选区横跨多个代码块时，系统编辑菜单依然会稳定给出「引用」与「拷贝」，不会丢失任一段落。
"""
        ),
        TurnPair(
            user: "如果回复流式输出到一半，用户往上滑看前文，界面怎么做到不抢滚动也不闪跳？",
            assistant: """
### 流式阅读位置保护（Reading Position Pinning）

当模型还在高速输出 token 时，如果用户主动向上轻滑离开底部，界面必须立刻把控制权还给用户。

> 判定规则：只有当用户距离底部的余量 `<= 36 pt` 时才维持 `isPinnedToBottom = true`；一旦上滑超过阈值，即使尾部继续新增数十行文字和代码块，也只更新 `contentSize` 而**保持 `contentOffset.y` 原封不动**。

1. **帧节流批处理**：后台 chunk 到来后不直接刷表，而是合并到下一次显示刷新（约 `60fps` 节奏）一次性更新 `UITextView.attributedText`。
2. **禁止 `reloadItems`**：只对当前可见的那一个 `SpikeAssistantCell` 执行原地赋值和 `invalidateLayout()`，避免 cell 复用闪烁或焦点丢失。
3. **定稿零切换**：完成流式时只把 `isStreaming` 置为 `false` 并移除末尾渐隐 alpha，字体、段落间距和底部状态条高度保持完全一致。
"""
        ),
        TurnPair(
            user: "在 TextKit 2 里画代码块圆角底卡时，为什么有时候刚复用出来的 cell 背景会慢半拍？",
            assistant: """
### TextKit 2 布局就绪与 `CATransaction` 细节

在 iOS 16+ 的 TextKit 2（`UITextView(usingTextLayoutManager: true)`）下，有两处细节非常容易导致视觉残影或首帧空白：

1. **惰性排版（Viewport-driven Layout）**：`NSTextLayoutManager` 默认可能尚未完成全段几何计算，直接查询 `selectionRects(for:)` 偶尔会拿到空数组。在 `layoutSubviews()` 里先调用 `textLayoutManager?.ensureLayout(for: documentRange)`，即可确保行矩形百分百就绪。
2. **CoreAnimation 隐式动画**：无论是 `CAShapeLayer.path` 还是 `CALayer.frame`，默认修改都会附带 `0.25s` 的缓动插值。在流式逐帧撑高代码块时，若忘了包一层 `CATransaction.setDisableActions(true)`，圆角背景框就会像橡皮筋一样拖在文字后面跑。

```swift
CATransaction.begin()
CATransaction.setDisableActions(true)
cardLayer.frame = computedCardFrame
cardLayer.backgroundColor = raisedPaperCGColor
CATransaction.commit()
```

关闭隐式动画后，文字与卡片边缘会在同一物理帧严格对齐。
"""
        ),
        TurnPair(
            user: "把这三项验证标准写成一份简洁的真机自检清单吧。",
            assistant: """
### Contract 2 真机验收清单

你可以在当前原型页直接逐项完成下面的三项真机验证：

1. **跨段落 / 跨块选字引用**
   - 长按任意正文词语，向右下方拖拽蓝点，横跨标题、列表项、引用卡片与代码块。
   - 点击弹出菜单最前面的「引用」，确认底部输入框上方出现引用条，且顶部或底部弹出已引用提示胶囊。
2. **前文加载锚点稳停**
   - 点击顶部「+20 前文」按钮，或手动向上滑动至接近列表顶部触发自动加载。
   - 观察屏幕上方原本阅读的那一行文字是否纹丝不动，并核对 HUD 中的 `anchor Δ: 0.0 pt`。
3. **流式到定稿零闪跳**
   - 点击顶部「模拟流式」或直接发送一条追问，观察长文与代码块流式增长的帧率与顺滑度。
   - 中途尝试向上略微滑动，确认页面不会强行把你拽回底部；等待输出结束，确认文字与卡片定稿瞬间无闪白、无跳行。
"""
        )
    ]
}
#endif

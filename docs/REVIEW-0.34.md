# 0.34 互查问题

审查基线为 `9553159`。范围为 `39a26d8` 起的 Claude 改动，含 `cbe41a9` 名帖卡。以下按严重程度排列。

## 1. [P1] 撤回重复记忆会删除原来的手写条目

- **定位** [`App/Sources/Team.swift:574`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Team.swift#L574) · [`App/Sources/Tools.swift:220`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Tools.swift#L220) · [`App/Sources/Reading/ChatPage.swift:2338`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/ChatPage.swift#L2338) · [`App/Sources/Team.swift:647`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Team.swift#L647)
- **触发** 先在常记手写一条。旅伴下一轮通过 `remember` 记下完全相同的一句，再点该轮步骤下方「撤回」。本地使用原方法复现了这条路径。
- **后果** 重复记忆只刷新旧条目的状态，工具仍回报成功。撤回按文本找到旧条目并删除，手写记忆及关联整理详情一起消失。即使找不到条目，界面也会显示已撤回。
- **建议** 让工具返回本轮实际改动的记忆 ID 和类型。新增只撤销本轮创建的 ID，刷新使用时间应恢复旧状态。附带版本检查避免撤回期间覆盖用户修改，界面依据撤回结果显示状态。

## 2. [P1] 聊天搜索和问答目录会在长对话里反复重建历史并放大渲染量

- **定位** [`App/Sources/Reading/ChatPage.swift:1303`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/ChatPage.swift#L1303) · [`App/Sources/Chat.swift:190`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Chat.swift#L190) · [`App/Sources/Chat.swift:277`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Chat.swift#L277) · [`App/Sources/Reading/ChatPage.swift:222`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/ChatPage.swift#L222) · [`App/Sources/Reading/ChatPage.swift:1397`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/ChatPage.swift#L1397) · [`App/Sources/Reading/ChatPage.swift:1283`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/ChatPage.swift#L1283)
- **触发** 打开有几千条记录的对话，进「在对话里找」或「问答目录」。在搜索框继续输字，随后退出搜索。
- **后果** 主线程最多循环 30 次，每次把加载上限加 160，再从已载入的历史重建扩大后的行数组和时间索引。加载后 `shownCount` 拉成全部已载入行数，普通 VStack 会保留整页；搜索时每一行取 `currentHit` 都重新遍历全文。长对话容易卡住或掉帧，且超过加载上限的旧记录会直接漏搜。
- **建议** 在已落盘对话上单次建立轻量索引，词变化时只计算一份结果并把命中 ID 传给各行。滚到目标时只扩展所需窗口，退出后恢复原窗口。若保留历史上限，明确显示尚未搜索的范围。

## 3. [P2] 分享名帖图片会带出旅伴的记忆条数

- **定位** [`App/Sources/Reading/NameCardView.swift:167`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/NameCardView.swift#L167) · [`App/Sources/Reading/NameCardView.swift:74`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/NameCardView.swift#L74) · [`App/Sources/Reading/NameCardView.swift:199`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/NameCardView.swift#L199) · [`App/Sources/Reading/NameCardView.swift:233`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/NameCardView.swift#L233) · [`App/Sources/Reading/NameCard.swift:19`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/NameCard.swift#L19)
- **触发** 让一位旅伴主动记下至少一件事，打开名帖并分享 PNG。
- **后果** 导出的 PNG 使用真实的 `remembers` 值，接收方能看到「关于你的 N 件事」。泄露的是记忆条数。结构化名帖的 JSON 字段只包括角色资料和头像。
- **建议** 给导出图片单独使用公开视图，隐藏「记得」一栏或改成不含个人统计的文案。本机预览仍可展示原来的条数。用实际导出图片加一条隐私回归检查。

## 4. [P2] 白纸仍有默认口吻，心绪开关只管提示词

- **定位** [`App/Sources/Temper.swift:68`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Temper.swift#L68) · [`App/Sources/Temper.swift:131`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Temper.swift#L131) · [`App/Sources/Temper.swift:164`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Temper.swift#L164) · [`App/Sources/Team.swift:1785`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Team.swift#L1785) · [`App/Sources/Team.swift:1812`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Team.swift#L1812) · [`App/Sources/Team.swift:1525`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Team.swift#L1525) · [`App/Sources/Team.swift:1595`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Team.swift#L1595) · [`App/Sources/Team.swift:1636`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Team.swift#L1636)
- **触发** 创建「白纸」旅伴并保留默认说话风格，在自定义设定里写要求用英文和正式语气。再用会自行返回心绪标签的模型验证。
- **后果** 白纸的性格提示为空，但默认风格仍在自定义设定之后追加「中文、口语」。对非白纸旅伴，用户写明省略心绪时，后续还会拼上要求必须先写心绪的指令。白纸或心绪开关关闭时，流式和落盘两处仍无条件提取心绪标签，模型自行输出时仍可能出现心绪卡。
- **建议** 统一设定、性格和风格的优先级。白纸且用默认风格时跳过额外口吻指令，让用户设定覆盖默认项。按本轮的心绪设置和实际发言者控制流式解析及落盘，验证开关与历史数据的表现。

## 5. [P2] 自定义宠物头像只能在已有同一宠物包的手机上恢复

- **定位** [`App/Sources/Reading/NameCard.swift:28`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/NameCard.swift#L28) · [`App/Sources/Reading/Desk.swift:415`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/Desk.swift#L415)
- **触发** 用自己导入的宠物包作旅伴头像，递名帖给尚未导入该包的另一台手机。
- **后果** 名帖只携带宠物包 ID。收帖检测不到相同 ID 就直接使用接收者的默认宠物，收帖成功提示没有说明头像已变。照片和双方都有的内置宠物走各自的现有路径。
- **建议** 确定自定义宠物的传递形式。可随名帖附有明确尺寸上限的定格头像，或保存受校验的宠物包附件。回退时明确提示，并保留原 ID 便于用户装包后恢复。

## 6. [P2] 长图在预览编辑过程中同步重画，问题超过八行会被截断

- **定位** [`App/Sources/Reading/NoteSheet.swift:82`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/NoteSheet.swift#L82) · [`App/Sources/Reading/NoteSheet.swift:114`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/NoteSheet.swift#L114) · [`App/Sources/Reading/NoteSheet.swift:135`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/NoteSheet.swift#L135) · [`App/Sources/Reading/NoteSheet.swift:169`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/NoteSheet.swift#L169)
- **触发** 对带大量正文或图片的回复打开「做成长图」，改标题或换主题。让原始提问长于八行后导出。
- **后果** 工具栏求值就会在主线程以 3 倍尺寸重做整张图片。长内容或频繁编辑时会争用界面时间，图片亦可能超过可用内存。勾选带上问题仍只显示前八行，导出中会缺原文。
- **建议** 在用户点保存或分享时生成位图，按输入状态复用结果。对极长内容限制单张像素数并分页。预览需要收起长问题时，导出用独立布局保留完整提问。

## 7. [P2] 长健康报告的卡片可能显示错误的最后几天和截断的数值

- **定位** [`App/Sources/Grant/Health.swift:172`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Grant/Health.swift#L172) · [`App/Sources/Grant/Health.swift:175`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Grant/Health.swift#L175) · [`App/Sources/Team.swift:1652`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Team.swift#L1652) · [`App/Sources/Reading/ChatPage.swift:2454`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/ChatPage.swift#L2454) · [`App/Sources/Reading/ChatPage.swift:3181`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/ChatPage.swift#L3181) · [`App/Sources/Reading/ChatPage.swift:3199`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/ChatPage.swift#L3199)
- **触发** 旅伴一次读取 30 天且包含多个健康项目，各天数据齐全。用完整步数、睡眠和心率等字段组成的本地样本超过了 3000 字。
- **后果** 工具按从旧到新返回，落盘只保留前 3000 字。卡片在前缀里取最后三天，可能遗漏实际最近几天，也可能把最后一行截到数值中间，显示一个实际不存在的心率。
- **建议** 在健康工具端单独产出供卡片读取的结构化最近三天摘要，保留明确的日期、项目、数值和单位。卡片直接读取摘要，勿从被截断的通用工具文本反推。

## 8. [P3] 群聊中「明」和「活」的心绪标签会在出字时显示为「温」

- **定位** [`App/Sources/Reading/ChatPage.swift:249`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/ChatPage.swift#L249) · [`App/Sources/Temper.swift:13`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Temper.swift#L13) · [`App/Sources/Reading/ChatPage.swift:1218`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/ChatPage.swift#L1218)
- **触发** 在群聊让「明」或「活」接话，观察写入沉思或念头、回复落盘前后。
- **后果** 实时心绪把群聊发言者传成 nil，触发默认「温」。落盘后才按发言者 ID 选性格，导致标签和符号中途切换。
- **建议** 把当前发言者 ID 与实时心绪一起送到聊天模型。实时和已完成的块按同一个发言者或当轮存下的性格显示。

## 9. [P3] 一眼卡的最近产出在任务完成后不会更新

- **定位** [`App/Sources/Reading/Glance.swift:44`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/Glance.swift#L44) · [`App/Sources/Reading/Glance.swift:67`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/Glance.swift#L67) · [`App/Sources/Reading/Glance.swift:101`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/Glance.swift#L101) · [`App/Sources/Team.swift:1691`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Team.swift#L1691)
- **触发** 任务进行中打开头像的一眼卡并让它保持打开，等任务写出新文件。
- **后果** 状态文字会跟随 Team 更新，但最近产出只在 .task 打开时取一次。完成后，仍显示旧文件或空白，需要关卡重开。每次重开还扫描当前对话的全部文件记录。
- **建议** 从文件快照更新或任务结束事件刷新最近三项，按对话键复用结果，让状态和产出同步更新。

## 10. [P3] 新界面仍有写死的称谓和固定排版

- **定位** [`App/Sources/Reading/CardEditors.swift:254`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/CardEditors.swift#L254) · [`App/Sources/Reading/ChatPage.swift:791`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/ChatPage.swift#L791) · [`App/Sources/Reading/Glance.swift:98`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/Glance.swift#L98) · [`App/Sources/Reading/NameCardView.swift:69`](https://github.com/lllhr94/Clio/blob/955315934326e31e4abe1e3995128a7f65044d03/App/Sources/Reading/NameCardView.swift#L69)
- **触发** 切换日常和书卷称谓，查看性格编辑、名帖和问答目录，再调大系统字号查看一眼卡。
- **后果** 两本词典键集合一致，但目前这些页面部分文本直接写中文，切换称谓不会覆盖全部功能标题。一眼卡使用固定字号，文字不会随系统字号变大。卡片固定 320 点且部分文字锁行，窄屏和较长文案容易被截断。
- **建议** 将新增功能名和提示统一从 `L.t` 取词，两本字典同步加键。用可用宽度和共享尺寸布局一眼卡，大字号时让状态和动作折行。

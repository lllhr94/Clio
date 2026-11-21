# Clio 0.34 修复交接

审查基线为 `batch-0.34` 的 `a97c06a`。截至本次交接共 32 条，编号沿用 下方的完整审查报告。各条的源码行号、触发条件、复现范围和建议见原报告。所有条目待修，本次仅记录。

## 第一批 · 发布前优先

| 报告编号 | 修复范围 | 验收条件 |
|---|---|---|
| #1、#20 | 备份恢复事务和聊天落盘状态 | 截断包、校验失败、磁盘写失败都不会半覆盖本地。恢复与后台保存串行。导出会等到写盘成功，未成功时给出明确反馈。 |
| #12、#13、#14、#15 | 工作文件回滚、对话归档 | 读取错误不会被当作文件不存在。原远山不存在或身份变更时停止还原。回滚失败保留可重试的副本。读不了的对话归档和索引都保留。 |
| #2、#16、#19 | 模型流式完成、取消和迟到回调 | 合法的 OpenAI／Anthropic 完成信号和非流式返回照常工作。断流保留已写正文并标记未完成。取消后不启动新工具，过期事件不写进新对话。被过滤或只回半句时，不发成功通知或用来提交摘要。 |
| #3、#17、#21 | 远游导航、网页权限和问答归属 | 两段对话并行时，操作绑定自己的标签、页面版本和许可。上个导航的超时不结束下个导航。旧问答提交被拒绝，停止另一轮不取消本轮问答。 |
| #4、#5 | WebDAV 传输、远山变更 | WebDAV 上传和恢复默认使用 HTTPS，备份带密钥需单独确认。改主机、账号或端口后旧连接及隧道失效，新操作只到新目标。 |

## 第二批 · 卡顿和聊天手感

| 报告编号 | 修复范围 | 验收条件 |
|---|---|---|
| #29 | 掉帧记录器 | 超过 200 条的测试仍按时间或累计事件节流保存。60／120 Hz 的检测口径写在记录里。复用此前原始记录时注明设备、操作和采样时长。 |
| #22、#23 | 首开长对话、发送、流式布局、用量圆环 | 文件读取与可移出的准备工作在后台。用量估算不加载图片内容。高频小块流式更新有上限，末尾只补最后一次更新；历史前缀不会每次重扫。 |
| #24、#25、#32 | 历史分页、搜索、小地图 | 超过 160 条原始消息后仍能继续上滑；加载旧页维持视口。连打搜索词只导航到最新查询；小地图有可用触区和 VoiceOver 等价入口。 |
| #26、#30 | 终端输出、宠物浮层 | 大量终端输出先分对话合并后再刷新界面，两个旅伴的输出各归其对话。弹层拖动和键盘时宠物跟随，静置后停止每帧采样。 |
| #7、#11、#27、#31 | 草稿附件、大图、长输入 | 大图转码和长粘贴离开主线程，写失败保留草稿。发送或重选后，旧取图任务不能把附件带进下一份草稿。图片缓存有字节上限。 |
| #28 | 养护页 WebDAV 配置 | 渲染读内存状态，密码读取及保存脱离每次界面刷新和每次按键。 |

## 第三批 · 迁移和边界

| 报告编号 | 修复范围 | 验收条件 |
|---|---|---|
| #6 | 备份迁移范围 | 核对书案、导入宠物和未发送草稿。备份内容按实际支持项显示，向旧格式兼容。 |
| #8、#9 | SSH 退出状态、外部数字 | 长输出截断后仍拿到真实退出状态。模型、天气和工具的异常数值返回可读错误或安全值。 |
| #10、#18 | 天气历史和对话压缩 | 旧天气卡显示日期和抓取时间，缺测有占位。压缩切点符合保留条数，标记只覆盖进入完整摘要的原文。 |

## 接手和验收

1. 从最新 `batch-0.34` 核对已经修过的条目。谁动 `Team.swift`、`ChatPage.swift` 或 `Browser.swift`，先按上表模块分工，避免两个分支并行改同一处状态。
2. 优先把已复现的故障写成回归测试。原报告中已隔离复现的条目用于验证逻辑；涉及 WebKit、系统后台、钥匙串延迟、触控和实际帧耗时的条目仍需真机。
3. 性能验证先测同一台 iPhone 的同一段长对话，逐项清空记录。分别测闲置、连打、发送、首开设置、终端输出、选字和回到底部。旧记录中的 29,593 ms 和闲置周期卡顿，根因仍待分项测量。
4. 修复分支通过 lint、聊天流程、AgentKit 测试和 iOS CI（`shots=false`）再交 PR。PR 按编号回填修复提交、验证结果和剩余事项。以实际需要的统一测试包做真机验收。

---

# Clio 0.34 全项目代码审查

审查基线为 `batch-0.34` 的 `a97c06a`。0.34 试签包构建自 `015144b`，两者只差一条 `docs/STATUS.md` 更新。审查沿入口追了引导和设置、对话与数据落盘、AgentKit 和模型接口、工具审批、远游、远山和 斗室、连接器、备份和记忆，再核对近期天气、字体、宠物、通知与构建。优先看数据丢失、误操作、卡死与隐私边界。此轮为代码审查，线上分支和业务源码未改。

## P1 优先修

### 1. 恢复备份到一半报错，已有数据已经被覆盖

恢复一边读档案一边写到现用目录，同时应用偏好和密钥。文件截断或后一项写入失败时，前面已写入的内容保留，用户收到的却是简短的失败提示。入参长度还直接从 UInt64 转 Int 并相加，超出范围时进程会中止。两个恢复入口都直接调用这段同步逻辑，大包还可能卡住界面。

**验证。** 用真实解析代码和独立临时目录复现。正常导出后只截掉最后一个字节，恢复提示「备份文件不完整」，本地测试文件仍已被换成备份里的版本。长度越界依据源码确认。

**建议。** 先完整校验文件和长度，再后台写入暂存目录。成功后统一替换数据，并在切换期间暂停现用数据写入。偏好与钥匙串条目也要有明确的提交或回滚策略。 [Backup.swift:69](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Care/Backup.swift#L69) · [CarePage.swift:135](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Care/CarePage.swift#L135) · [CarePage.swift:224](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Care/CarePage.swift#L224)

### 2. 流没收完或已经点了停止，工具仍可能开始执行

引擎在收到已可解析的工具参数后，即使响应流直接结束、没有可辨识的结束信号，也会进入工具循环。审核通过后到调用工具之间也缺少取消检查。收到部分响应或点了「停止」时，写文件、发消息等工具可能仍被调用。

**验证。** 两个本地 Swift 样本都执行了真实 `Agent.run` 与只会累加计数的假工具。断流样本在没有结束事件时计数加 1。停止样本在开始执行前取消，最终回报取消，计数仍加 1。

**建议。** 让适配器明确区分完整响应与断流，只有完整工具调用且未取消时才执行。保留提供商明确的结束信号及非流式兼容路径。在等待审批返回后再次检查取消。 [Agent.swift:233](https://github.com/lllhr94/Clio/blob/a97c06a/AgentKit/Sources/AgentKit/Agent.swift#L233) · [Agent.swift:306](https://github.com/lllhr94/Clio/blob/a97c06a/AgentKit/Sources/AgentKit/Agent.swift#L306) · [Provider.swift:130](https://github.com/lllhr94/Clio/blob/a97c06a/AgentKit/Sources/AgentKit/Provider.swift#L130)

### 3. 远游的当前标签和网站授权跨对话共用

全 App 只有一个浏览器，工具总操作屏幕上的当前标签。两个旅伴同时办事，或用户在等待批准时换标签，之后的读、点、填会使用当前页。网站许可也是全局表，一轮的启动会清另一轮的许可，另一轮授予的许可又可能被共享。读页、填字的批准与真正使用的标签未绑定。

**影响。** 旅伴可能读到用户刚切去的已登录页面，把内容带入另一段对话，也可能在错误页面提交。静态追踪确认共享状态和缺少绑定，WebKit 并发顺序待 iPhone 验证。

**建议。** 用对话和轮次隔离许可，工具绑定稳定的标签 ID 与页面版本。提交或填字前验证刚批准的目标仍一致，切页时要求重新读取或批准。标签可共用登录存储。 [Team.swift:194](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L194) · [Team.swift:1373](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L1373) · [Browser.swift:494](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Roam/Browser.swift#L494) · [Browser.swift:529](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Roam/Browser.swift#L529) · [Browser.swift:564](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Roam/Browser.swift#L564)

### 4. WebDAV 允许明文上传备份和凭据

WebDAV 接受 HTTP，App 放开了传输安全限制。请求用 Basic Auth，备份文件本身无加密。用户如果填的是 HTTP，网盘账号密码、对话、记忆及照片会明文传输。勾选带上密钥时，同一个开关也影响网盘上传，文件还会携带模型 API 密钥。依据请求构造、App 配置和档案格式确认，审查未发真实请求。

**建议。** WebDAV 默认只接受 HTTPS。传输前说明备份包含的内容，上传带模型密钥的版本应有独立明确的选择。 [WebDAV.swift:19](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Care/WebDAV.swift#L19) · [project.yml:99](https://github.com/lllhr94/Clio/blob/a97c06a/App/project.yml#L99) · [CarePage.swift:208](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Care/CarePage.swift#L208) · [备份格式](https://github.com/lllhr94/Clio/blob/a97c06a/docs/BACKUP-FORMAT.md)

### 5. 更改远山主机后，后续命令可能仍在旧主机执行

修改现有主机时会沿用 ID 并保存配置，但连接池只按 ID 查尚在使用期的连接，没核对地址、端口或账号。更改后立即执行可能命中旧连接，界面和工具已使用新主机信息。转发隧道也按主机 ID 与服务目标缓存。依据保存和缓存路径确认，待两台测试主机确认连线过程。

**建议。** 主机连接配置一变就使 SSH 和隧道缓存立即失效，重连完成前阻止新操作。连接池按配置版本识别连接，主机删除时也关掉旧会话。 [Hills.swift:59](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Hills/Hills.swift#L59) · [Hills.swift:644](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Hills/Hills.swift#L644) · [Tunnel.swift:27](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Hills/Tunnel.swift#L27)

## P2 下一批修

### 6. 当前备份无法完整迁移

现有格式只收 Application Support 下的 Team、Portraits 和部分偏好。书案文件在 Documents；导入的宠物包使用自己的目录；草稿图在 Caches，草稿文字和文件列表的键也不在备份范围。迁机后聊天中的旧文件链接可能打不开，草稿和部分头像设置也会丢。依据实际存储位置和导出白名单确认。

**建议。** 将这些数据纳入带版本的备份，或在生成前逐项明确展示范围。用一份含文档、图片、宠物和草稿的迁移样本核对。 [Backup.swift:5](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Care/Backup.swift#L5) · [Workspace.swift:10](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Study/Workspace.swift#L10) · [PetLibrary.swift:63](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Pet/PetLibrary.swift#L63) · [ChatPage.swift:3714](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L3714)

### 7. 草稿附件保存时先删后写，发送时不立即清理旧附件

切对话或进后台时，代码在主线程删掉旧图片目录，再一张张写新文件，忽略失败。中途写入失败或 App 被结束，原来成功保存的副本也可能丢。发送时清的是内存数组，直到下次离开或进入后台才清附件磁盘副本。在中间意外退出时，下次打开可能带回已发送的附件。磁盘清理与发送、备份需一起测试，尚未做 iOS 中止实验。

**建议。** 用单一草稿清单和后台原子替换保存附件，发送成功后同步提交清理操作。保存失败时保留上一份完好的副本。 [ChatPage.swift:578](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L578) · [ChatPage.swift:2665](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L2665) · [ChatPage.swift:3742](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L3742)

### 8. SSH 输出很多时会在拿到退出状态前报成功

远程命令累积输出超过 200,000 字符就提前退出读取循环。此时退出码还留在初始值 0，后续失败状态不会被读取。终端和旅伴都可能把失败或尚在运行的命令当成成功。依据返回路径确认。

**建议。** 达到上限后停止累积但继续排空，直到拿到实际退出状态；超时或取消返回明确状态，并标记输出有截断。 [Hills.swift:149](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Hills/Hills.swift#L149)

### 9. 模型和天气的数值转换可能让 App 退出

读取模型上下文长度、天气天数、浏览器标签编号时，把外部 JSON 的 Double 直接转 Int。超出 Int 范围会在 Swift 中中止，天气天数的限幅在转换之后，阻止不了。标签编号在生成进度文本时就开始转换。依据转换顺序确认。

**建议。** 在处理外部数字的共同边界用可失败的转换，先校验有限值、范围和是否为整数，必要时返回工具参数错误。 [OpenAIProvider.swift:47](https://github.com/lllhr94/Clio/blob/a97c06a/AgentKit/Sources/AgentKit/OpenAIProvider.swift#L47) · [Weather.swift:20](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Weather.swift#L20) · [Browser.swift:500](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Roam/Browser.swift#L500)

### 10. 查看昨天的天气卡，第一行仍写「今天」

天气卡把第一、二行无条件标为「今天」「明天」，按日期号做的解析从第三行才开始。返回旧对话时会把历史预报当成实时预报。跨时区的预报也缺少明确的地点日期。另一个缺测场景会把空温度显示为 0℃。依据卡片和工具格式确认。

**建议。** 保存查询时间、预报地点时区与原始日期。只对相对于预报地点当前日期的记录写「今天」「明天」，历史卡显示日期和抓取时间，缺测显示「—」。 [ChatPage.swift:3778](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L3778) · [Weather.swift:27](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Weather.swift#L27)

### 11. 反复聊图片会累积整张图片的内存缓存

模型请求读取的照片按文件名永久放进进程内的字典，缓存没有张数、字节或有效期限制，读失败的结果也长期记着。反复打开含图对话、发送不同图片后，字典持有此前加载的原始字节，即使当前对话已经不用它们。内存增长依据对象持有关系确认，具体峰值待真机。

**建议。** 用有字节上限的缓存，只长期记必要的格式或校验信息。恢复备份、替换图或收到内存警告时清理对应缓存。 [Library.swift:203](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Library.swift#L203) · [Team.swift:1841](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L1841)

## 验证记录和测试缺口

- 最新试签包对应的 CI 通过了 lint、聊天流程、AgentKit 测试和 iOS 编译。截图关闭。此次审查没有重跑发布流程。 [CI 44895339886](https://github.com/lllhr94/Clio/actions/runs/44895339886)
- Linux 本地通过全部 151 个 Swift 文件的语法检查、lint 和聊天流程夹具，夹具仍报告现有的流式列表、表格遇内部空行时冻结的已知问题。整套 `swift test` 依赖 Apple 的 NaturalLanguage，已用上述 macOS CI 结果核对。
- 三个隔离样本确认了截断备份先覆盖文件、响应未正常结束仍执行工具和取消后仍执行工具。样本只用临时数据和计数工具，未访问真实账号或服务。
- 中文等宽字体静态抽查通过。拉丁 A、i、0 为 600 单位，中文「中、文、天」为 1200 单位，两个字体每 em 都是 1000 单位。系统字体选项和 GB2312 之外的字形走回退，终端和代码块的实际排版仍待 iOS 验证。
- iOS 真机交互、后台恢复时机和性能未实测。现有 CI 会编译 App，但缺少备份事务、远游跨对话和 SSH 切换的集成测试。此次梳理了各模块的关键路径，未对约 3.8 万行 Swift 逐行人工证明。

## 第二轮故障注入与边界复核

基线仍为 `a97c06a`，复核期间远程分支未前进。对文件 I/O 错误、断流、取消后回调、远山删除、连续浏览、历史归档及长输入逐项追踪。本轮新增 9 条，其中 7 条通过隔离样本复现，另外 2 条由源码路径确认。样本运行实际业务逻辑，文件环境、网络、界面和系统服务按需替换成测试对象。

### 12. [P1] 读取旧文件失败，回滚把现有文件当成新建文件删掉

**触发与后果。** 创建快照时，`try? await host.readFile` 把“不存在”和“暂时无法读取”都变成 nil。若写操作随后成功，回滚把这个 nil 当作文件原先不存在，调用删除。一次短暂的读取错误可能最终丢掉工作文件。

**验证与修法。** 用假文件系统注入读取失败，调用真实快照和回滚逻辑，观察到删除调用。区分不存在、成功读取和读取失败；取不到可靠快照时明确告知，阻止声称可撤回的修改。 [Snapshots.swift:56](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Study/Snapshots.swift#L56) · [Snapshots.swift:112](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Study/Snapshots.swift#L112) · [WorkspaceTools.swift:153](https://github.com/lllhr94/Clio/blob/a97c06a/AgentKit/Sources/Craft/WorkspaceTools.swift#L153)

### 13. [P1] 删除远山主机后，回滚会写到本机书案

**触发与后果。** 回滚根据快照里的工作地点重新选目标。历史主机已删除时，工作地点会回退到书案，回滚依然执行写入或删除。手机书案若有同名文件，可能被覆盖或删除。

**验证与修法。** 用实际工作地点选择与回滚代码，准备两个分开的假文件系统。创建远程快照后删掉主机，再回滚，手机端的同名文件被覆盖。回滚要求原目标存在且身份一致，找不到时中止并保留副本。 [Snapshots.swift:104](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Study/Snapshots.swift#L104) · [Place.swift:51](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Study/Place.swift#L51)

### 14. [P1] 第一次还原文件失败后，原版本也被丢掉

**触发与后果。** 权限变化、磁盘空间不足或远程断网都可能让某项还原失败。虽然失败项会显示出来，用于下次还原的文件和索引却会被一并删除，等连接恢复也无法再试。聊天入口还会在还原失败后启动重跑。

**验证与修法。** 注入一次写回失败，再恢复可写并重试。第一次报告失败，第二次已经找不到快照。仅清理还原成功的项，保留失败项；还原未完成时把后续重跑交给用户确认。 [Snapshots.swift:118](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Study/Snapshots.swift#L118) · [Team.swift:1786](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L1786)

### 15. [P1] 归档读不出来时，打开操作仍会删除归档

**触发与后果。** 打开旧对话时，文件读取或解析失败会被当成空对话，随后删除旧文件、摘要和索引。当旧格式不兼容、文件损坏或暂时读不到时，原本可保留待恢复的数据会被永久删除。

**验证与修法。** 给实际 `openLeaf` 方法注入一次读取失败，验证它打开空白对话并删掉归档与索引。读取必须区分真实空档案与失败；先验证，再确认新状态已落盘，然后才删旧档。 [Team.swift:1183](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L1183) · [Library.swift:170](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Library.swift#L170)

### 16. [P2] 清空、重来或切换归档后，上一轮的迟到结果会写进当前对话

**触发与后果。** 这些操作请求取消旧任务后马上替换聊天记录。旧任务仍可发布最后一个工具结果或停止提示，回调只带聊天键，入库时没有核对轮次。迟到的旧数据可能使刚清空的聊天重新出现内容，或混进打开的旧档。由取消顺序与回调检查确认，实际 SwiftUI 操作时序待真机验证。

**建议。** 把对话版本和轮次标识传到写入层；历史被替换后拒收旧事件。仍需要保留的旧任务结果写回其所属归档。 [Team.swift:1118](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L1118) · [Team.swift:1162](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L1162) · [Team.swift:1613](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L1613)

### 17. [P2] 上次导航的超时会提前结束这次网页等待

**触发与后果。** 导航完成后旧计时任务还在运行，新导航把续体放进共用的 `loaded`。旧计时到点时会唤醒新导航，工具可能在页面没加载完时读取它，或把未加载完的页面报成已打开。

**验证与修法。** 抽取实际等待逻辑，用假加载状态完成 A 后发起 B。B 还没到自己的超时，A 的计时已将它唤醒。给每次导航配独立标识与可取消计时，完成回调与超时都核对所属导航。 [Browser.swift:151](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Roam/Browser.swift#L151)

### 18. [P2] 压缩标记可覆盖模型根本没读到的历史

**触发与后果。** 压缩会把超长原文截成最后 60,000 字，但仍报告并标记整个较早区间。另外，为找用户消息边界而往后移动切点，实际留下的消息可能少于设置值。原文仍能翻，模型会丢失未进入提要的重要约定。

**验证与修法。** 用实际 `Turns` 代码验证两个样本：设置保留 5 条，最后只保留 1 条；统计压缩了 2 条，其中一整条没进入模型的输入。按完整轮次选择切点和分批总结，标记只覆盖已成功写入提要的区间。 [Turns.swift:56](https://github.com/lllhr94/Clio/blob/a97c06a/AgentKit/Sources/Craft/Turns.swift#L56) · [Turns.swift:68](https://github.com/lllhr94/Clio/blob/a97c06a/AgentKit/Sources/Craft/Turns.swift#L68) · [Team.swift:971](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L971)

### 19. [P2] 有半句回答的断流可以看起来像答完

**触发与后果。** 服务先发一点正文，再在没有结束信号时关闭响应。引擎照常返回，没有断流提示；相同情况也能把半截文字当成完整摘要。即使发出明确的「被过滤」事件，引擎仍正常返回。上层以此发完成消息，并可能继续发送排队内容。

**验证与修法。** 两种响应都用假模型跑过实际引擎，分别确认缺少断流提示、正常返回。上层通知和队列行为由源码确认。保留已收到的正文，同时将完整、部分、过滤和失败作为独立结果交给上层，长文摘要只在完整返回时提交。 [Agent.swift:109](https://github.com/lllhr94/Clio/blob/a97c06a/AgentKit/Sources/AgentKit/Agent.swift#L109) · [Agent.swift:245](https://github.com/lllhr94/Clio/blob/a97c06a/AgentKit/Sources/AgentKit/Agent.swift#L245) · [Team.swift:1613](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L1613) · [Team.swift:1558](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L1558)

### 20. [P2] 聊天写盘失败后，备份仍可能成功返回

**触发与后果。** 磁盘满或写入报错时，后台保存调用吞掉错误，随后仍把请求标为完成。备份只等队列排空，可能读到上一份旧文件并成功导出，界面中刚看到的新消息却不在里面。依据错误传播路径确认，未在 iPhone 上填满磁盘。

**建议。** 保存记录区分排队、持久化成功和失败；失败时保留可重试状态，备份发现未成功写盘的对话时给出明确结果。 [Library.swift:175](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Library.swift#L175) · [ChatDisk.swift:11](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/ChatDisk.swift#L11) · [Backup.swift:18](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Care/Backup.swift#L18)

## 尚需集成或真机验证

| 场景 | 复测目标 |
|---|---|
| 恢复进行中触发后台保存；恢复后立即退出 | 文件、索引、偏好与钥匙串保持同一份恢复结果 |
| 文件回滚遇到远山改址、掉线，或书案同名文件 | 只在原工作位置还原，失败仍能重试 |
| 两个旅伴同时浏览，或等待批准时手动切标签 | 等待、许可、目标页和表单属于同一轮，同一标签 |
| 清空、切归档或重来时仍有工具执行 | 后到的事件无法污染新对话 |
| 自动整理时切换前后台、修改权限或断网 | 失败有记录，重启不漏处理、不重复写记忆 |
| 小屏、最大字号、选字、滚动及耗时 | 在同一真机按单一动作取样，并核对位置、剪贴板和掉帧记录 |

本轮未操作真实账号、远山主机或用户文件。源码与远程分支未修改。

## 第三轮性能与 UI 深查

基线仍为 `a97c06a`。这轮新增 12 条，4 条用隔离 Swift 样本复现，其余 8 条通过源码确认。按入口追踪首开聊天和设置、输入和发送、流式出字、终端输出、翻历史、搜索、相册、问答、宠物浮层、小地图和掉帧仪。以下 Linux 结果只证明执行次数、数据流和计算规模，iPhone 的帧时与交互需要设备复测。

### 21. [P1] 两个旅伴同时提问，旧表单可以把回答交给另一轮

**现象。** 短问答使用全局 `Asker.current`，聊天页只检查自己是否在干活，不核对提问来自哪段对话。新问题会取代旧问题，提交按钮未传表单 ID，停止任意运行中的对话也会尝试取消全局表单。

**验证。** 用实际问答控制逻辑复现。B 打开后 A 的等待被取消，再以旧界面提交样本文字，B 收到了答案。两页实际显示顺序待真机验证。

**修法。** 问答保存对话与轮次归属，提交、取消都核对表单 ID。并行提问可排队或分对话显示，旧界面提交应被拒绝。 [Secrets.swift:109](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Vault/Secrets.swift#L109) · [ChatPage.swift:507](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L507) · [InlineAsk.swift:42](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/InlineAsk.swift#L42) · [Team.swift:1364](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L1364)

### 22. [P2] 首次进长对话、开始发送和回复收尾都还有主线程重活

**现象。** 首次打开某段聊天时同步读并解码整段 JSON，再截取供显示的行。用量圆环在进入、模型变化、回复结束、行数变化等路径重算，主线程会建完整的上下文、取图片、序列化工具参数。技能缓存过期时，这条路径还能重新扫描和读取技能文件。同一轮实际发送又会准备上下文和工具。C30 移走了部分启动与写盘工作，但这些路径仍在。对应旧掉帧记录中的首开、已递出和收尾，具体耗时待分项测量。

**修法。** 后台读首屏快照。用量计算复用请求的轻量统计，按对话版本合并触发，统计图片张数时不用加载图片内容。真实发送将可离开主线程的准备工作移出。 [Chat.swift:143](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Chat.swift#L143) · [Team.swift:725](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L725) · [ChatPage.swift:493](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L493) · [Team.swift:1575](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L1575) · [Team.swift:2077](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L2077) · [Skills.swift:39](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Skills.swift#L39)

### 23. [P2] 流式长回复每次从头扫描，限频可被小数据块绕过

**现象。** 流式布局每次更新从开头扫到末尾找最后一个完整块；每个新段落产生新的累计前缀，又会以整段文字为键调用解析缓存。与此同时，每次刚追上服务器数据块就无条件通过限频。多个几乎实时到达的小块可以让长回复在滚动过程中反复重排。

**验证。** 实际限频条件对一秒内 50 次「追上当前块」放行 50 次，超过代码注明的 15 次／秒；这表示允许的发布次数，实际 iPhone 布局次数还要测。实际前缀扫描在 80 次小尾部更新中，分别扫过约 94 万、469 万和 938 万字符，规模随累计正文增长。

**修法。** 在流持续时固定刷新上限，整轮结束才做最后一次强制刷新。保存已完成块和扫描进度，只处理新增尾部。 [Chat.swift:111](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Chat.swift#L111) · [Chat.swift:179](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Chat.swift#L179) · [ProseView.swift:57](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ProseView.swift#L57)

### 24. [P2] 上滑翻历史到达最近 160 条原始记录后会无提示停住

**现象。** 模型只生成最近 160 条原始记录对应的行。聊天页的「更早的」只扩大已经生成的行数，未调用模型里真正扩大历史窗口的方法，也未使用 `hasEarlier`。日志超出窗口时，普通上滑和「更早的」入口都无法继续；全文搜索和目录仍有独立读盘路径。

**修法。** 联通两层分页，加载前记录当前可见消息和偏移，旧页载入后维持位置。按消息含工具记录的真实边界测试。 [Chat.swift:103](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Chat.swift#L103) · [Chat.swift:205](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Chat.swift#L205) · [ChatPage.swift:132](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L132) · [ChatPage.swift:245](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L245)

### 25. [P2] 长对话搜索时，每次按键仍同步扫全文并安排滚动

**现象。** C25 把历史行的构建移到了后台。实际搜索仍在主线程逐行做本地化比较，每次编辑都会立刻跳往最新命中，并新增一个未取消的滚动任务。快速连续输入会在扫描的同时反复换历史窗口，较早查询安排的滚动也可能晚到。

**修法。** 对查询做短防抖，在后台以不可变快照匹配；只接受当前版本的结果，合并到一次跳转。 [ChatPage.swift:1475](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L1475) · [ChatPage.swift:1525](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L1525) · [ChatPage.swift:1546](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L1546)

### 26. [P2] 终端虽只显示五行，仍为每行输出在主线程排一个任务

**现象。** 每行输出都创建一个主线程任务。刷新时把这批全部构造成带 UUID 的行，再留下最后五行。该队列还被所有聊天共享，不同旅伴同时跑命令时，输出会混在一起，开始新工具也会清掉另一段对话的输出。

**验证。** 实际队列逻辑在压入 2,000 行后曾整批积压，最后只显示五行。两段对话的输出混合、另一段调用清空也影响第一段，均已在样本验证。

**修法。** 在生产端先按对话和轮次分组、限长、合并，主线程只接收节流后的最后几行。 [ToolTail.swift:13](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ToolTail.swift#L13) · [ToolTail.swift:36](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ToolTail.swift#L36) · [Team.swift:1943](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Team.swift#L1943)

### 27. [P2] 选大图和加载聊天图片会阻塞界面，异步选图还能写回已发出的草稿

**现象。** 相册和相机的缩图、JPEG 编码在 UI 回调里完成；正文图片路径也同步读本地文件、建立 UIImage，网址图片下载后同步写临时文件。相册任务等待取图期间，用户可以先发送当前内容或重选，旧任务完成后依然能追加图片、清掉新的选择列表，没核对草稿版本。

**修法。** 在后台按像素上限取缩略图、编码和写暂存文件。为选图绑定草稿版本，发送或重选后取消旧工作，并在发布前核对版本。 [ChatPage.swift:752](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L752) · [ChatPage.swift:761](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L761) · [ChatPage.swift:2665](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L2665) · [ProseView.swift:616](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ProseView.swift#L616)

### 28. [P2] 养护页每次构建界面仍可能同步查钥匙串

**现象。** 页面状态初始化会读取 WebDAV 密码。配置了地址和用户名且按钮未因任务被禁用时，两枚按钮各求一次 `ready`，各自同步读钥匙串；密码框每次变化又直接写钥匙串。首开和输入卡住都有明确的同步路径，但不能归因到旧记录里的那次 29.593 秒。

**修法。** 进入页面异步读一次，渲染只看内存状态。用户确认保存时写入，或为编辑使用防抖与离页提交。 [CarePage.swift:19](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Care/CarePage.swift#L19) · [CarePage.swift:41](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Care/CarePage.swift#L41) · [WebDAV.swift:13](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Care/WebDAV.swift#L13)

### 29. [P2] 掉帧记录满 200 条后会为每条新记录排一次写盘

**现象。** 保存条件用的是保留条数，而追加后立刻把条数裁回 200。达到上限后，每个独立的新事件都满足取模条件，整份记录会频繁排队编码和写入。固定 17 ms 门槛还漏掉 120 Hz 下部分漏帧，动作标签也只能说明当时有哪些状态。

**验证。** 注入时钟运行记录逻辑。前 199 条触发 9 次保存，第 200 到 250 条触发 51 次。另验证模拟 120 Hz 的一次漏刷新、约 16.7 ms 间隙，没有入库。

**修法。** 用累计事件数或时间防抖做写盘依据，报告观察窗口和实际刷新周期。做性能对照时把录制器的开销与被测页面分开。 [Diag.swift:57](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Care/Diag.swift#L57) · [Diag.swift:96](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Care/Diag.swift#L96) · [Diag.swift:113](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Care/Diag.swift#L113)

### 30. [P2] 打开附加面板后，即使静止，宠物仍每帧追踪窗口

**现象。** 60 Hz 的宠物位置采样只有在没有弹层等条件时会暂停。附件、用量、目录等面板打开并停着时，每帧仍查控制器层级、读取呈现图层的坐标。交互期间需要跟手，静置时没必要每帧重复。另一条每秒宠物计时主要只在状态变化时写入，源码不足以判定它是旧记录中闲置周期卡顿的根因。

**修法。** 只在弹层进入、交互拖动和键盘变化时启动追踪，稳定后暂停，交互重新开始时再唤醒。分别测开关宠物和面板静置。 [PetPerch.swift:127](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Pet/PetPerch.swift#L127) · [PetPerch.swift:173](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Pet/PetPerch.swift#L173) · [ChatPage.swift:525](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L525)

### 31. [P2] 普通输入仍有整串扫描和同步粘贴写盘

**现象。** 输入已经从主要聊天状态拆开，但每次变更还会数新旧草稿的字符，建议区也会查整段草稿里的触发符与空格。大量中文、复合字符与超长草稿时，工作会随草稿长度增长。触发长粘贴时，在同一界面回调内建目录、编码并写文件，结束后才更新附件。

**修法。** 普通键入只判断当前编辑或尾部命令，快速跳过粘贴路径。长粘贴后台转存，失败时保留输入文字，结果回写前核对草稿版本。 [ChatPage.swift:1149](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L1149) · [ChatPage.swift:2079](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L2079) · [ChatPage.swift:2545](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L2545)

### 32. [P3] 小地图刻度很难点，VoiceOver 没有入口

**现象。** 每道刻度自身只有 7–10 点宽、3 点高，跳转手势绑在刻度上。外层虽声明了区域形状，但没有对应点击处理。刻度按行数密排时容易碰到相邻项，整个小地图又被无障碍隐藏。实际误触和右边缘滚动手势的冲突待真机复测。

**修法。** 给整条小地图一个手势，将触点映射到最近的问题；为 VoiceOver 提供有名称的等价导航，保持聊天正文滚动优先。 [ChatPage.swift:2270](https://github.com/lllhr94/Clio/blob/a97c06a/App/Sources/Reading/ChatPage.swift#L2270)

### 真机复测顺序

| 操作 | 如何隔离 |
|---|---|
| 聊天闲置 30 秒 | 同一长对话，宠物开／关，面板闭／开，每组单独录；帧率仪另做开关对照 |
| 冷启动首开长对话，内有图 | 分别测打开、用量计算、打开大图、发送和回覆收尾，不与网络等待混在同一项 |
| 同一个长中文草稿 | 分开测连打、中文输入法组字、长粘贴、选大图后立即发送 |
| 流式及终端 | 用短块高频和长块低频各一次；分别在底部跟随、上滑读旧消息、两个对话同时出终端行 |
| 历史与小地图 | 超过 160 条原始记录，先用普通上滑，再高速键入搜索。iPhone SE、大号字体、iPad 分屏和 VoiceOver 核对刻度及选择 |
| 两个旅伴同时问答 | 验证表单归属、停止另一段是否会收起本表单，以及旧表单是否能误提交 |

本轮复跑 lint 与聊天流程夹具通过。夹具仍报告已有的列表、表格遇内部空行时冻结。审查只更新此报告，未改业务源码或触发发布。

## Claude 的修复记录（batch-0.34）

| # | 怎么修的 | 怎么验 |
|---|---|---|
| 1 | 恢复先整份校验，写进旁边的副本，再逐个文件夹替换，失败就换回；之后到重开前不再写盘 | 拿截断的备份恢复，手机上数据不变 |
| 2、19 | 没有结束信号的流算「断了」：不跑工具、不发「做完」通知、不接着发排队的话；被过滤、截断都单独告诉上层；`[DONE]` 算结束 | AgentKit 测试 `DroppedStreamTests` |
| 3 | 每段对话有自己的标签（不再拿用户屏幕上的那页，除非是空白页）和自己的网站许可；点、填、从信匣填之前核对页面还是上次读的那页，变了就要求重读；接手（handoff）属于提出它的对话，停另一段不会取消它 | 两段对话同时用远游；读完页面后手动换页再让它点 |
| 4 | WebDAV 只收 https，局域网 NAS 可用 http；网盘备份永远不带密钥 | 填 http 公网地址会提示 |
| 5 | 主机保存或删除后立刻关掉它的连接和隧道；连接池按「用户@地址:端口」认连接，改过就重连 | 改主机地址后马上跑命令 |
| 6 | 备份前写清带什么、不带什么（书案文件、导入的宠物、草稿、信匣） | 设置 › 备份说明 |
| 7 | 草稿附件在后台写进新文件夹，全部写好才替换旧的；发送时立刻清掉 | 加图后切后台再杀掉 App |
| 8 | 输出超过 20 万字后不再保存，但继续读到命令结束，拿到真的退出码，并注明截掉了多少 | `seq 1 200000; false` 应报失败 |
| 9 | 外部数字统一走 `JSONValue.int` / `Whole.int`：非有限、不是整数、太大都不转，工具参数给错误提示 | — |
| 10 | 天气结果记下查询时间和时区；只有当地今天查的卡写「今天」「明天」，旧卡显示日期和「几点查的」，「现在」改成「当时」；缺测显示「—」 | 打开昨天的天气卡 |
| 11 | 图片缓存只记「原样发送」或有限大小（24 MB）的重画结果，失败不记；内存警告和恢复备份时清空 | — |
| 12 | 改文件前读不出来（不是「不存在」）就记成「读不出」，撤回时绝不删它 | — |
| 13 | 撤回记下远山主机是谁；主机删了或改了地址就不动，不会落到书案 | — |
| 14 | 只有还原成功的才从记录里去掉，失败的旧版本留着；有失败就不自动重来，留一句话让用户决定 | — |
| 15 | 读不出来的旧絮语留着不动，提示先备份 | — |
| 16 | 每段对话一个轮次编号，清空、重来、换页后旧一轮迟到的字丢掉 | — |
| 17 | 每次等页面加载有自己的编号，旧计时器到点只结束自己那次；各标签各等各的 | — |
| 18 | 压缩切点往前挪到一轮开头，至少留下设置的条数；整理部分太长时整轮整轮往前挪切点，标记只算模型读到的 | Craft 测试 `testFoldKeepsAtLeastWhatTheSettingSays`、`testFitCutFoldsOnlyWhatTheDigestReads` |
| 20 | 写盘失败记下来，有没存进去的对话时备份拒绝生成 | — |
| 21 | 短问答排队，不再互相顶掉；提交、取消都带表单编号，过期的表单提交无效；对话页只显示自己的问答；停一段对话只收它自己的问答 | 两个旅伴同时 ask_user |
| 28 | 养护页的网盘密码只在打开时读一次钥匙串 | — |
| 32 | 小地图整条一个点按手势，就近跳到问题；VoiceOver 是一个「问题导航」，上下滑一个个问题跳 | — |

#22～27、#29～31 由 Codex 在 C31（PR #31）修好，已合入 batch-0.34：首开长对话和发送前的重活移到后台、流式出字限频、历史翻页到最早一条、搜索防抖、终端输出按对话分开并限量、选图和长粘贴移到后台、掉帧记录按屏幕刷新率判断、弹层静止时宠物不再每帧追踪。真机待看：翻页是否保住位置、慢速选图后马上发送、弹层拖动、同场景掉帧对比。

// Clio Design System 2.0 Interactive Prototype Engine (v5)
// Full Master Brief Section 19 & Deliverable #10 Motion Lab coverage:
// Same complex real Clio workflow across Directions A/B/C, 5 Global ViewStates (Normal/Empty/Loading/Offline/Outcome),
// Onboarding, Home, Empty Inscription, Full 18-element Markdown Chat, Streaming, Tools/Trace/PlanCard,
// Interactive InlineAsk, A/B/C ApproveView + Taint, Voice Capture, Attachments, Unified Global Search,
// Redesigned IA Sidebar, Model Roles, 4-Layer Memory, Flip NameCard, Pet Studio, Files+PDF KB, Roam Browser,
// Den Terminal + SSH Hosts, MCP Connectors + Skills, 8+1 Settings + StopRuler, Backup/WebDAV + Usage/Diagnostics,
// and Interactive Motion & Haptics Lab.

(function () {
  "use strict";

  const TOKENS = window.CLIO_TOKENS_V2;
  const PET = window.CLIO_PET_SPRITES;

  const SCENE_GROUPS = {
    core: [
      { id: "chat", label: "1. 长对话 · 全Markdown", sub: "H1-H3 / 代码 / 正文头像显隐" },
      { id: "onboarding_home", label: "2. 引导 · 首页 · 空对话", sub: "4步欢迎 / Home / 题词" },
      { id: "pet", label: "3. 宠物与身份定制", sub: "小克/肉包+3新宠 / 助手与我" }
    ],
    agent: [
      { id: "tools", label: "4. Agent 并发 · 清单", sub: "只读并发 / 思考 / PlanCard" },
      { id: "ask", label: "5. 主动提问 InlineAsk", sub: "单多选 + 自定义 + 涉密隔离" },
      { id: "approval", label: "6. 审批与外网卫士", sub: "Taint + A盖印 / B棘轮 / C潮汐" }
    ],
    ia: [
      { id: "search", label: "7. 全局搜索与侧栏 IA", sub: "跨 对话+记忆+PDF 聚合搜" },
      { id: "models", label: "8. 模型角色与即时切换", sub: "默认 / 备用 / 整理 / 生图" }
    ],
    workspace: [
      { id: "files", label: "9. 书案与 PDF 知识库", sub: "挂载目录 + FTS5 索引 + 互动HTML" },
      { id: "roam_den", label: "10. 浏览器 · 终端 · SSH", sub: "Roam接手 / Alpine / 远山" },
      { id: "ext", label: "11. MCP 连接器与技能", sub: "Google/GitHub/Notion + Skills" }
    ],
    settings: [
      { id: "memory", label: "12. 四层记忆与名帖", sub: "常记/近期/旧事/入藏 + 翻牌" },
      { id: "settings", label: "13. 8+1 设置与 StopRuler", sub: "中英别名搜 + 9项独立排版" },
      { id: "care", label: "14. 加密备份 · 用量诊断", sub: "WebDAV 恢复 + Flighty 统计" }
    ],
    motion: [
      { id: "motion_lab", label: "15. 动效与触觉实验室", sub: "4档弹簧 / 中途打断 / 零闪烁" }
    ]
  };

  function findGroupForScene(sceneId) {
    for (const [grp, items] of Object.entries(SCENE_GROUPS)) {
      if (items.some((it) => it.id === sceneId)) return grp;
    }
    return "core";
  }

  const SECTION46_SAMPLE = {
    proseText: "Clio 使用 SQLite FTS5 实现长期记忆检索，并通过 UICollectionView 与 CoreText 优化长对话渲染。支持 120 Hz ProMotion，目标单帧预算约为 8.33 ms。当前模型 Claude Sonnet，已调用 3 个 MCP 工具，累计使用 12,840 Tokens。「中文引号」、“英文混排”、数字 0123456789、全角标点、**粗体**、*斜体*、Emoji 🐱、特殊符号 ≈ ± √，以及 `API.status = 200`。",
    fullMarkdown: `## 二级结构：CLREQ 混排与光学验收样本

Clio 使用 SQLite FTS5 实现长期记忆检索，并通过 UICollectionView 与 CoreText 优化长对话渲染。支持 120 Hz ProMotion，目标单帧预算约为 8.33 ms。当前模型 Claude Sonnet，已调用 3 个 MCP 工具，累计使用 12,840 Tokens。「中文引号」、“英文混排”、数字 0123456789、全角标点、**粗体**、*斜体*、Emoji 🐱、特殊符号 ≈ ± √，以及 \`API.status = 200\`。

### 三级条目：列表密度与长链接核验

1. **安全行框规则**：以字面自然高度为底线，严禁裁剪特殊数学符号与 Emoji；
   - \`New York + PingFang\`：默认书卷搭配，兼顾中文清晰与数字衬线气质；
   - \`ClioKai-Medium\`：实测 xHeight 较小，内部 \`+4.5%\` 光学校准并收柔假粗体。
2. 源码定位：https://github.com/lllhr94/Clio/blob/batch-0.36/App/Sources/Reading/ChatListUIKit/ChatListModels.swift

| 字体组合 | 自然行高比 | 视觉校准 | 实测 Tokens/s | 状态 |
|---|---:|---:|---:|---|
| 书卷 (NY+苹方) | 1.40× | 1.00× | 12,840 | 默认推荐 |
| 霞鹜文楷 Medium | 1.184× | 1.045× | 12,840 | 人文长读 |
| Maple + MonoCN | 1.320× | 1:2 栅格 | 60 / 120 | 代码对齐 |

$$
\\text{safeLineHeight} = \\max(\\text{target}, \\lceil \\text{asc} - \\text{desc} \\rceil + 2\\text{pt})
$$

\`\`\`swift
// 流式未闭合代码围栏与定稿共享同一 FontOpticalProfile
let safeMin = max(readingSize * lineHeight, ceil(font.ascender - font.descender) + 2)
\`\`\`
`
  };

  // Same realistic scenario across all 3 languages (Section 19 invariant)
  const INITIAL_TURNS = [
    {
      id: 1,
      user: "帮我做个 0.36 发布前体检：按克制编辑式阶梯检验长文全元素排版，确认 Nginx 配置并核对指标表。",
      aiTitle: "0.36 发布前体检与长文排版基准",
      metrics: "1.48s · 526 tok",
      aiBody: `
        <h1 class="prose-h1">一级总览：0.36 架构体检结果 (21.5pt)</h1>
        <p class="prose-p">已完成对 <strong>UIKit 聊天管线</strong> 与 <span class="inline-code">clio-memory.db</span> 的交叉核验。流式生成到定稿瞬间 <del>不再使用渐隐叠层</del>，保持零闪烁交接。Clio 使用 SQLite FTS5 实现长期记忆检索，支持 <span class="inline-code">120 Hz</span> ProMotion（目标单帧 <span class="inline-code">8.33 ms</span>），累计使用 12,840 Tokens，「中文引号」、“英文混排”、数字 0123456789、🐱 ≈ ± √，以及 <span class="inline-code">API.status = 200</span>。</p>
        <h2 class="prose-h2">二级结构：列表密度与轻量化引用 (19pt)</h2>
        <ol class="prose-ol">
          <li><strong>首层序列表项</strong>：核心 SQLite FTS5 与 PDF 文档索引均已独立建表；
            <ul class="prose-list">
              <li>二级嵌套列表：只读工具允许并发读盘与查库（行高适度收紧至 1.50×）；</li>
              <li>写操作与 <span class="inline-code">ssh_run</span> 受外网 Taint 卫士强截保护。</li>
            </ul>
          </li>
          <li><strong>安全与密钥边界</strong>：参考 <a href="javascript:void(0)" class="prose-link">https://github.com/lllhr94/Clio/blob/batch-0.36/App/Sources/Reading/ChatListUIKit/ChatListModels.swift</a>。</li>
        </ol>
        <h3 class="prose-h3">三级节段：轻引用与数值右对齐表格 (17pt Semibold)</h3>
        <blockquote class="prose-quote">Apple HIG Materials 明确要求：<strong>Don't use Liquid Glass in the content layer</strong> —— 实时玻璃只服务导航与控件，正文保持纯净高对比可读性。</blockquote>
        <div class="prose-math">
          <div class="math-label">统一安全行框公式（替换旧 extraSpacing 单点算法）</div>
          <div class="math-expr">safeMin = max(size × m<sub>content</sub>, ceil(ascender − descender) + 2pt) &nbsp;|&nbsp; CR ≥ 4.5:1</div>
        </div>
        <div class="prose-table-wrap has-scroll">
          <table class="prose-table">
            <thead><tr><th>审计维度</th><th class="num">A 素笺</th><th class="num">B 清器</th><th class="num">C 栖息</th><th>0.36 状态</th></tr></thead>
            <tbody>
              <tr><td class="wrap-cell">外卡 / 内块圆角</td><td class="num font-mono">26 / 14pt</td><td class="num font-mono">18 / 10pt</td><td class="num font-mono">28 / 14pt</td><td class="font-mono">已对齐</td></tr>
              <tr><td class="wrap-cell">三阶灰字 AA 对比</td><td class="num font-mono">4.91:1</td><td class="num font-mono">4.94:1</td><td class="num font-mono">4.56:1</td><td class="font-mono">全部达标</td></tr>
              <tr><td class="wrap-cell">120Hz 帧预算</td><td class="num font-mono">8.33 ms</td><td class="num font-mono">8.33 ms</td><td class="num font-mono">8.33 ms</td><td class="font-mono">待实机测</td></tr>
              <tr><td class="wrap-cell">Token 实测示例</td><td class="num font-mono">12,840</td><td class="num font-mono">12,840</td><td class="num font-mono">12,840</td><td class="font-mono">数字右齐</td></tr>
            </tbody>
          </table>
        </div>
        <div class="media-preview-card" data-open-attachment-preview="chart">
          <div class="media-thumb">📊</div>
          <div style="flex:1; min-width:0;">
            <div style="font-size:13px; font-weight:600;">WCAG 对比度 &amp; 帧耗时图表.html</div>
            <div style="font-size:11px; color:var(--ink-secondary);">离线沙箱互动图卡 · 12.1 KB · 点按Zoom预览</div>
          </div>
          <span class="filter-pill" style="font-size:10.5px; padding:2px 8px;">预览 ›</span>
        </div>
      `,
      code: `// 单一 FontOpticalProfile + SafeLineBox（替代旧 extraSpacing）\nlet metrics = ChatResolvedMetrics.resolve(\n    size: Theme.shared.size,      // 默认 17pt\n    lineHeight: Theme.shared.lineHeight,\n    uiScale: UIScale.factor       // 0.88x ~ 1.08x\n)`,
      plainText: "0.36 发布前体检完成：UIKit 异步 CoreText 瓦片、W3C CLREQ 排版、SafeLineBox 光学校准与 Taint 安全护栏均校验就绪。",
      sources: ["w3.org · CLREQ", "apple.com · HIG", "linear.app · Refresh"]
    },
    {
      id: 2,
      user: "继续确认代码块 2:1 对齐和流式输出交接，另外帮我查好香港 VPS 密钥状态。",
      aiTitle: "代码 2:1 栅格与环境概览",
      metrics: "0.92s · 184 tok",
      aiBody: `<p class="prose-p">已验证 <span class="inline-code">MapleMono + ClioMonoCN</span> 字符宽比严格维持 <strong>1:2</strong>（每个汉字宽等于两个 ASCII 字母），长表与命令输出均自动横滑并保左对齐。</p>`,
      code: `# SSH 远山主机 + 2:1 中文表对齐实测\n环境        | 延迟    | 密钥策略 | 状 态\nProd-CN2   | 24 ms  | Ed25519  | 就 绪 ✓`,
      plainText: "MapleMono + ClioMonoCN 维持 1:2 中西字符宽比；香港 VPS Prod-CN2 Ed25519 公钥状态就绪。",
      sources: null
    },
    {
      id: 3,
      user: "联网搜一下昨天刚发布的新协议细节，顺便试试向上滑动进入沉浸阅读。",
      aiTitle: "工具执行 7 态与沉浸式阅读示例",
      metrics: "1.34s · 212 tok",
      toolAggregate: { status: "failed", label: "联网搜索失败 (0/2)", detail: "Bing / DDG 请求全部失败 · Fake-IP 环境另案追踪" },
      aiBody: `
        <p class="prose-p">本次联网搜索两次尝试均未拿到有效正文，因此上方步骤摘要如实标红为 <strong>「✕ 全部失败 (0/2)」</strong>（不再用绿色 ✓ 误报成功）。</p>
        <p class="prose-p">向上滑动历史消息时，顶栏收起为轻巧会话胶囊，输入框与小克平滑退场；点击顶部恢复胶囊、反向明显下滑、或回到底部即可随时唤回完整控件。</p>
      `,
      code: "",
      plainText: "本次联网搜索两次尝试均未拿到有效正文，上方步骤摘要如实标红为全部失败（不再误显示绿色完成）。",
      sources: null
    }
  ];

  const MODEL_CATALOG = [
    { vendor: "DeepSeek", code: "deepseek/deepseek-reasoner", shortName: "DeepSeek R1", sub: "硅", thinking: "高", role: "默认聊天", note: "深度推理 · 缓存命中 · 128k" },
    { vendor: "Anthropic", code: "anthropic/claude-sonnet-4-20250514", shortName: "Sonnet 4", sub: "直", thinking: "中", role: "复杂写代码", note: "长文编辑与多工具协同 · 200k" },
    { vendor: "OpenAI", code: "openai/gpt-4o-mini-2024-07-18", shortName: "GPT-4o mini", sub: "中", thinking: "自动", role: "记忆整理", note: "夜间批整理与分类 · 极省费" },
    { vendor: "Google", code: "google/imagen-3.0-generate-002", shortName: "Imagen 3", sub: "官", thinking: "关闭", role: "图像生成", note: "插画配图与名帖背景" }
  ];

  function resolveShortModelName(raw) {
    const s = String(raw || "").trim();
    if (!s) return "Model";
    const aliases = TOKENS.shortModelAliases || {};
    if (aliases[s]) return aliases[s];
    const found = MODEL_CATALOG.find((m) => m.code === s || m.shortName === s);
    if (found && found.shortName) return found.shortName;
    let out = s.includes("/") ? s.slice(s.lastIndexOf("/") + 1) : s;
    out = out.replace(/-\d{8}$/, "").replace(/-generate-\d+$/, "");
    if (aliases[out]) return aliases[out];
    return out.length > 16 ? out.slice(0, 15) + "…" : out;
  }

  function resolveToolAggregateStatus(steps, opts = {}) {
    if (opts.waitingApproval) return "waiting_approval";
    const list = Array.isArray(steps) ? steps : [];
    if (!list.length) return "pending";
    if (list.some((s) => s.status === "running")) return "running";
    if (list.every((s) => s.status === "pending")) return "pending";
    if (list.some((s) => s.status === "cancelled") && !list.some((s) => s.status === "failed")) return "cancelled";
    const okCount = list.filter((s) => s.status === "succeeded" || s.status === "ok").length;
    const failCount = list.filter((s) => s.status === "failed" || s.status === "unknown").length;
    if (okCount === list.length) return "succeeded";
    if (okCount === 0 && failCount > 0) return "failed";
    if (okCount > 0 && failCount > 0) return "partial";
    return failCount > 0 ? "failed" : "running";
  }

  const SEARCH_CORPUS = [
    { type: "chat", title: "0.36 发布前体检与长文排版", owner: "小克 · 今天 21:42", snippet: "已完成对 UIKit 聊天管线与 clio-memory.db 的交叉核验… SSH nginx -t", target: "chat" },
    { type: "chat", title: "120Hz 聊天瓦片优化与 anchorOffset", owner: "架构师 · 11-24", snippet: "向上拉取历史保持 0.0pt 视口零跳位，禁用滚动列表实时玻璃…", target: "tools" },
    { type: "memory", title: "常记规则 · 设计系统调研守则", owner: "拾遗 [常记 · 手写]", snippet: "Clio 设计系统 2.0 调研严禁改动任何正式 Swift 生产代码…", target: "memory" },
    { type: "memory", title: "近期记忆 · WebDAV 备份策略", owner: "拾遗 [近期 · 小克写入]", snippet: "偏好保留密钥加密备份并定时同步至私有 WebDAV 网盘。", target: "memory" },
    { type: "file", title: "设计系统2.0结论.md", owner: "书案 · 本地文档 · 18.4 KB", snippet: "W3C CLREQ 行首行尾禁则、H1-H3 阶梯与 8+1 设置分类树摘要…", target: "files" },
    { type: "file", title: "iOS26-HIG-Materials.pdf (第 4 页)", owner: "书案 · PDF FTS5 已索引", snippet: "Don't use Liquid Glass in the content layer — Apple HIG 2025.", target: "files" }
  ];

  function sfIcon(name, size = 15) {
    const s = `width="${size}" height="${size}" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"`;
    const icons = {
      cpu: `<svg ${s}><rect x="5" y="5" width="10" height="10" rx="2"/><rect x="8" y="8" width="4" height="4" rx="0.5"/><path d="M8 2v3M12 2v3M8 15v3M12 15v3M2 8h3M2 12h3M15 8h3M15 12h3"/></svg>`,
      sparkles: `<svg ${s}><path d="M10 2.5l1.6 4.4L16 8.5l-4.4 1.6L10 14.5l-1.6-4.4L4 8.5l4.4-1.6L10 2.5z"/><path d="M15.5 13.5l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7.7-1.8z"/></svg>`,
      palette: `<svg ${s}><circle cx="10" cy="10" r="7.5"/><circle cx="7.2" cy="8" r="1.1" fill="currentColor" stroke="none"/><circle cx="10.2" cy="6.4" r="1.1" fill="currentColor" stroke="none"/><circle cx="13" cy="8.2" r="1.1" fill="currentColor" stroke="none"/><path d="M11 13.5a2 2 0 1 0 3.2-1.6"/></svg>`,
      textformat: `<svg ${s}><path d="M3.5 15L7 5l3.5 10M4.7 11.8h4.6"/><path d="M12.5 11.5c0-1.4 1.1-2.2 2.4-2.2 1.2 0 2.1.7 2.1 1.9V15M17 12.2c-1.8 0-4.5.2-4.5 1.7 0 .8.7 1.3 1.7 1.3 1.2 0 2.1-.6 2.8-1.4"/></svg>`,
      waveform: `<svg ${s}><path d="M3 10v0M6 7v6M9 4v12M12 6v8M15 8v4M18 10v0"/></svg>`,
      bubble: `<svg ${s}><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3h7A2.5 2.5 0 0 1 16 5.5v6a2.5 2.5 0 0 1-2.5 2.5H9l-3.5 3v-3A2.5 2.5 0 0 1 4 11.5v-6z"/><path d="M7.5 7.5h5M7.5 10h3.2"/></svg>`,
      mic: `<svg ${s}><rect x="7.5" y="2.8" width="5" height="8.5" rx="2.5"/><path d="M4.8 9.8a5.2 5.2 0 0 0 10.4 0M10 15v2.5M7.5 17.5h5"/></svg>`,
      brain: `<svg ${s}><path d="M9.8 4.2A3 3 0 0 0 4.5 6.8a2.8 2.8 0 0 0 .5 5.4A3 3 0 0 0 9.8 15.8V4.2z"/><path d="M10.2 4.2A3 3 0 0 1 15.5 6.8a2.8 2.8 0 0 1-.5 5.4 3 3 0 0 1-4.8 3.6V4.2z"/></svg>`,
      paw: `<svg ${s}><circle cx="5.2" cy="7.5" r="1.3"/><circle cx="8.3" cy="5.2" r="1.3"/><circle cx="11.7" cy="5.2" r="1.3"/><circle cx="14.8" cy="7.5" r="1.3"/><path d="M10 9.5c-2.2 0-4 1.6-4 3.4 0 1.3 1.1 2.1 2.2 2.1.7 0 1.2-.3 1.8-.3s1.1.3 1.8.3c1.1 0 2.2-.8 2.2-2.1 0-1.8-1.8-3.4-4-3.4z"/></svg>`,
      sun: `<svg ${s}><circle cx="10" cy="10" r="3.4"/><path d="M10 2.5v2M10 15.5v2M2.5 10h2M15.5 10h2M4.7 4.7l1.4 1.4M13.9 13.9l1.4 1.4M15.3 4.7l-1.4 1.4M6.1 13.9l-1.4 1.4"/></svg>`,
      plug: `<svg ${s}><path d="M7.5 3v3.5M12.5 3v3.5M5.5 6.5h9v3a4.5 4.5 0 0 1-9 0v-3zM10 14v3.5"/></svg>`,
      globe: `<svg ${s}><circle cx="10" cy="10" r="7.2"/><path d="M2.8 10h14.4M10 2.8c2.2 2.1 3.3 4.5 3.3 7.2s-1.1 5.1-3.3 7.2c-2.2-2.1-3.3-4.5-3.3-7.2s1.1-5.1 3.3-7.2z"/></svg>`,
      terminal: `<svg ${s}><rect x="2.8" y="3.8" width="14.4" height="12.4" rx="2.5"/><path d="M6.2 8l2.5 2-2.5 2M10.5 12h3.2"/></svg>`,
      shield: `<svg ${s}><path d="M10 2.8l6 2.4v4.6c0 3.8-2.6 6.4-6 7.5-3.4-1.1-6-3.7-6-7.5V5.2l6-2.4z"/><path d="M7.6 10l1.6 1.7 3.3-3.4"/></svg>`,
      key: `<svg ${s}><circle cx="7" cy="10" r="3.3"/><path d="M10.3 10h6.9M14.5 10v2.5M16.8 10v1.8"/></svg>`,
      faceid: `<svg ${s}><path d="M3.2 6.2V4.5A1.3 1.3 0 0 1 4.5 3.2h1.7M13.8 3.2h1.7a1.3 1.3 0 0 1 1.3 1.3v1.7M16.8 13.8v1.7a1.3 1.3 0 0 1-1.3 1.3h-1.7M6.2 16.8H4.5a1.3 1.3 0 0 1-1.3-1.3v-1.7"/><path d="M7.5 8v1M12.5 8v1M10 8v2.5h-.8M7.5 12.6c.7.9 1.6 1.3 2.5 1.3s1.8-.4 2.5-1.3"/></svg>`,
      bell: `<svg ${s}><path d="M14.8 12.8H5.2c.9-1 1.3-2.3 1.3-4.2a3.5 3.5 0 1 1 7 0c0 1.9.4 3.2 1.3 4.2z"/><path d="M8.5 15.2a1.7 1.7 0 0 0 3 0"/></svg>`,
      cloud: `<svg ${s}><path d="M6.2 14.8h8.1a3 3 0 0 0 .4-5.9 4.2 4.2 0 0 0-8.1-1A3.4 3.4 0 0 0 6.2 14.8z"/></svg>`,
      chart: `<svg ${s}><path d="M4 15.5V10M8.2 15.5V6.5M12.4 15.5V9M16.5 15.5V4.5"/></svg>`,
      info: `<svg ${s}><circle cx="10" cy="10" r="7.2"/><path d="M10 9.2v4.3M10 6.5h.01"/></svg>`,
      chevronRight: `<svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4.2 2.4L7.8 6 4.2 9.6"/></svg>`,
      chevronLeft: `<svg width="13" height="13" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M7.8 2.4L4.2 6l3.6 3.6"/></svg>`
    };
    return icons[name] || icons.info;
  }

  const SETTINGS_CATALOG = [
    // 模型与服务
    { group: "模型与服务", id: "providers", icon: "cpu", tint: "#3B5875", title: "服务商与密钥", line: "API 地址、测速与钥匙串凭据", kw: "api key deepseek claude openai ollama 服务商 密钥", sub: "providers" },
    { group: "模型与服务", id: "models_cfg", icon: "sparkles", tint: "#3B5875", title: "模型角色与推理", line: "", kw: "model role thinking context temperature tokens retry 温度 上下文 思考 模型", sub: "models_cfg" },
    // 外观与阅读
    { group: "外观与阅读", id: "appearance", icon: "palette", tint: "#5E547A", title: "外观与设色", line: "", kw: "theme look color 设色 主题 深色 oled 书卷 日常 称谓 调弦 松绿 黛蓝 光氛", sub: "appearance" },
    { group: "外观与阅读", id: "typography", icon: "textformat", tint: "#4D6682", title: "字体与版式", line: "", kw: "font size line height spacing clreq wenkai 字体 字号 行距 段距 版式 排版 预设 文楷 缩放", sub: "typography" },
    { group: "外观与阅读", id: "motion_haptics", icon: "waveform", tint: "#5E547A", title: "动效与触觉反馈", line: "", kw: "motion haptic vibration 动效 触觉 震动 减弱动态", sub: "motion_haptics" },
    // 对话与交互
    { group: "对话与交互", id: "chat_display", icon: "bubble", tint: "#5A5650", title: "对话与 Agent 策略", line: "", kw: "对话显示 avatar face thinking trace stats agent steps concurrency retry 对话 头像 思考 步数 并发 重试", sub: "chat_display" },
    { group: "对话与交互", id: "voice", icon: "mic", tint: "#5A5650", title: "语音、听写与朗读", line: "", kw: "voice stt tts whisper sensevoice 语音 麦克风 朗读", sub: "voice" },
    // 旅伴与记忆
    { group: "旅伴与记忆", id: "memory_rules", icon: "brain", tint: "#8F524B", title: "记忆策略与整理", line: "", kw: "memory recall night 记忆 拾遗 常记 自动整理", sub: "memory_rules" },
    { group: "旅伴与记忆", id: "goPet", icon: "paw", tint: "#8F524B", title: "伴读宠物", line: "", kw: "pet xiaoke roubao xuanmao songque zhihe 宠物 伴读 小克 肉包", scene: "pet" },
    { group: "旅伴与记忆", id: "morning", icon: "sun", tint: "#8F524B", title: "晨信与伴读手札", line: "", kw: "morning brief journal 晨信 手札 日记", sub: "morning" },
    // 工具与扩展
    { group: "工具与扩展", id: "extensions", icon: "plug", tint: "#8E6A34", title: "MCP 连接器与技能", line: "", kw: "mcp connector skill google github notion 连接器 技能", sub: "extensions" },
    { group: "工具与扩展", id: "search_engine", icon: "globe", tint: "#8E6A34", title: "联网搜索引擎", line: "", kw: "search tavily brave searxng 搜索 联网", sub: "search_engine" },
    { group: "工具与扩展", id: "workspace", icon: "terminal", tint: "#8E6A34", title: "工作空间与远程主机", line: "Alpine 终端、SSH 远山与挂载目录", kw: "ssh vps host server 远山 远程 主机 公钥 终端 挂载", sub: "workspace" },
    // 权限与隐私安全
    { group: "权限与隐私", id: "permissions", icon: "shield", tint: "#336349", title: "权限预设与外网卫士", line: "", kw: "permission grant taint web 权限 审批 外网 安全", sub: "permissions" },
    { group: "权限与隐私", id: "vault", icon: "key", tint: "#336349", title: "密码匣", line: "钥匙串物理加密 · 永不入模型上下文", kw: "vault secret password keychain 密码 密钥 信匣 密匣", sub: "vault" },
    { group: "权限与隐私", id: "privacy", icon: "faceid", tint: "#336349", title: "面容锁与防窥", line: "", kw: "face id privacy blur lock 面容 锁 防窥", sub: "privacy" },
    // 通知与后台
    { group: "通知与后台", id: "notifications", icon: "bell", tint: "#356173", title: "通知、灵动岛与后台", line: "", kw: "notification live activity island keepawake always on 通知 灵动岛 常亮 保活", sub: "notifications" },
    // 数据与养护
    { group: "数据与养护", id: "backup", icon: "cloud", tint: "#455A6E", title: "加密备份与 WebDAV", line: "", kw: "backup webdav restore aes 备份 恢复 云同步", sub: "backup" },
    { group: "数据与养护", id: "usage_diag", icon: "chart", tint: "#455A6E", title: "用量、存储与诊断", line: "", kw: "usage token storage fps hitch diag 用量 费用 存储 掉帧 诊断", sub: "usage_diag" },
    // 关于
    { group: "关于", id: "about", icon: "info", tint: "#5B635D", title: "关于 Clio", line: "", kw: "about version license gpl credits 关于 版本 许可 致谢", sub: "about" }
  ];

  const state = {
    lang: "AC",
    acPalette: "paper_dai",
    mode: "light",
    tone: "literary",
    showChatFaces: false,
    ax: false,
    reduceMotion: false,
    reduceTransparency: false,
    viewState: "normal", // normal | empty | loading | error | outcome
    activeGroup: "core",
    scene: "chat",

    // Decoupled Identity Customization (Assistant & User)
    assistant: {
      name: "小克",
      subtitle: "沉静克制 · 架构设计与伴读助手",
      sealChar: "克",
      followPet: true,
      avatarMode: "followPet", // followPet | pet | monogram | photo
      avatarPetId: "xiaoke",
      avatarMonogram: "克",
      avatarTint: "#35587B",
      avatarPhoto: null
    },
    userProfile: {
      name: "我",
      avatarMode: "monogram", // monogram | pet | photo
      avatarPetId: "roubao",
      avatarMonogram: "我",
      avatarTint: "#276454",
      avatarPhoto: null
    },
    identityEditor: null, // "assistant" | "me" | null
    identityDraft: null,

    // Sub-tabs inside consolidated scenes
    onboardSub: "home", // onboard | home | empty
    onboardStep: 0,
    roamSub: "roam", // roam | den | ssh
    memorySub: "layers", // layers | cards
    careSub: "backup", // backup | usage

    // Typography & Single Optical Calibration Engine
    readingSize: 17,
    lineHeight: 1.65,
    paragraphGap: 13,
    readingWidth: 640,
    uiScale: 1.0,
    activeReadingPreset: "editorial",
    fontCombo: "E",
    fontCompareOpen: false,

    // Single Source of Truth: Model Inference vs Agent Execution vs Progressive Disclosure
    modelAdvOpen: false,
    modelTemp: 0.7,
    modelMaxOut: "8k",
    modelCtxRatio: "75%",
    modelReqRetry: 2,
    agentPolicyOpen: false,
    agentMaxSteps: 16,
    agentReadConcurrency: 4,
    agentToolRetry: 1,
    typoAdvOpen: false,
    diagDevOpen: false,

    // Navigation & overlays
    sidebarOpen: false,
    modelMenuOpen: false,
    moreMenuOpen: false,
    diExpanded: false,
    sendModeMenuOpen: false,
    attachMenuOpen: false,
    alwaysOnOpen: false,
    fullApprovalOpen: false,
    stopPickerKind: null,
    previewFile: null,
    htmlChartTab: "contrast",
    sourcesSheetOpen: false,
    selectionMenuText: null,

    // Interactive chat & Scroll-aware Chrome
    chatTurns: INITIAL_TURNS.map((item) => ({ ...item })),
    activeTurn: 1,
    streaming: false,
    streamingTurnId: null,
    streamingRevealOn: true,
    chatFollowBottom: true,
    chromeMode: "full", // full | immersive
    chatKeyboardOpen: false,
    composerFocused: false,
    selectionActive: false,
    simVoiceOver: false,
    toolDemoState: "partial", // pending | running | succeeded | partial | failed | cancelled | waiting_approval
    voiceRecording: false,
    pendingQuote: null,
    pendingAttachments: ["WCAG-audit.json (12KB)"],
    sendMode: "interject",
    compressedNotice: false,

    // Search
    globalQuery: "",
    globalTab: "all", // all | chat | memory | file

    // InlineAsk & Tools & Approval
    thinkingOpen: false,
    traceOpen: true,
    planOpen: true,
    askScope: "Prod-CN2",
    askChecks: ["wcag", "nginx"],
    askCustomOpen: false,
    askCustomText: "",
    askSubmitted: false,
    activeModel: { ...MODEL_CATALOG[0] },
    inlineApprovalStatus: "pending",
    fullApprovalVerdict: null,

    // Files & Memory & Companions
    fileQuery: "",
    memoryFilter: "all",
    memories: [
      { id: "m1", layer: "pinned", kind: "rule", text: "Clio 设计系统 2.0 调研与原型期严禁修改任何正式生产代码", source: "user", date: "11-25" },
      { id: "m2", layer: "pinned", kind: "preference", text: "普通按钮默认绝不震动；仅高语义切换与审批仪式给清晰触觉", source: "user", date: "11-24" },
      { id: "m3", layer: "surface", kind: "project", text: "0.36 已落地 UIKit CoreText 异步瓦片、四层记忆与 PDF FTS5", source: "bot", bot: "小克", date: "今天 21:10" },
      { id: "m4", layer: "deep", kind: "experience", text: "微信读书与 W3C CLREQ：汉字与西文保留 0.12em 视图微距不污染复制", source: "bot", bot: "架构师", date: "11-18" },
      { id: "m5", layer: "archived", kind: "note", text: "旧版剪影宠物形象（卷卷/墨团等）已删除停用，统一为宠物包", source: "user", date: "11-15" }
    ],
    cardFlipped: false,

    // Terminal & Roam & Extensions
    roamUrl: "https://developer.apple.com/design/human-interface-guidelines/materials",
    roamHandoffActive: true,
    denStatus: "awake",
    denLogs: [
      { kind: "note", text: "Alpine Linux · 就绪（Maple Mono + Clio Mono CN 2:1 栅格）" },
      { kind: "cmd", text: "clio-lint --design-check" },
      { kind: "out", text: "词典键对等校验…… 1075 / 1075 完全一致 ✓\nWCAG 2.1 AA 对比度…… 117 组 ≥ 4.5:1 ✓" }
    ],
    sshKeyCopied: false,
    skills: [
      { id: "sk1", name: "swift-uikit-audit", desc: "核查 120Hz 掉帧与 MainActor 隔离", on: true },
      { id: "sk2", name: "clreq-typesetting", desc: "按 W3C CLREQ 校对长文标点与禁则", on: true },
      { id: "sk3", name: "webdav-verify", desc: "校验 AES-GCM 备份解密摘要", on: false }
    ],

    // Settings & Preferences (Real interactive 8+1 sub-page states)
    settingsQuery: "",
    settingsSub: null,
    readingFace: "editorial", // editorial | sans | serif | wenkai
    headingWeight: "semibold", // medium | semibold | bold
    clreqSqueeze: true,
    ambientGlowOn: true,
    showHintBadge: true,
    hapticIntensity: "standard", // off | gentle | standard | crisp
    chatShowThinking: true,
    chatShowStats: true,
    chatTraceDefaultOpen: false,
    chatConfirmStop: true,
    voiceMode: "cloud", // system | cloud
    voiceModel: "Groq Whisper v3",
    voiceMuteHaptics: true,
    memAutoRecall: true,
    memAutoWrite: true,
    memNightOrganize: true,
    morningBriefOn: true,
    morningTime: "07:30",
    nightJournalOn: true,
    searchEngine: "builtin", // builtin | brave | tavily | searxng
    grantPreset: "balanced", // strict | balanced | auto | readonly
    taintGuardOn: true,
    vaultUnlocked: false,
    faceIdLockOn: true,
    bgPrivacyBlur: true,
    notifyDone: true,
    liveIslandOn: true,
    bgKeepAwake: true,
    backupPassphraseReady: true,
    backupEncryptKeys: true,
    lastBackupAt: "今天 21:30 · iCloud & WebDAV",

    // Pet (5+1 built-in/custom pets & 6 restrained controls)
    petActiveId: "xiaoke",
    petNicknames: {
      xiaoke: "小克",
      roubao: "肉包",
      xuanmao: "玄猫",
      songque: "松雀",
      zhihe: "纸鹤",
      custom: "自定伙伴"
    },
    petSizeFactor: 1.0,
    petActivity: "quiet", // lively | quiet | minimal
    petSnoozeUntil: null,
    petCustomPhoto: null,
    petCustomBreathe: true,
    petBotBindings: { default: "xiaoke", architect: "songque" },
    petActiveBotKey: "default",
    petVisible: true,
    petState: "idle",
    petX: 0.24,
    petOneOffUntil: 0,
    petAnimSince: 0,
    petTaps: [],
    petBubble: null,
    petFlipped: false,

    // Motion & Streaming Lab
    motionTierDemo: "standard",
    keyboardSyncLocked: true,
    keyboardDemoRaised: true,
    naiveStreamComparing: false,
    streamLabTrace: "jitter", // slow | fast | jitter | stall | burst | error
    streamLabFont: "editorial",
    interruptPos: 0, // 0..100
    interruptTarget: 0
  };

  // ==================== Haptics Waveform Monitor (Enforces Section 15 Restraint) ====================
  const hapticWaves = [];
  const hapticCanvas = typeof document !== "undefined" ? document.getElementById("hapticCanvas") : null;
  const hapticCtx = (hapticCanvas && typeof hapticCanvas.getContext === "function") ? hapticCanvas.getContext("2d") : null;
  const hapticLogEl = typeof document !== "undefined" ? document.getElementById("hapticLog") : null;

  function emitHaptic(kind, label) {
    const langCfg = TOKENS.languages[state.lang] || TOKENS.languages.A;
    const h = langCfg.haptics || {};
    const bias = Number.isFinite(h.sharpnessBias) ? h.sharpnessBias : 0.45;
    const now = performance.now();

    if (state.voiceRecording && kind !== "alert") {
      appendHapticLog(`[录音静音保护] 跳过震动 (${label || kind}) · 防麦克风干扰`, "#94A3B8");
      return;
    }

    if (kind === "silent") {
      appendHapticLog(`[静默 · 普通钮无震动] ${label}`, "#64748B");
      return;
    }

    if (state.hapticIntensity === "off") {
      appendHapticLog(`[已关闭触觉] 跳过 (${label || kind})`, "#64748B");
      return;
    }
    const ampScale = state.hapticIntensity === "gentle" ? 0.65 : (state.hapticIntensity === "crisp" ? 1.15 : 1.0);

    let spikes = [];
    let desc = "";

    if (kind === "selection") {
      spikes = [{ t: 0, amp: 0.36, sharp: bias, dur: 18 }];
      desc = `Selection · i=0.36 s=${bias.toFixed(2)}`;
    } else if (kind === "light" || kind === "tap") {
      const iVal = Number.isFinite(h.tapIntensity) ? h.tapIntensity : 0.45;
      spikes = [{ t: 0, amp: Math.max(0.45, iVal), sharp: bias, dur: 24 }];
      desc = `Light · i=${Math.max(0.45, iVal).toFixed(2)} s=${bias.toFixed(2)}`;
    } else if (kind === "tick") {
      spikes = [{ t: 0, amp: 0.42, sharp: Math.min(0.95, bias + 0.15), dur: 18 }];
      desc = `tick · 刻度 i=0.42`;
    } else if (kind === "detent") {
      const dVal = Number.isFinite(h.detentIntensity) ? h.detentIntensity : 0.72;
      spikes = [{ t: 0, amp: dVal, sharp: Math.min(0.95, bias + 0.2), dur: 35 }];
      desc = `Snap Detent · 基准吸合 i=${dVal.toFixed(2)}`;
    } else if (kind === "pet" || kind === "grab") {
      spikes = [
        { t: 0, amp: 0.42, sharp: 0.30, dur: 22 },
        { t: 75, amp: 0.55, sharp: 0.48, dur: 26 }
      ];
      desc = `PetWake / Grab · 双连轻震 95ms`;
    } else if (kind === "confirm") {
      if (state.lang === "A" || state.lang === "AC") {
        spikes = [
          { t: 0, amp: 0.95, sharp: 0.25, dur: 34 },
          { t: 34, amp: 0.78, sharp: 0.12, dur: 105 },
          { t: 122, amp: 0.74, sharp: 0.65, dur: 28 }
        ];
        desc = "AHAP 朱印 thud() · 三段 140ms";
      } else if (state.lang === "B") {
        spikes = [
          { t: 0, amp: 0.95, sharp: 0.90, dur: 22 },
          { t: 55, amp: 0.88, sharp: 0.85, dur: 20 }
        ];
        desc = "棘轮咬合锁 · 双锐脉冲 s=0.90";
      } else {
        spikes = [
          { t: 0, amp: 0.58, sharp: 0.20, dur: 135 },
          { t: 130, amp: 0.66, sharp: 0.35, dur: 45 }
        ];
        desc = "温和潮汐波 · 175ms 柔和收尾";
      }
    } else if (kind === "alert") {
      spikes = [
        { t: 0, amp: 0.88, sharp: 0.82, dur: 28 },
        { t: 90, amp: 0.70, sharp: 0.65, dur: 28 }
      ];
      desc = "Error / Warning · 双顿告警 118ms";
    }

    spikes.forEach((sp) => {
      hapticWaves.push({ born: now + sp.t, amp: Math.min(1, sp.amp * ampScale), sharp: sp.sharp, dur: sp.dur, kind });
    });
    appendHapticLog(`${label ? label + " → " : ""}${desc}`, "#A7B0C2");
  }

  function appendHapticLog(msg, color) {
    if (!hapticLogEl) return;
    const line = document.createElement("div");
    line.style.color = color || "#A7B0C2";
    line.textContent = `[${new Date().toLocaleTimeString("zh-CN", { hour12: false })}] ${msg}`;
    if (hapticLogEl.firstChild && hapticLogEl.textContent.startsWith("等待")) hapticLogEl.innerHTML = "";
    hapticLogEl.prepend(line);
    while (hapticLogEl.children.length > 14) hapticLogEl.removeChild(hapticLogEl.lastChild);
  }

  function renderHapticCanvas() {
    if (!hapticCanvas || !hapticCtx) return;
    const w = hapticCanvas.width;
    const h = hapticCanvas.height;
    hapticCtx.clearRect(0, 0, w, h);

    hapticCtx.strokeStyle = "#2A303D";
    hapticCtx.lineWidth = 1;
    hapticCtx.beginPath();
    hapticCtx.moveTo(0, h / 2);
    hapticCtx.lineTo(w, h / 2);
    hapticCtx.stroke();

    const now = performance.now();
    const windowMs = 1500;
    for (let i = hapticWaves.length - 1; i >= 0; i--) {
      const sp = hapticWaves[i];
      const age = now - sp.born;
      if (age > windowMs) {
        hapticWaves.splice(i, 1);
        continue;
      }
      if (age < 0) continue;
      const x = w - (age / windowMs) * w;
      const barW = Math.max(4, (sp.dur / windowMs) * w);
      const peak = sp.amp * (h * 0.42);
      const color = sp.kind === "alert" ? "#F87171" : (sp.kind === "confirm" ? "#34D399" : (sp.kind === "detent" ? "#FBBF24" : "#60A5FA"));

      hapticCtx.fillStyle = color;
      hapticCtx.globalAlpha = Math.max(0.15, 1 - age / windowMs);
      hapticCtx.beginPath();
      hapticCtx.roundRect(x - barW / 2, h / 2 - peak, barW, peak * 2, 3);
      hapticCtx.fill();
      hapticCtx.globalAlpha = 1;
    }
    requestAnimationFrame(renderHapticCanvas);
  }

  // ==================== Helpers ====================
  function t(key) {
    const dict = TOKENS.tones[state.tone] || TOKENS.tones.daily;
    return dict[key] || TOKENS.tones.daily[key] || key;
  }

  function hintBadge(dailyText) {
    return (state.tone === "literary" && state.showHintBadge) ? `<span class="hint-tag">(${escHtml(dailyText)})</span>` : "";
  }

  function getColors() {
    const langCfg = TOKENS.languages[state.lang] || TOKENS.languages.AC || TOKENS.languages.A;
    if (state.lang === "AC" && langCfg.palettes && langCfg.palettes[state.acPalette]) {
      return langCfg.palettes[state.acPalette][state.mode];
    }
    return langCfg.colors[state.mode];
  }

  function activePetDisplayName(id) {
    const pid = id || state.petActiveId;
    return (state.petNicknames && state.petNicknames[pid]) || (pid === "custom" ? state.petNicknames.custom : "小克");
  }

  function resolveAssistantPetId() {
    if (state.assistant.followPet) return state.petActiveId;
    return state.assistant.avatarPetId || "xiaoke";
  }

  function isPetVisibleNow() {
    if (!state.petVisible) return false;
    if (state.petSnoozeUntil && state.petSnoozeUntil > Date.now()) return false;
    return true;
  }

  function renderAvatarMarkup(kind, sizePx = 32, moodOverride = "") {
    if (kind === "assistant") {
      const a = state.assistant;
      if (a.avatarMode === "photo" && a.avatarPhoto) {
        return `<img class="chat-avatar-img" src="${a.avatarPhoto}" alt="${escHtml(a.name)}" />`;
      }
      if (a.avatarMode === "monogram") {
        const ch = (a.avatarMonogram || a.name || "克").trim().slice(0, 1) || "克";
        const fz = Math.round(sizePx * 0.46);
        return `<span class="chat-avatar-mono" style="background:${a.avatarTint}; font-size:${fz}px;">${escHtml(ch)}</span>`;
      }
      const petId = resolveAssistantPetId();
      if (petId === "custom" && state.petCustomPhoto) {
        return `<img class="chat-avatar-img" src="${state.petCustomPhoto}" alt="${escHtml(a.name)}" />`;
      }
      const cSz = Math.max(18, Math.round(sizePx * 0.82));
      return `<canvas data-pet-canvas="1" data-pet-id="${escHtml(petId)}" data-pet-still="${moodOverride ? "0" : "1"}" ${moodOverride ? `data-pet-mood="${escHtml(moodOverride)}"` : ""} width="48" height="48" style="width:${cSz}px;height:${cSz}px;image-rendering:pixelated;"></canvas>`;
    }
    const me = state.userProfile;
    if (me.avatarMode === "photo" && me.avatarPhoto) {
      return `<img class="chat-avatar-img" src="${me.avatarPhoto}" alt="${escHtml(me.name)}" />`;
    }
    if (me.avatarMode === "pet") {
      const petId = me.avatarPetId || "roubao";
      if (petId === "custom" && state.petCustomPhoto) {
        return `<img class="chat-avatar-img" src="${state.petCustomPhoto}" alt="${escHtml(me.name)}" />`;
      }
      const cSz = Math.max(18, Math.round(sizePx * 0.82));
      return `<canvas data-pet-canvas="1" data-pet-id="${escHtml(petId)}" data-pet-still="1" width="48" height="48" style="width:${cSz}px;height:${cSz}px;image-rendering:pixelated;"></canvas>`;
    }
    const ch = (me.avatarMonogram || me.name || "我").trim().slice(0, 1) || "我";
    const fz = Math.round(sizePx * 0.46);
    return `<span class="chat-avatar-mono" style="background:${me.avatarTint}; font-size:${fz}px;">${escHtml(ch)}</span>`;
  }

  function escHtml(str) {
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  let toastTimer = null;
  function showToast(msg) {
    const host = document.getElementById("toastHost");
    if (!host) return;
    host.innerHTML = `<div class="toast-pill">${escHtml(msg)}</div>`;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { host.innerHTML = ""; }, 1800);
  }

  let fontEnvReport = {
    bundled: [
      { id: "ClioKaiWeb", label: "ClioKai (霞鹜文楷)", status: "checking" },
      { id: "MapleMonoWeb", label: "MapleMono (代码)", status: "checking" },
      { id: "ClioMonoCNWeb", label: "ClioMonoCN (2:1 中文)", status: "checking" },
      { id: "ClioSealWeb", label: "ClioSeal (朱印)", status: "checking" }
    ],
    system: [
      { id: "New York", label: "New York (英数衬线)", status: "unknown" },
      { id: "PingFang SC", label: "PingFang SC (苹果黑体)", status: "unknown" },
      { id: "STSongti-SC", label: "STSongti-SC (随选宋体)", status: "unknown" }
    ]
  };

  function probeCanvasFontAvailable(familyName, fallbackGeneric) {
    if (typeof document === "undefined") return false;
    try {
      const c = document.createElement("canvas");
      const ctx = c.getContext("2d");
      if (!ctx) return false;
      const sample = "纸墨之间 Clio 0123456789 永国门";
      ctx.font = `17px ${fallbackGeneric}`;
      const baseW = ctx.measureText(sample).width;
      ctx.font = `17px "${familyName}", ${fallbackGeneric}`;
      const testW = ctx.measureText(sample).width;
      return Math.abs(testW - baseW) > 0.4;
    } catch (_) {
      return false;
    }
  }

  function detectFontEnvironment() {
    if (typeof document === "undefined") return fontEnvReport;
    const loadedFamilies = new Set();
    if (document.fonts && typeof document.fonts.forEach === "function") {
      document.fonts.forEach((f) => {
        if (f.status === "loaded") {
          const clean = String(f.family || "").replace(/["']/g, "");
          loadedFamilies.add(clean);
        }
      });
    }
    const bundled = [
      { id: "ClioKaiWeb", label: "ClioKai (App/Fonts)", status: loadedFamilies.has("ClioKaiWeb") ? "loaded" : "pending" },
      { id: "MapleMonoWeb", label: "MapleMono (App/Fonts)", status: loadedFamilies.has("MapleMonoWeb") ? "loaded" : "pending" },
      { id: "ClioMonoCNWeb", label: "ClioMonoCN (2:1)", status: loadedFamilies.has("ClioMonoCNWeb") ? "loaded" : "pending" },
      { id: "ClioSealWeb", label: "ClioSeal (朱印)", status: loadedFamilies.has("ClioSealWeb") ? "loaded" : "pending" }
    ];
    const system = [
      { id: "New York", label: "New York", status: probeCanvasFontAvailable("New York", "serif") ? "loaded" : "fallback" },
      { id: "PingFang SC", label: "PingFang SC", status: probeCanvasFontAvailable("PingFang SC", "sans-serif") ? "loaded" : "fallback" },
      { id: "STSongti-SC", label: "STSongti-SC", status: probeCanvasFontAvailable("STSongti-SC", "serif") ? "loaded" : "fallback" }
    ];
    fontEnvReport = { bundled, system };
    return fontEnvReport;
  }

  function renderFontStatusStripHtml() {
    const rep = detectFontEnvironment();
    const bPills = rep.bundled.map((b) => `<span class="font-status-pill ${b.status === "loaded" ? "loaded" : ""}">${b.status === "loaded" ? "✓" : "◌"} ${escHtml(b.label)}</span>`).join("");
    const anyMissingSys = rep.system.some((s) => s.status !== "loaded");
    const sPill = anyMissingSys
      ? `<span class="font-status-pill fallback">⚠ New York / 苹方 / 宋体 非 Apple 平台已回退 · 待 iOS 真机核验</span>`
      : `<span class="font-status-pill loaded">✓ Apple 系统字体可用</span>`;
    return `<div class="font-status-strip" id="fontStatusStrip">${bPills}${sPill}</div>`;
  }

  function computeSafeLineBox(sizePt, lineHeightMult, faceKey, metrics) {
    const profile = (TOKENS.fontOpticalProfiles && TOKENS.fontOpticalProfiles[faceKey]) || TOKENS.fontOpticalProfiles.editorial;
    const scale = Number(profile.opticalScale || 1.0);
    const effectiveSizePt = Math.round(sizePt * scale * 2) / 2;
    const asc = Number(metrics?.ascent ?? effectiveSizePt * 0.88);
    const desc = Number(metrics?.descent ?? effectiveSizePt * 0.24);
    const naturalBoxPt = Math.ceil(asc + desc);
    const targetPt = sizePt * lineHeightMult;
    const minimumLineHeight = Math.max(targetPt, naturalBoxPt);
    return {
      effectiveSizePt,
      naturalBoxPt,
      targetPt,
      minimumLineHeight,
      maximumLineHeight: 0,
      lineSpacing: 0
    };
  }

  function resolveReadingTypography(faceKey, sizePt, lineHeightMult, axEnabled) {
    const profile = (TOKENS.fontOpticalProfiles && TOKENS.fontOpticalProfiles[faceKey]) || TOKENS.fontOpticalProfiles.editorial;
    const baseSizePx = sizePt * (axEnabled ? 1.15 : 1);
    const safeBox = computeSafeLineBox(baseSizePx, lineHeightMult, faceKey);
    const userBubbleLh = Math.min(1.68, Math.max(1.32, lineHeightMult - 0.12));
    return {
      faceKey,
      fontCss: profile.fontCss,
      opticalScale: profile.opticalScale || 1,
      trackingEm: profile.trackingEm || "0em",
      boldWeight: profile.boldWeight || 600,
      baseSizePx,
      effectiveSizePx: safeBox.effectiveSizePt,
      lineHeight: lineHeightMult,
      userBubbleLineHeight: Number(userBubbleLh.toFixed(2)),
      safeBox
    };
  }

  function switchScene(nextScene) {
    state.scene = nextScene;
    state.activeGroup = findGroupForScene(nextScene);
    state.sidebarOpen = false;
    state.modelMenuOpen = false;
    state.moreMenuOpen = false;
    state.diExpanded = false;
    state.sendModeMenuOpen = false;
    state.attachMenuOpen = false;
    state.stopPickerKind = null;
    state.previewFile = null;
    state.identityEditor = null;
    state.identityDraft = null;
    if (nextScene !== "chat" && nextScene !== "pet") {
      state.chromeMode = "full";
      state.chatKeyboardOpen = false;
      state.composerFocused = false;
    }
    if (nextScene !== "settings") {
      state.settingsSub = null;
    }
    if (nextScene === "approval" && state.inlineApprovalStatus === "pending") {
      setPetMood("notification");
    } else if (nextScene !== "pet" && !state.streaming) {
      setPetMood("idle");
    }
    renderAll({ resetScroll: true });
  }

  function setPetMood(mood, oneOffDurationMs = 0) {
    state.petState = mood;
    state.petAnimSince = performance.now();
    state.petOneOffUntil = oneOffDurationMs > 0 ? performance.now() + oneOffDurationMs : 0;
  }

  function applyThemeVariables() {
    const screen = document.getElementById("iphoneScreen");
    if (!screen) return;
    const langCfg = TOKENS.languages[state.lang];
    const c = getColors();

    screen.dataset.lang = state.lang;
    screen.dataset.mode = state.mode;
    screen.dataset.tone = state.tone;
    screen.dataset.ax = String(state.ax);
    screen.dataset.reduceMotion = String(state.reduceMotion);
    screen.dataset.reduceTransparency = String(state.reduceTransparency);
    screen.dataset.chrome = (state.scene === "chat" || state.scene === "pet") ? state.chromeMode : "full";

    const style = screen.style;
    screen.dataset.palette = state.acPalette;
    screen.dataset.readingFace = state.readingFace;
    screen.dataset.headingWeight = state.headingWeight;
    style.setProperty("--badge-ratio", String(langCfg.radii.badgeRatio || 0.26));
    style.setProperty("--bg", c.bg);
    style.setProperty("--surface", c.surface);
    style.setProperty("--surface-elevated", c.surfaceElevated);
    style.setProperty("--surface-subtle", c.surfaceSubtle);
    style.setProperty("--ink", c.ink);
    style.setProperty("--ink-secondary", c.inkSecondary);
    style.setProperty("--ink-tertiary", c.inkTertiary);
    style.setProperty("--rule", c.rule);
    style.setProperty("--accent", c.accent);
    style.setProperty("--on-accent", c.onAccent);
    style.setProperty("--accent-wash", c.accentWash);
    style.setProperty("--seal", c.seal);
    style.setProperty("--seal-fill", c.sealFill);
    style.setProperty("--on-seal", c.onSeal);
    style.setProperty("--ok", c.ok);
    style.setProperty("--warn", c.warn);
    style.setProperty("--danger", c.danger);
    style.setProperty("--my-bubble", c.myBubble);
    style.setProperty("--code-bg", c.codeBg);
    style.setProperty("--stop-wash", c.stopWash);

    style.setProperty("--r-outer", langCfg.radii.outerCard + "px");
    style.setProperty("--r-inner", langCfg.radii.innerBlock + "px");
    style.setProperty("--r-sheet", langCfg.radii.sheet + "px");
    style.setProperty("--rail-width", langCfg.toolRailWidth + "px");
    style.setProperty("--ui-scale", String(state.uiScale));
    style.setProperty("--ax-mult", state.ax ? "1.18" : "1");
    const resolvedFace = (state.lang === "B" && state.readingFace === "editorial") ? "sans" : (state.readingFace || "editorial");
    const typo = resolveReadingTypography(resolvedFace, state.readingSize, state.lineHeight, state.ax);
    style.setProperty("--reading-font-family", typo.fontCss);
    style.setProperty("--reading-size", typo.baseSizePx.toFixed(1) + "px");
    style.setProperty("--font-optical-scale", String(typo.opticalScale));
    style.setProperty("--effective-reading-size", typo.effectiveSizePx.toFixed(1) + "px");
    style.setProperty("--font-tracking", typo.trackingEm);
    style.setProperty("--bold-weight", String(typo.boldWeight));
    style.setProperty("--reading-lh", String(typo.lineHeight));
    style.setProperty("--user-bubble-lh", String(typo.userBubbleLineHeight));
    style.setProperty("--para-gap", state.paragraphGap + "px");
    style.setProperty("--reading-width", state.readingWidth + "px");
    style.setProperty("--motion-dur", langCfg.motionTiers.standard.ms + "ms");
    style.setProperty("--motion-ease", langCfg.motionTiers.standard.cubic);

    const glow = document.getElementById("ambientGlow");
    let glowColor = c.accent;
    let glowAlpha = 14;
    if (state.viewState === "error") { glowColor = c.danger; glowAlpha = 22; }
    else if (state.scene === "approval" && state.inlineApprovalStatus === "pending") { glowColor = c.seal; glowAlpha = 20; }
    else if (state.streaming || state.petState === "thinking" || state.petState === "working") { glowColor = c.warn; glowAlpha = 18; }
    if (glow) {
      glow.style.display = state.ambientGlowOn ? "" : "none";
      glow.style.background = `radial-gradient(ellipse at 50% 0%, color-mix(in srgb, ${glowColor} ${glowAlpha}%, transparent), transparent 68%)`;
      glow.style.setProperty("--ambient-line", glowColor);
    }

    const netEl = document.getElementById("networkStatusChip");
    if (netEl) netEl.textContent = state.viewState === "error" ? "无服务 · SOS" : "5G · 94%";

    const palName = state.lang === "AC" ? ` · ${TOKENS.languages.AC.palettes[state.acPalette].name}` : "";
    const langBadgeEl = document.getElementById("langBadge");
    if (langBadgeEl) langBadgeEl.textContent = `${state.lang} · ${langCfg.name}${palName}`;
    const langDescEl = document.getElementById("langDesc");
    if (langDescEl) langDescEl.textContent = `${langCfg.subtitle} — ${langCfg.desc}`;
    const hapEl = document.getElementById("hapticProfileTag");
    if (hapEl) hapEl.textContent = `${langCfg.haptics.profile} · ${langCfg.haptics.confirmDesc}`;
  }

  // ==================== Multi-Pet & Procedural Pixel-Art Engine ====================
  const PET_PACKS = window.CLIO_PET_PACKS || (typeof PET !== "undefined" ? { xiaoke: PET } : {});
  const spriteImgCache = {};
  Object.entries(PET_PACKS).forEach(([packId, packData]) => {
    if (!packData) return;
    spriteImgCache[packId] = {};
    Object.entries(packData.sheets || {}).forEach(([sheetName, dataUri]) => {
      const img = new Image();
      img.onload = () => drawAllPetCanvases(performance.now());
      img.src = dataUri;
      spriteImgCache[packId][sheetName] = img;
    });
  });

  function drawAllPetCanvases(now) {
    document.querySelectorAll("canvas[data-pet-canvas]").forEach((canvas) => {
      const petId = canvas.dataset.petId || state.petActiveId || "xiaoke";
      const still = canvas.dataset.petStill === "1";
      const flipped = canvas.dataset.petFlip === "1" || (canvas.id === "petMainCanvas" && state.petFlipped);
      const forcedMood = canvas.dataset.petMood || "";
      drawPetCanvas(canvas, now, { petId, still, flipped, forcedMood });
    });
  }

  function resolvePetAnimName() {
    const now = performance.now();
    if (state.petOneOffUntil > now) return state.petState;
    if (state.petOneOffUntil > 0 && state.petOneOffUntil <= now) {
      state.petOneOffUntil = 0;
      state.petState = state.streaming
        ? "working"
        : (state.scene === "approval" && state.inlineApprovalStatus === "pending" ? "notification" : "idle");
      state.petAnimSince = now;
    }
    return state.petState || "idle";
  }

  function startPetLoop() {
    let lastDraw = 0;
    function tick(now) {
      if (now - lastDraw > 75) {
        lastDraw = now;
        drawAllPetCanvases(now);
      }
      requestAnimationFrame(tick);
    }
    requestAnimationFrame(tick);
  }

  function drawProceduralPixelPet(ctx, petId, mood, elapsed, canvasW, canvasH) {
    const c = getColors();
    const u = Math.max(1, Math.floor(Math.min(canvasW, canvasH) / 16));
    const ox = Math.floor((canvasW - u * 16) / 2);
    const oy = Math.floor(canvasH - u * 16);
    const beat = state.reduceMotion ? 0 : Math.floor((elapsed / 320) % 4);
    const blink = !state.reduceMotion && (elapsed % 2800 > 2620 || mood === "sleeping");
    const bobY = (mood === "attention" || mood === "tickle") && beat % 2 === 1 ? -1 : 0;
    const p = (x, y, w, h, color) => {
      ctx.fillStyle = color;
      ctx.fillRect(ox + x * u, oy + (y + bobY) * u, w * u, h * u);
    };

    if (petId === "xuanmao") {
      const coat = "#242228";
      const earInner = "#C27D78";
      const eye = mood === "error" ? "#E87568" : (mood === "notification" ? "#E4A952" : "#89C997");
      p(4, 3, 2, 2, coat); p(10, 3, 2, 2, coat); // ears
      p(5, 4, 1, 1, earInner); p(10, 4, 1, 1, earInner);
      p(3, 5, 10, 6, coat); // head
      p(4, 11, 8, 4, coat); // body
      p(5, 12, 6, 3, "#36333B"); // belly sheen
      const tailShift = (beat === 1 || beat === 2) ? 1 : 0;
      p(12, 11 - tailShift, 2, 1, coat); p(13, 9 - tailShift, 1, 3, coat); // swaying tail
      if (blink) { p(5, 8, 2, 1, "#B8A99A"); p(9, 8, 2, 1, "#B8A99A"); }
      else { p(5, 7, 2, 2, eye); p(9, 7, 2, 2, eye); p(5, 7, 1, 1, "#FFFDF8"); p(9, 7, 1, 1, "#FFFDF8"); }
      p(7, 9, 2, 1, "#E5989B"); // tiny nose
    } else if (petId === "songque") {
      const moss = "#2E705D";
      const wing = "#215244";
      const cream = "#F4EFE2";
      const beak = "#D8893A";
      p(5, 4, 6, 5, moss); // head
      p(4, 8, 8, 6, moss); // plump body
      p(5, 9, 6, 4, cream); // cream breast
      const flap = (mood === "working" || mood === "attention" || mood === "tickle") && beat % 2 === 1 ? -1 : 0;
      p(3, 9 + flap, 2, 3, wing); p(11, 9 + flap, 2, 3, wing); // wings
      p(7, 7, 2, 1, beak); // beak
      if (blink) { p(5, 6, 1, 1, "#111"); p(10, 6, 1, 1, "#111"); }
      else { p(5, 6, 1, 1, "#111"); p(10, 6, 1, 1, "#111"); p(4, 7, 1, 1, "#E89B8B"); p(11, 7, 1, 1, "#E89B8B"); }
      p(6, 14, 1, 1, beak); p(9, 14, 1, 1, beak); // feet
    } else {
      // zhihe (Folded Paper Crane)
      const paper = c.bg === "#000000" || c.bg === "#191815" || c.bg === "#151816" ? "#EFEAE0" : "#FFFDF8";
      const shade = "#D9D0C1";
      const crown = "#B5382A";
      const wingY = beat % 2 === 1 ? -1 : 0;
      p(2, 5 + wingY, 5, 3, paper); p(9, 5 + wingY, 5, 3, paper); // wings
      p(3, 7 + wingY, 3, 1, shade); p(10, 7 + wingY, 3, 1, shade);
      p(5, 8, 6, 4, paper); p(6, 10, 4, 3, shade); // folded body
      p(7, 4, 2, 4, paper); // neck
      p(7, 3, 3, 2, paper); p(9, 4, 2, 1, "#945608"); // head & beak
      p(7, 3, 1, 1, crown); // cinnabar crest
      p(11, 6, 2, 4, paper); // tail tip
    }
    if (mood === "thinking" || mood === "notification") {
      p(13, 2, 2, 2, mood === "notification" ? c.seal : c.accent);
    } else if (mood === "error") {
      p(13, 2, 2, 2, c.danger);
    }
  }

  function drawPetCanvas(canvas, now, opts = {}) {
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    const petId = opts.petId || state.petActiveId || "xiaoke";
    const animName = opts.still ? "idle" : (opts.forcedMood || resolvePetAnimName());
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.imageSmoothingEnabled = false;

    const pack = PET_PACKS[petId];
    if (!pack) {
      ctx.save();
      if (opts.flipped) { ctx.translate(canvas.width, 0); ctx.scale(-1, 1); }
      const elapsed = (opts.still || state.reduceMotion) ? 0 : Math.max(0, now - (state.petAnimSince || 0));
      drawProceduralPixelPet(ctx, petId, animName, elapsed, canvas.width, canvas.height);
      ctx.restore();
      return;
    }

    const anim = pack.animations[animName] || pack.animations.idle;
    if (!anim) return;
    const img = spriteImgCache[petId]?.[anim.sheet];
    if (!img || !img.complete) return;

    const totalMs = anim.frames.reduce((s, f) => s + f.ms, 0) || 1000;
    const relNow = Math.max(0, now - (state.petAnimSince || 0));
    const elapsed = (opts.still || state.reduceMotion) ? 0 : (anim.loop === false ? Math.min(relNow, totalMs - 1) : (relNow % totalMs));
    let acc = 0;
    let frameObj = anim.frames[0];
    for (const f of anim.frames) {
      acc += f.ms;
      if (elapsed <= acc) { frameObj = f; break; }
    }

    const col = frameObj.i % (anim.cols || 3);
    const sx = col * anim.frameW;
    ctx.save();
    if (opts.flipped) {
      ctx.translate(canvas.width, 0);
      ctx.scale(-1, 1);
    }
    const dx = anim.box ? anim.box.x : Math.round((canvas.width - anim.frameW) / 2);
    const dy = anim.box ? anim.box.y : (canvas.height - anim.frameH);
    ctx.drawImage(img, sx, 0, anim.frameW, anim.frameH, dx, dy, anim.frameW, anim.frameH);
    ctx.restore();
  }

  // ==================== Native Source Inspector ====================
  const INSPECTOR_MAP = {
    chat: { files: ["ChatListViewController.swift", "ChatProseRenderer.swift", "ChatTextTileRenderer.swift", "ChatPage+Dock.swift"], apis: ["UICollectionViewDiffableDataSource", "CTFramesetter", ".glassEffect(.regular)", "AVSpeechSynthesizer"], notes: "UIKit 异步 CoreText 瓦片承接全部 18 种 Markdown 元素与 CLREQ 视觉 micro-kerning；滚动正文绝对禁用实时玻璃。" },
    onboarding_home: { files: ["SetupView.swift", "DeskHomeView.swift", "Desk.swift", "ToneViews.swift"], apis: ["TabView(.page)", "ScrollView + LazyVStack", "Ink.mark"], notes: "引导页现场对照日常/书卷并开启旁注开关；Home 页收敛掉与侧栏重复的右上按钮，保留晨信与待签单高优提醒。" },
    pet: { files: ["PetStage.swift", "PetPerch.swift", "PetLibrary.swift", "TurnActivity.swift"], apis: ["KeyframeAnimator", "PetPerch.Surface", "ActivityKit"], notes: "严守输入栏上沿水平拖动限位（≤28pt），自动避让跳转钮与回复行；戳醒触发 CoreHaptics 轻连震。" },
    tools: { files: ["ThinkingBox.swift", "ChatTrace.swift", "PlanCard.swift", "ToolTail.swift"], apis: ["PlanReveal: Layout", ".lineLimit(3, reservesSpace: true)", ".transaction { $0.animation = nil }"], notes: "适配 0.36 只读工具并发分组；思考框 3 行定高零重排并增加等宽秒数；PlanCard 自下而上裁剪展开。" },
    ask: { files: ["InlineAsk.swift", "Vault/FormSheet.swift", "AskSheetLogic"], apis: ["Binding<[String]>", "ViewThatFits", "Vault Keychain Gate"], notes: "0.36 InlineAsk 直接在对话流回答单/多选与自定义补充；含 field.secret 或 requiresVault 字段硬隔离走 FormSheet。" },
    approval: { files: ["ApproveView.swift", "InlineApproval.swift", "Taint.swift"], apis: ["DragGesture", "CHHapticEngine AHAP", "ApprovalViewport"], notes: "外网污染 Taint 强制逐次确认；AX3 自动取消纸张倾斜并启用滚动；A 朱印 thud / B 棘轮 / C 潮汐波。" },
    search: { files: ["DeskSidebarView.swift", "UnifiedSearchSheet", "TeamModel+Search.swift", "MemoryIndexService.swift"], apis: ["SQLite FTS5", "clio-index.db + clio-docs-fts.db", "UIViewPropertyAnimator"], notes: "侧栏提升「记忆 拾遗」为 1 tap 直达，并统一对接三大 SQLite FTS5 索引做全库高亮搜索。" },
    models: { files: ["ChatPage+Chips.swift", "ServicePage.swift", "DefaultModelsPage.swift", "ImageModelPage.swift"], apis: ["BrandIcons Cache", "Selection Haptic", "ThinkingStyle"], notes: "聊天内不退出切换模型与思考档；设置内集中分派「默认 / 备用 / 记忆整理 / 生图」四角色。" },
    files: { files: ["StudyPage.swift", "InteractivePreview.swift", "DiffText.swift", "Workspace.swift"], apis: ["Security-Scoped Bookmark", "clio-docs-fts.db", ".navigationTransition(.zoom)"], notes: "显示本地文档、外部挂载状态与 PDF 全文索引标志；HTML 沙箱严格断网拦截且支持图卡 Zoom 过渡。" },
    roam_den: { files: ["RoamChrome.swift", "Browser.swift", "DenPage.swift", "HillsPage.swift", "Inkstone.swift"], apis: ["WKWebView", "SwiftTerm / iSH", "Ed25519 HostKeyKeeper"], notes: "打通工作台三件套：浏览器人工接手卡片、Alpine Linux 本地终端、SSH 远山公钥与主机指纹信任。" },
    ext: { files: ["ConnectorsPage.swift", "Google.swift", "Skills.swift", "SkillInstaller.swift"], apis: ["OAuth / MCPAuth", "Workspace 技能/", "RowCard"], notes: "云端连接器与远山自建 MCP 互相打通；Skills 按目录加载并支持单开关启停。" },
    memory: { files: ["MemoryPageV2.swift", "MemoryImportSheet.swift", "NameCardView.swift", "Daily.swift"], apis: ["SQLite 4-Layer Memory", "matchFlip Transition", "ShareLink Desensitized"], notes: "四层记忆标记 AI 写入可撤回 vs 用户手写保护；旅伴名帖正反翻转并带去敏分享功能。" },
    settings: { files: ["SettingsView.swift", "LookPage.swift", "FontPage.swift", "StopPicker.swift", "SecretsPage.swift", "VoiceSettings.swift"], apis: ["NavigationStack (All Push)", "StopRuler + detent", "Bilingual Alias Search"], notes: "统一 8+1 分类与全 Push 转场，提亮语音/密码匣；StopRuler 连拖不丢指针，跨默认档给 detent 吸合。" },
    care: { files: ["CarePage.swift (Split)", "Backup.swift", "WebDAV.swift", "UsageSheet.swift", "FrameMeter.swift"], apis: ["BackupCrypto AES-GCM", "Charts / Ring", "Hitches Monitor"], notes: "彻底拆解 1583 行巨石 CarePage：加密本地/WebDAV 恢复独立表单 + Flighty/OffScreen 风格用量与诊断。" },
    motion_lab: { files: ["Ink.swift (Motion)", "DeskSlideHost.swift", "ChatListViewController.swift", "Haptics.swift"], apis: ["WWDC23 10158 Spring", "UIViewPropertyAnimator", "CADisplayLink Keyboard", "CHHapticEngine"], notes: "四档物理弹簧 (Instant/Quick/Standard/Expressive)、中途抢夺手势速度继承、15Hz 零闪对比与键盘锚点锁定。" }
  };

  // ==================== Render Master Pipeline ====================
  function renderAll(opts = {}) {
    applyThemeVariables();
    updateDynamicIsland();
    renderStudioSceneGrid();
    renderTopBar();
    renderViewport(opts);
    renderBottomDock();
    renderModalLayer();
    renderInspector();
    syncStudioActiveButtons();
    drawAllPetCanvases(performance.now());
  }

  function renderStudioSceneGrid() {
    const grid = document.getElementById("sceneGrid");
    if (!grid) return;
    const list = SCENE_GROUPS[state.activeGroup] || SCENE_GROUPS.core;
    grid.innerHTML = list.map((it) => `
      <button type="button" class="scene-btn ${state.scene === it.id ? "active" : ""}" data-scene="${it.id}">
        ${it.label}
        <small>${it.sub}</small>
      </button>
    `).join("");
    grid.querySelectorAll("[data-scene]").forEach((btn) => {
      btn.onclick = () => {
        emitHaptic("silent", `切换展示页: ${btn.dataset.scene}`);
        switchScene(btn.dataset.scene);
      };
    });
  }

  function updateDynamicIsland() {
    const di = document.getElementById("dynamicIsland");
    const dot = document.getElementById("diDot");
    const label = document.getElementById("diLabel");
    if (!di || !dot || !label) return;

    let text = `${t("idle")} · Clio`;
    dot.className = "di-dot";
    di.classList.remove("expanded");

    if (state.viewState === "error") {
      text = "网络已断开 · 离线可用";
      dot.style.background = "var(--danger)";
      di.classList.add("expanded");
    } else if (state.voiceRecording) {
      text = "正在听写 · 震动已避让";
      dot.classList.add("pulse");
      dot.style.background = "var(--danger)";
      di.classList.add("expanded");
    } else if (state.streaming) {
      text = `${t("replying")} · ${state.activeModel.vendor}`;
      dot.classList.add("pulse");
      dot.style.background = "var(--accent)";
      di.classList.add("expanded");
    } else if (state.scene === "approval" && state.inlineApprovalStatus === "pending") {
      text = `${t("waiting")} · 1 项`;
      dot.style.background = "var(--warn)";
      di.classList.add("expanded");
    } else if (state.scene === "roam_den" && state.denStatus === "running") {
      text = `${t("terminal")} · 运行中`;
      dot.classList.add("pulse");
      dot.style.background = "var(--accent)";
    } else {
      dot.style.background = "var(--ok)";
    }
    label.textContent = text;
  }

  function syncImmersiveOverlays() {
    const screen = document.getElementById("iphoneScreen");
    if (!screen) return;
    screen.dataset.chrome = (state.scene === "chat" || state.scene === "pet") ? state.chromeMode : "full";
    let topPill = document.getElementById("immersiveTopPill");
    if (!topPill) {
      topPill = document.createElement("button");
      topPill.type = "button";
      topPill.className = "immersive-top-pill";
      topPill.id = "immersiveTopPill";
      screen.appendChild(topPill);
      topPill.onclick = () => {
        restoreFullChrome("点击顶部恢复控件");
      };
    }
    const stText = state.streaming ? t("replying") : (state.inlineApprovalStatus === "pending" && state.scene === "approval" ? t("waiting") : "阅读历史中");
    topPill.innerHTML = `<span class="status-dot ${state.streaming ? "busy" : ""}"></span><span>${escHtml(state.assistant.name)} · ${stText}</span><span style="color:var(--accent); font-weight:600;">恢复控件 ▾</span>`;

    let botBar = document.getElementById("immersiveBottomBar");
    if (!botBar) {
      botBar = document.createElement("div");
      botBar.className = "immersive-bottom-bar";
      botBar.id = "immersiveBottomBar";
      botBar.innerHTML = `<button type="button" class="immersive-stop-pill" id="btnImmersiveStop" style="display:none;">■ 停止生成</button><button type="button" class="immersive-restore-pill" id="btnImmersiveLatest">↓ 回到最新</button>`;
      screen.appendChild(botBar);
      botBar.querySelector("#btnImmersiveStop").onclick = () => {
        stopStreaming("沉浸模式停止生成");
      };
      botBar.querySelector("#btnImmersiveLatest").onclick = () => {
        state.chatFollowBottom = true;
        restoreFullChrome("回到最新消息");
        const sc = document.getElementById("mainScroller");
        if (sc) {
          ScrollChromeController.markProgrammaticScroll();
          sc.scrollTop = sc.scrollHeight;
        }
      };
    }
    const inChat = state.scene === "chat" || state.scene === "pet";
    const isImm = inChat && state.chromeMode === "immersive";
    botBar.classList.toggle("active", isImm);
    const stopBtn = botBar.querySelector("#btnImmersiveStop");
    const latestBtn = botBar.querySelector("#btnImmersiveLatest");
    if (stopBtn) stopBtn.style.display = state.streaming ? "inline-flex" : "none";
    if (latestBtn) latestBtn.textContent = state.streaming ? "↓ 回到最新（生成中）" : "↓ 回到最新";
  }

  function renderTopBar() {
    const bar = document.getElementById("appTopBar");
    if (!bar) return;
    const working = state.streaming || state.petState === "working" || state.petState === "thinking";
    const statusMap = {
      files: t("files"), memory: t("memory"), roam_den: "工作台", settings: t("settings"),
      search: "全局搜索", onboarding_home: t("home"), models: t("modelsTitle"),
      ext: "连接技能", care: "备份诊断", motion_lab: "动效测试",
      approval: state.inlineApprovalStatus === "pending" ? t("waiting") : "已处理"
    };
    const statusText = state.voiceRecording ? "听写中" : (state.streaming ? t("replying") : (statusMap[state.scene] || t("idle")));
    const vendorChar = state.activeModel.vendor.slice(0, 1);
    const shortModel = resolveShortModelName(state.activeModel.code);

    bar.innerHTML = `
      <button type="button" class="glass-circle pressable" id="btnSidebar" aria-label="打开侧边栏">
        <span style="font-size:15px; line-height:1;">☰</span>
      </button>
      <button type="button" class="glass-pill pressable" id="btnIdentity">
        <div class="avatar-wrap ${working ? "breathing" : ""}" style="overflow:hidden;">
          ${renderAvatarMarkup("assistant", 22, "live")}
        </div>
        <div class="topbar-identity">
          <span class="topbar-name">${escHtml(state.assistant.name)}</span>
          <span class="topbar-status"><span class="status-dot ${working ? "busy" : (state.scene === "approval" && state.inlineApprovalStatus === "pending" ? "warn" : "")}"></span><span class="topbar-status-text">${escHtml(statusText)}</span></span>
        </div>
      </button>
      <div class="glass-pill topbar-right-group">
        <button type="button" class="model-chip-btn pressable" id="btnModelMenu" title="${escHtml(state.activeModel.code)}">
          <span class="vendor-badge">${vendorChar}<span class="vendor-sub">${state.activeModel.sub}</span></span>
          <span class="font-mono" style="font-size:11px; max-width:86px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">${escHtml(shortModel)}</span>
          <span style="font-size:9px; opacity:0.6;">▾</span>
        </button>
        <span class="topbar-sep"></span>
        <button type="button" class="more-btn pressable" id="btnMoreMenu" aria-label="更多操作">⋯</button>
      </div>
    `;
    syncImmersiveOverlays();

    document.getElementById("btnSidebar").onclick = () => {
      emitHaptic("silent", "打开侧边栏");
      state.sidebarOpen = true;
      renderModalLayer();
    };
    document.getElementById("btnIdentity").onclick = () => {
      emitHaptic("silent", "查看旅伴气泡 / 名帖");
      switchScene("memory");
      state.memorySub = "cards";
      renderAll({ resetScroll: true });
    };
    document.getElementById("btnModelMenu").onclick = () => {
      emitHaptic("silent", "展开顶栏模型菜单");
      state.moreMenuOpen = false;
      state.diExpanded = false;
      state.modelMenuOpen = !state.modelMenuOpen;
      renderModalLayer();
    };
    document.getElementById("btnMoreMenu").onclick = () => {
      emitHaptic("silent", "展开更多菜单");
      state.modelMenuOpen = false;
      state.diExpanded = false;
      state.moreMenuOpen = !state.moreMenuOpen;
      renderModalLayer();
    };
  }

  // ==================== Global Non-Normal State Simulator Overlay ====================
  function renderViewStateBannerOrReplace(scroller) {
    if (state.viewState === "normal") return false;
    const targetName = (SCENE_GROUPS[state.activeGroup]?.find((x) => x.id === state.scene)?.label) || "当前页面";

    if (state.viewState === "empty") {
      scroller.innerHTML = `
        <div class="state-empty-box">
          <canvas id="emptyPetCanvas" data-pet-canvas="1" width="48" height="48" style="width:64px;height:64px;image-rendering:pixelated;margin-bottom:8px;"></canvas>
          <div class="font-mark" style="font-size:19px; font-weight:700; margin-bottom:6px;">风起于青萍，尚未落笔</div>
          <div style="font-size:13px; color:var(--ink-secondary); max-width:260px; line-height:1.5; margin-bottom:14px;">
            「${targetName}」当前为空白态。遵守 DS 2.0 规范：空白页禁止留死白，始终提供温和引导与 1-tap 起始入口。
          </div>
          <div style="display:flex; gap:8px; flex-wrap:wrap; justify-content:center;">
            <button type="button" class="filter-pill active" id="btnRestoreNormalState">加载示例工作数据</button>
            <button type="button" class="filter-pill" id="btnJumpSearchEmpty">打开全局搜索</button>
          </div>
        </div>
      `;
      scroller.querySelector("#btnRestoreNormalState").onclick = () => { state.viewState = "normal"; emitHaptic("light", "恢复数据"); renderAll(); };
      scroller.querySelector("#btnJumpSearchEmpty").onclick = () => { state.viewState = "normal"; switchScene("search"); };
      return true;
    }

    if (state.viewState === "loading") {
      scroller.innerHTML = `
        <div class="clio-card" style="padding:14px; margin-bottom:12px;">
          <div style="display:flex; align-items:center; gap:8px; margin-bottom:10px;">
            <span class="status-dot busy"></span>
            <strong style="font-size:13.5px;">正在加载「${targetName}」（异步 FTS5 + CoreText 预排版）</strong>
          </div>
          <div class="skel-line" style="width:72%;"></div>
          <div class="skel-line" style="width:94%;"></div>
          <div class="skel-line" style="width:58%;"></div>
        </div>
        <div class="clio-card" style="padding:14px;">
          <div class="skel-line" style="width:45%; height:14px;"></div>
          <div class="skel-line" style="width:88%;"></div>
          <div class="skel-line" style="width:80%;"></div>
        </div>
        <button type="button" class="filter-pill" id="btnStopSkeleton" style="margin-top:12px;">完成加载（恢复正常视图）</button>
      `;
      scroller.querySelector("#btnStopSkeleton").onclick = () => { state.viewState = "normal"; renderAll(); };
      return true;
    }

    if (state.viewState === "error") {
      scroller.innerHTML = `
        <div class="offline-card">
          <div style="font-size:20px; margin-bottom:6px;">⛨ 网络已断开 / 接口不可达</div>
          <div style="font-size:13px; color:var(--ink); font-weight:600; margin-bottom:4px;">api.deepseek.com 连接超时（NSURLErrorTimedOut）</div>
          <div style="font-size:12px; color:var(--ink-secondary); line-height:1.5; margin-bottom:12px;">
            遵守「优雅降级」规则：严禁只甩冰冷错误码或无限转圈。你的<strong>本地记忆拾遗、书案 PDF 检索与 Alpine 斗室</strong>目前完全离线可用。
          </div>
          <div style="display:flex; gap:8px; flex-wrap:wrap;">
            <button type="button" class="filter-pill active" id="btnRetryNet">重试连接</button>
            <button type="button" class="filter-pill" id="btnGoLocalFiles">离线看书案文档</button>
          </div>
        </div>
      `;
      scroller.querySelector("#btnRetryNet").onclick = () => {
        state.viewState = "normal";
        emitHaptic("confirm", "恢复联网连接");
        showToast("已重新连上服务商 ✓");
        renderAll();
      };
      scroller.querySelector("#btnGoLocalFiles").onclick = () => { state.viewState = "normal"; switchScene("files"); };
      return true;
    }

    if (state.viewState === "outcome") {
      scroller.innerHTML = `
        <div class="clio-card" style="padding:14px; border-left:3px solid var(--ok); margin-bottom:12px;">
          <div style="display:flex; align-items:center; gap:8px; font-weight:700; color:var(--ok); margin-bottom:4px;">
            <span>✓</span><span>任务交付成功 · 三重冗余状态编码（色+形+文）</span>
          </div>
          <div style="font-size:12.5px; color:var(--ink-secondary); line-height:1.5;">
            WebDAV 加密快照 <span class="font-mono">clio-20261125.clioenc</span> 已校验完毕并归档（触发 <span class="font-mono">Success</span> 触觉）。
          </div>
        </div>
        <div class="clio-card" style="padding:14px; border-left:3px solid var(--danger); margin-bottom:12px; background:var(--stop-wash);">
          <div style="display:flex; align-items:center; gap:8px; font-weight:700; color:var(--danger); margin-bottom:4px;">
            <span>✕</span><span>工具执行失败 · 非阻断性可恢复状态</span>
          </div>
          <div style="font-size:12.5px; color:var(--ink); line-height:1.5; margin-bottom:8px;">
            步骤 <span class="font-mono">nginx -t</span> 返回 exit code 1（第 14 行缺少分号），已拦截 <span class="font-mono">reload</span> 并保留现场日志（触发 <span class="font-mono">Error</span> 触觉）。
          </div>
          <div style="display:flex; gap:8px;">
            <button type="button" class="filter-pill active" id="btnViewFailLog">查看终端日志</button>
            <button type="button" class="filter-pill" id="btnBackNormalOutcome">返回正常视图</button>
          </div>
        </div>
      `;
      scroller.querySelector("#btnViewFailLog").onclick = () => { state.viewState = "normal"; state.roamSub = "den"; switchScene("roam_den"); };
      scroller.querySelector("#btnBackNormalOutcome").onclick = () => { state.viewState = "normal"; renderAll(); };
      return true;
    }
    return false;
  }

  function attachImeSafeInput(inputEl, onUpdate) {
    if (!inputEl) return;
    let composing = false;
    inputEl.addEventListener("compositionstart", () => { composing = true; });
    inputEl.addEventListener("compositionend", (e) => {
      composing = false;
      onUpdate(e.target.value);
    });
    inputEl.addEventListener("input", (e) => {
      if (composing || e.isComposing) return;
      onUpdate(e.target.value);
    });
  }

  function updateFloatingSelectionToolbar(vp) {
    const host = vp || document.getElementById("appViewport");
    if (!host) return;
    const existing = host.querySelector(".selection-toolbar");
    if (existing) existing.remove();
    if (!state.selectionMenuText) return;

    const bar = document.createElement("div");
    bar.className = "selection-toolbar";
    bar.innerHTML = `
      <button type="button" id="selCopy">拷贝</button>
      <button type="button" id="selQuote">引用追问</button>
      <button type="button" id="selMem">存入拾遗</button>
      <button type="button" id="selSpeak">朗读</button>
      <button type="button" id="selClose" style="opacity:0.6;">✕</button>
    `;
    host.appendChild(bar);
    bar.querySelector("#selCopy").onclick = () => {
      emitHaptic("light", "拷贝选中文本");
      try { navigator.clipboard?.writeText(state.selectionMenuText); } catch (_) {}
      showToast("已拷贝纯净原文（选区与排版未破坏）");
      state.selectionMenuText = null;
      state.selectionActive = false;
      try { window.getSelection()?.removeAllRanges(); } catch (_) {}
      updateFloatingSelectionToolbar(host);
    };
    bar.querySelector("#selQuote").onclick = () => {
      emitHaptic("silent", "引用追问");
      state.pendingQuote = state.selectionMenuText;
      state.selectionMenuText = null;
      state.selectionActive = false;
      try { window.getSelection()?.removeAllRanges(); } catch (_) {}
      restoreFullChrome("引用追问");
      switchScene("chat");
      const inp = document.getElementById("composerInput");
      if (inp) inp.focus();
    };
    bar.querySelector("#selMem").onclick = () => {
      emitHaptic("confirm", "选字存入记忆");
      state.memories.unshift({ id: "m" + Date.now(), layer: "surface", kind: "note", text: state.selectionMenuText, source: "user", date: "刚刚" });
      showToast("已存入手写记忆");
      state.selectionMenuText = null;
      state.selectionActive = false;
      updateFloatingSelectionToolbar(host);
    };
    bar.querySelector("#selSpeak").onclick = () => {
      emitHaptic("silent", "AVSpeechSynthesizer 朗读");
      showToast("正在调用系统中文语音朗读…");
      state.selectionMenuText = null;
      state.selectionActive = false;
      updateFloatingSelectionToolbar(host);
    };
    bar.querySelector("#selClose").onclick = () => {
      state.selectionMenuText = null;
      state.selectionActive = false;
      try { window.getSelection()?.removeAllRanges(); } catch (_) {}
      updateFloatingSelectionToolbar(host);
    };
  }

  function renderViewport(opts = {}) {
    const vp = document.getElementById("appViewport");
    if (!vp) return;
    const prevScroller = document.getElementById("mainScroller");
    const prevScrollTop = (!opts.resetScroll && prevScroller) ? prevScroller.scrollTop : 0;

    vp.innerHTML = "";
    updateFloatingSelectionToolbar(vp);

    const scroller = document.createElement("div");
    scroller.className = "scroll-content";
    scroller.id = "mainScroller";
    // Mount BEFORE scene renderers so document.getElementById resolves reliably!
    vp.appendChild(scroller);

    if (!renderViewStateBannerOrReplace(scroller)) {
      if (state.scene === "chat" || state.scene === "pet") renderChatScene(scroller, vp);
      else if (state.scene === "onboarding_home") renderOnboardingHomeScene(scroller);
      else if (state.scene === "tools") renderToolsScene(scroller);
      else if (state.scene === "ask") renderInlineAskScene(scroller);
      else if (state.scene === "approval") renderApprovalScene(scroller);
      else if (state.scene === "search") renderSearchScene(scroller);
      else if (state.scene === "models") renderModelsScene(scroller);
      else if (state.scene === "files") renderFilesScene(scroller);
      else if (state.scene === "roam_den") renderRoamDenScene(scroller);
      else if (state.scene === "ext") renderExtScene(scroller);
      else if (state.scene === "memory") renderMemoryScene(scroller);
      else if (state.scene === "settings") renderSettingsScene(scroller);
      else if (state.scene === "care") renderCareScene(scroller);
      else if (state.scene === "motion_lab") renderMotionLabScene(scroller);
    }

    ScrollChromeController.markProgrammaticScroll();
    if (opts.scrollToBottom) {
      scroller.scrollTop = scroller.scrollHeight;
    } else if (prevScrollTop > 0) {
      scroller.scrollTop = prevScrollTop;
    }
  }

  // ==================== Scene 1 & 3: Complex Markdown Chat, 5-Combo Font Comparator & Pet Studio ====================
  function renderLanguageChatHeader() {
    if (state.lang === "B") {
      return `<div class="lang-header-B"><span>CORE // 120Hz TILES</span><span>CTX ${(state.chatTurns.length * 14).toFixed(0)}% · MONO DIGITS</span></div>`;
    }
    return "";
  }

  function renderFontComparePanel() {
    const combo = TOKENS.fontCombos.find((x) => x.id === state.fontCombo) || TOKENS.fontCombos[4];
    const buttons = TOKENS.fontCombos.map((c) => `
      <button type="button" class="filter-pill ${state.fontCombo === c.id ? "active" : ""}" style="font-size:11px; padding:3px 9px;" data-pick-combo="${c.id}">${c.id}</button>
    `).join("");
    return `
      <div class="clio-card" style="padding:12px 13px; margin-bottom:12px;">
        <div style="display:flex; justify-content:space-between; align-items:center; gap:6px; margin-bottom:7px;">
          <strong style="font-size:13px;">4.6 同一复杂样本 · 5 组字体光学对照</strong>
          <button type="button" class="reply-action-btn" id="btnCloseFontCompare" style="font-size:11.5px;">收起</button>
        </div>
        ${renderFontStatusStripHtml()}
        <div style="display:flex; gap:5px; flex-wrap:wrap; margin-bottom:7px;">${buttons}</div>
        <div style="font-size:11.5px; color:var(--ink-secondary); margin-bottom:8px; line-height:1.45;">
          <strong style="color:var(--accent);">${combo.title}</strong>：${combo.desc}
        </div>
        <div class="clio-inner-block" style="background:var(--bg); padding:10px 11px;">
          <div class="font-reading combo-sample" data-combo="${combo.id}" id="fontCompareSampleBody">
            ${renderStreamingMarkdown(SECTION46_SAMPLE.fullMarkdown, false)}
          </div>
        </div>
        <div style="font-size:10.5px; color:var(--ink-tertiary); margin-top:6px;">
          注：ClioKai / MapleMono 已从仓库 App/Fonts 直载；Apple 系统字体非 Apple 平台已标记回退，最终 CoreText 行框度量为 iPhone 真机裁决基准。
        </div>
      </div>
    `;
  }

  function renderPetStudioPanel() {
    const aPetName = activePetDisplayName();
    const followOn = state.assistant.followPet;
    const sizeInfo = TOKENS.petSizes.find((s) => Math.abs(s.factor - state.petSizeFactor) < 0.01) || TOKENS.petSizes[1];
    const snoozed = state.petSnoozeUntil && state.petSnoozeUntil > Date.now();
    const actLabels = [
      { id: "lively", title: "活泼 · 会冒泡" },
      { id: "quiet", title: "安静 · 只做动作" },
      { id: "minimal", title: "极简 · 仅待批/出错动" }
    ];
    const petCardsHtml = TOKENS.petCatalog.map((item) => {
      const picked = state.petActiveId === item.id;
      const shownName = activePetDisplayName(item.id);
      return `
        <button type="button" class="pet-card-btn ${picked ? "active" : ""}" data-select-pet="${item.id}">
          <canvas data-pet-canvas="1" data-pet-id="${item.id}" width="48" height="48" style="width:38px;height:38px;image-rendering:pixelated;"></canvas>
          <strong style="font-size:12.5px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; max-width:100%;">${escHtml(shownName)}</strong>
          <span class="pet-card-tag">${item.badge}</span>
        </button>
      `;
    }).join("");
    const customCardHtml = state.petCustomPhoto ? `
      <button type="button" class="pet-card-btn ${state.petActiveId === "custom" ? "active" : ""}" data-select-pet="custom">
        <img src="${state.petCustomPhoto}" alt="自定义宠物" style="width:38px;height:38px;border-radius:10px;object-fit:cover;" />
        <strong style="font-size:12.5px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; max-width:100%;">${escHtml(activePetDisplayName("custom"))}</strong>
        <span class="pet-card-tag">已导入</span>
      </button>` : `
      <button type="button" class="pet-card-btn" id="btnPickCustomPet">
        <div style="width:38px;height:38px;border-radius:10px;background:var(--surface-subtle);display:flex;align-items:center;justify-content:center;font-size:18px;color:var(--accent);">＋</div>
        <strong style="font-size:12.5px;">导入图片/包</strong>
        <span class="pet-card-tag">PNG/GIF/Zip</span>
      </button>`;

    return `
      <div class="clio-card" style="padding:13px; margin-bottom:11px;">
        <div style="display:flex; justify-content:space-between; align-items:center; gap:8px; margin-bottom:6px;">
          <div style="font-weight:700; font-size:15px;" class="font-mark">伴读宠物与身份工作室</div>
          <span class="filter-pill" style="font-size:10.5px; padding:1px 8px;">当前立宠 · ${escHtml(aPetName)}</span>
        </div>
        <div style="font-size:12px; color:var(--ink-secondary); line-height:1.5; margin-bottom:10px;">
          陪伴宠物与助手头像已完成解耦：输入栏上沿只做水平拖拽，且同时支持自由定制「助手名字 / 头像 / 朱印」与「我的头像」。
        </div>
        <div style="display:flex; gap:8px; flex-wrap:wrap; margin-bottom:10px;">
          <button type="button" class="filter-pill active" data-edit-identity="assistant">🪶 编辑助手 (${escHtml(state.assistant.name)})</button>
          <button type="button" class="filter-pill" data-edit-identity="me">🪪 编辑我的 (${escHtml(state.userProfile.name)})</button>
        </div>

        <div style="font-size:12px; font-weight:600; color:var(--ink-secondary); margin-bottom:6px;">① 选择伴读伙伴（内置 2 只实装 + 3 只 2.0 规划新增 + 导入）</div>
        <div class="pet-grid">${petCardsHtml}${customCardHtml}</div>
        <input type="file" id="petCustomFileInput" accept="image/*" style="display:none;" />

        <div style="display:flex; align-items:center; gap:8px; margin-bottom:9px;">
          <span style="font-size:12px; color:var(--ink-secondary); white-space:nowrap;">宠物昵称</span>
          <input class="field-input" id="petNicknameInput" value="${escHtml(aPetName)}" placeholder="给这只伙伴起个昵称" style="padding:6px 10px; font-size:12.5px;" />
          ${state.petActiveId === "custom" ? `<button type="button" class="filter-pill ${state.petCustomBreathe ? "active" : ""}" id="btnToggleCustomBreathe" style="font-size:11px; flex-shrink:0;">呼吸:${state.petCustomBreathe ? "开" : "关"}</button>` : ""}
        </div>

        <div style="font-size:11.5px; color:var(--ink-tertiary); margin-bottom:5px;">试看全部动作状态（点下方立宠同样触发轻震与反馈）</div>
        <div style="display:flex; flex-wrap:wrap; gap:5px; margin-bottom:10px;">
          ${["idle:闲坐", "thinking:沉吟", "working:干活", "notification:候印", "attention:开心", "error:懵了", "sleeping:睡觉"].map((item) => {
            const [k, label] = item.split(":");
            return `<button type="button" class="filter-pill ${state.petState === k ? "active" : ""}" style="font-size:11px; padding:3px 9px;" data-pet-mood="${k}">${label}</button>`;
          }).join("")}
        </div>
      </div>

      <div class="row-card" style="margin-bottom:12px;">
        <button type="button" class="switch-row" id="swFollowPet">
          <div style="flex:1; min-width:0;">
            <div style="font-weight:600; font-size:13.5px;">② 助手头像跟随伴读宠物</div>
            <div style="font-size:11.5px; color:var(--ink-secondary);">${followOn ? "已联动：换宠物时正文与顶栏助手头像同步切换" : "已解耦：助手使用独立头像/单字圆章，互不打扰"}</div>
          </div>
          <span class="ios-switch ${followOn ? "on" : ""}"></span>
        </button>

        <button type="button" class="row-item pressable" id="btnPetSizeRuler">
          <div style="flex:1; min-width:0;">
            <div style="font-weight:600; font-size:13.5px;">③ 宠物大小（StopRuler 档位）</div>
            <div style="font-size:11.5px; color:var(--ink-secondary);">沿用标准竖向胶囊拖动调节 · 禁止数字 Stepper</div>
          </div>
          <span class="font-mono" id="settingVal-petSize" style="font-size:12px; color:var(--accent); font-weight:600;">${sizeInfo.detail} ⇵</span>
        </button>

        <button type="button" class="switch-row" id="swPetVisible">
          <div style="flex:1; min-width:0;">
            <div style="font-weight:600; font-size:13.5px;">④ 站在输入框上沿</div>
            <div style="font-size:11.5px; color:var(--ink-secondary);">${snoozed ? "已暂时收起（歇 1 小时），头像不受影响" : "关掉或歇一会儿后仍保留正文与名帖头像"}</div>
          </div>
          <span class="ios-switch ${isPetVisibleNow() ? "on" : ""}"></span>
        </button>

        <div class="row-item" style="flex-direction:column; align-items:stretch; gap:7px;">
          <div style="display:flex; justify-content:space-between; align-items:center;">
            <span style="font-weight:600; font-size:13.5px;">⑤ 互动活跃度</span>
            <div style="display:flex; gap:6px;">
              <button type="button" class="filter-pill" id="btnPetSnooze" style="font-size:11px; padding:2px 8px;">${snoozed ? "马上叫醒" : "歇 1 小时"}</button>
              <button type="button" class="filter-pill" id="btnTriggerPetBubble" style="font-size:11px; padding:2px 8px;">试发冒泡</button>
            </div>
          </div>
          <div style="display:flex; gap:6px; flex-wrap:wrap;">
            ${actLabels.map((a) => `<button type="button" class="filter-pill ${state.petActivity === a.id ? "active" : ""}" style="font-size:11px; padding:3px 9px;" data-pet-activity="${a.id}">${a.title}</button>`).join("")}
          </div>
        </div>

        <div class="row-item" style="flex-direction:column; align-items:stretch; gap:6px;">
          <div style="display:flex; justify-content:space-between; align-items:center;">
            <span style="font-weight:600; font-size:13.5px;">⑥ 分助手绑定不同宠物</span>
            <span style="font-size:11px; color:var(--ink-tertiary);">切对话自动换宠</span>
          </div>
          <div style="display:flex; gap:6px; flex-wrap:wrap;">
            <button type="button" class="filter-pill ${state.petActiveBotKey === "default" ? "active" : ""}" style="font-size:11.5px;" data-pet-bot="default">${escHtml(state.assistant.name)} · 绑${escHtml(activePetDisplayName(state.petBotBindings.default))}</button>
            <button type="button" class="filter-pill ${state.petActiveBotKey === "architect" ? "active" : ""}" style="font-size:11.5px;" data-pet-bot="architect">架构师 · 绑${escHtml(activePetDisplayName(state.petBotBindings.architect))}</button>
          </div>
        </div>
      </div>
    `;
  }

  function renderChatScene(scroller, vp) {
    const isPetScene = state.scene === "pet";
    let html = renderLanguageChatHeader();

    if (isPetScene) {
      html += renderPetStudioPanel();
    }

    html += `
      <div style="display:flex; justify-content:space-between; align-items:center; gap:6px; margin-bottom:10px; flex-wrap:wrap;">
        <div style="display:flex; gap:5px; flex-wrap:wrap; align-items:center;">
          <button type="button" class="filter-pill" id="btnDemoSelection">✎ ${t("selectDemo")}</button>
          <button type="button" class="filter-pill ${state.fontCompareOpen ? "active" : ""}" id="btnToggleFontCompare">Aa 5字体对照</button>
          <button type="button" class="filter-pill ${state.showChatFaces ? "active" : ""}" id="btnToggleChatFaces">👤 头像:${state.showChatFaces ? "开" : "关"}</button>
          <button type="button" class="filter-pill ${state.chatKeyboardOpen ? "active" : ""}" id="btnToggleSimKeyboard">⌨ ${state.chatKeyboardOpen ? "收起键盘" : "模拟键盘"}</button>
        </div>
        <div style="display:flex; gap:5px; align-items:center;">
          ${state.compressedNotice ? `<span class="font-mono" style="font-size:10.5px; color:var(--ok);">已收卷 38%</span>` : ""}
          <button type="button" class="filter-pill" id="btnSimulateStream">${state.streaming ? "■ 停止输出" : "▶ 复杂流式"}</button>
        </div>
      </div>
    `;

    if (state.fontCompareOpen) {
      html += renderFontComparePanel();
    }

    state.chatTurns.forEach((turn, idx) => {
      const thinkingHtml = turn.thinking ? `
        <div class="thinking-box">
          <div class="thinking-toggle">${turn.streaming ? "✦ 正在思考 · 推演中" : "✦ 已思考 1.8s · 48 字"}</div>
          ${turn.streaming ? `<div class="thinking-live-window">检查 UIKit 瓦片缓存命中……<br>锁定 anchorOffset Δ = 0.0pt……<br>Telegram 级渐显平滑推进……</div>` : ""}
        </div>` : "";

      const toolBadgeInfo = turn.toolAggregate
        ? (TOKENS.toolStatuses7?.find((x) => x.key === turn.toolAggregate.status) || { icon: "!", label: turn.toolAggregate.label })
        : null;
      const turnToolHtml = turn.toolAggregate ? `
        <div class="trace-card" style="padding:8px 11px;">
          <div style="display:flex; align-items:center; justify-content:space-between; gap:8px;">
            <span class="tool-state-badge ${escHtml(turn.toolAggregate.status)}">${escHtml(toolBadgeInfo.icon)} ${escHtml(turn.toolAggregate.label || toolBadgeInfo.label)}</span>
            <span style="font-size:11px; color:var(--ink-secondary);">${escHtml(turn.toolAggregate.detail || "")}</span>
          </div>
        </div>` : "";

      const codeHtml = turn.code ? `
        <div class="clio-inner-block">
          <div class="code-header">
            <span class="font-mono">swift · 2:1 grid</span>
            <button type="button" class="code-copy-btn" data-copy-code="${turn.id}">复制</button>
          </div>
          <pre class="code-pre">${escHtml(turn.code)}</pre>
        </div>` : "";

      const srcHtml = turn.sources ? `
        <button type="button" class="sources-pill pressable" data-open-sources="1">
          <span class="source-dots"><span class="source-dot">W</span><span class="source-dot">A</span><span class="source-dot">L</span></span>
          <span>${turn.sources.length} 个${t("source")}</span>
          <span style="opacity:0.55;">›</span>
        </button>` : "";

      const quotePillHtml = turn.quoted ? `<div style="font-size:11.5px; color:var(--ink-secondary); border-left:2px solid var(--accent); padding-left:7px; margin-bottom:4px; opacity:0.85;">❝ ${escHtml(turn.quoted)}</div>` : "";
      const timeGapHtml = state.showChatFaces ? `<div class="chat-time-gap">${idx === 0 ? "今天 21:40" : "21:42"}</div>` : "";
      const meAvatarHtml = state.showChatFaces ? `<button type="button" class="chat-avatar-btn" data-edit-identity="me" title="点击自定义我的称呼与头像">${renderAvatarMarkup("me", 32)}</button>` : "";
      const speakerHeadHtml = state.showChatFaces ? `
        <button type="button" class="speaker-head-row" data-edit-identity="assistant" title="点击自定义助手名字、头像与朱印">
          <span class="chat-avatar-btn">${renderAvatarMarkup("assistant", 32)}</span>
          <span style="font-size:12.5px; font-weight:600; color:var(--ink-secondary);">${escHtml(state.assistant.name)}</span>
          <span class="speaker-edit-hint">改名/头像 ›</span>
        </button>` : "";

      const liveProseBody = turn.streaming
        ? renderStreamingMarkdown(turn.renderedRevealText ?? (turn.plainText || ""), true)
        : (turn.aiBody || renderStreamingMarkdown(turn.plainText || "……", false));

      html += `
        <section class="chat-turn" id="turn-${turn.id}">
          ${timeGapHtml}
          <div class="msg-user-wrap ${state.showChatFaces ? "with-face" : ""}">
            <div class="msg-user-bubble">${quotePillHtml}${escHtml(turn.user)}</div>
            ${meAvatarHtml}
          </div>
          <div class="msg-assistant ${turn.id > 3 ? "entering" : ""}">
            ${speakerHeadHtml}
            ${thinkingHtml}
            ${turnToolHtml}
            <div class="font-reading reading-measure" data-turn-prose="${turn.id}">
              ${liveProseBody}
            </div>
            ${codeHtml}
            ${srcHtml}
            <div class="reply-actions">
              <button type="button" class="reply-action-btn" data-copy-reply="${turn.id}">❐ ${t("copy")}</button>
              <button type="button" class="reply-action-btn" data-redo-reply="${turn.id}">↻ ${t("redo")}</button>
              <button type="button" class="reply-action-btn" data-quote-reply="${turn.id}">❝ ${t("quote")}</button>
              <span class="font-mono" style="margin-left:auto; font-size:10.5px; color:var(--ink-tertiary);">${turn.metrics || "1.12s"}</span>
            </div>
          </div>
        </section>
      `;
    });

    scroller.innerHTML = html;

    // Floating Jump-to-Latest Pill (shown in full chrome when user scrolls up)
    const jumpPill = document.createElement("button");
    jumpPill.type = "button";
    jumpPill.className = "jump-latest-pill pressable" + ((!state.chatFollowBottom && state.chromeMode !== "immersive") ? " visible" : "");
    jumpPill.id = "btnJumpLatest";
    jumpPill.innerHTML = `<span>↓</span><span>回到最新${state.streaming ? "（生成中）" : ""}</span>`;
    vp.appendChild(jumpPill);

    jumpPill.onclick = () => {
      state.chatFollowBottom = true;
      restoreFullChrome("回到最新");
      ScrollChromeController.markProgrammaticScroll();
      scroller.scrollTop = scroller.scrollHeight;
      jumpPill.classList.remove("visible");
      emitHaptic("silent", "回到底部并恢复跟底");
    };

    const chromeCtrl = new ScrollChromeController(TOKENS.scrollAwareChrome);
    let lastScrollTop = scroller.scrollTop;
    scroller.onscroll = () => {
      const distBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
      const isScrollable = scroller.scrollHeight > scroller.clientHeight + 28;
      state.chatFollowBottom = distBottom <= 36;
      if (!ScrollChromeController.isProgrammaticScroll()) {
        const deltaY = scroller.scrollTop - lastScrollTop;
        const lockReason = getChromeLockReason(state);
        const nextMode = chromeCtrl.handleScroll({
          scrollTop: scroller.scrollTop,
          deltaY,
          distBottom,
          isScrollable,
          locked: Boolean(lockReason)
        });
        if (nextMode !== state.chromeMode) {
          applyChromeModeTransition(nextMode, scroller);
        }
      }
      lastScrollTop = scroller.scrollTop;
      const showFullJump = !state.chatFollowBottom && state.chromeMode !== "immersive" && isScrollable;
      jumpPill.classList.toggle("visible", Boolean(showFullJump));
    };

    // Minimap
    const minimap = document.createElement("div");
    minimap.className = "minimap-rail";
    state.chatTurns.forEach((turn) => {
      const tick = document.createElement("button");
      tick.type = "button";
      tick.className = `minimap-tick ${state.activeTurn === turn.id ? "active" : ""}`;
      tick.title = `跳到第 ${turn.id} 轮`;
      tick.onclick = () => {
        emitHaptic("tick", `小地图跳至第 ${turn.id} 轮`);
        state.activeTurn = turn.id;
        state.chatFollowBottom = false;
        const target = document.getElementById(`turn-${turn.id}`);
        if (target) {
          ScrollChromeController.markProgrammaticScroll();
          target.scrollIntoView({ behavior: state.reduceMotion ? "auto" : "smooth", block: "start" });
        }
        minimap.querySelectorAll(".minimap-tick").forEach((el, idx2) => el.classList.toggle("active", state.chatTurns[idx2]?.id === state.activeTurn));
      };
      minimap.appendChild(tick);
    });
    vp.appendChild(minimap);

    // Non-destructive selection toolbar (NEVER clears selection or wipes #mainScroller DOM!)
    scroller.onmouseup = () => {
      const sel = window.getSelection ? window.getSelection() : null;
      const picked = sel ? sel.toString().trim() : "";
      if (picked.length >= 2) {
        state.chatFollowBottom = false;
        state.selectionActive = true;
        restoreFullChrome("选字保护锁定");
        emitHaptic("selection", "选中正文片段（选区已保护，跟底与自动收起已暂停）");
        state.selectionMenuText = picked.slice(0, 40) + (picked.length > 40 ? "…" : "");
        updateFloatingSelectionToolbar(vp);
      } else if (state.selectionActive && !picked) {
        state.selectionActive = false;
      }
    };

    const btnCmp = document.getElementById("btnToggleFontCompare");
    if (btnCmp) btnCmp.onclick = () => {
      state.fontCompareOpen = !state.fontCompareOpen;
      emitHaptic("selection", "切换 5 组字体光学对照");
      renderViewport();
    };
    const btnCloseCmp = document.getElementById("btnCloseFontCompare");
    if (btnCloseCmp) btnCloseCmp.onclick = () => { state.fontCompareOpen = false; renderViewport(); };
    scroller.querySelectorAll("[data-pick-combo]").forEach((b) => {
      b.onclick = () => {
        state.fontCombo = b.dataset.pickCombo;
        emitHaptic("selection", `对照字体组合 ${state.fontCombo}`);
        renderViewport();
      };
    });
    const btnFaces = document.getElementById("btnToggleChatFaces");
    if (btnFaces) btnFaces.onclick = () => {
      state.showChatFaces = !state.showChatFaces;
      emitHaptic("selection", `正文双方头像 → ${state.showChatFaces ? "开启" : "关闭"}`);
      renderAll();
    };
    const btnSimKb = document.getElementById("btnToggleSimKeyboard");
    if (btnSimKb) btnSimKb.onclick = () => {
      state.chatKeyboardOpen = !state.chatKeyboardOpen;
      if (state.chatKeyboardOpen) restoreFullChrome("键盘弹出锁定控件");
      emitHaptic("silent", state.chatKeyboardOpen ? "弹出模拟键盘" : "收起模拟键盘");
      renderAll();
    };
    scroller.querySelectorAll("[data-edit-identity]").forEach((btn) => {
      btn.onclick = () => openIdentityEditor(btn.dataset.editIdentity);
    });

    const btnSim = document.getElementById("btnSimulateStream");
    if (btnSim) btnSim.onclick = toggleStreamDemo;
    const btnSelDemo = document.getElementById("btnDemoSelection");
    if (btnSelDemo) btnSelDemo.onclick = () => {
      emitHaptic("selection", "跨段选字菜单");
      state.selectionMenuText = "CoreText 光学微距绝不污染复制的纯净原文";
      renderViewport();
    };
    const chartCard = scroller.querySelector("[data-open-attachment-preview]");
    if (chartCard) chartCard.onclick = () => { emitHaptic("silent", "Zoom 预览附件图卡"); state.previewFile = "html"; renderModalLayer(); };

    scroller.querySelectorAll("[data-copy-code]").forEach((btn) => {
      btn.onclick = () => {
        emitHaptic("light", "复制代码块");
        const turn = state.chatTurns.find((x) => String(x.id) === btn.dataset.copyCode);
        if (turn?.code) { try { navigator.clipboard?.writeText(turn.code); } catch (_) {} }
        btn.textContent = "✓ 已复制";
        btn.style.color = "var(--ok)";
        setTimeout(() => { btn.textContent = "复制"; btn.style.color = ""; }, 1200);
      };
    });
    scroller.querySelectorAll("[data-copy-reply]").forEach((btn) => {
      btn.onclick = () => {
        emitHaptic("light", "复制整轮回复");
        btn.textContent = t("copied");
        btn.style.color = "var(--ok)";
        setTimeout(() => { btn.textContent = `❐ ${t("copy")}`; btn.style.color = ""; }, 1200);
      };
    });
    scroller.querySelectorAll("[data-redo-reply]").forEach((btn) => {
      btn.onclick = () => redoTurnStream(Number(btn.dataset.redoReply));
    });
    scroller.querySelectorAll("[data-quote-reply]").forEach((btn) => {
      btn.onclick = () => {
        const turn = state.chatTurns.find((x) => x.id === Number(btn.dataset.quoteReply));
        emitHaptic("silent", "引用追问");
        state.pendingQuote = (turn?.aiTitle || turn?.plainText || "选定回复").slice(0, 32);
        renderBottomDock();
        const inp = document.getElementById("composerInput");
        if (inp) inp.focus();
      };
    });
    scroller.querySelectorAll("[data-open-sources]").forEach((btn) => {
      btn.onclick = () => { emitHaptic("silent", "打开出处清单"); state.sourcesSheetOpen = true; renderModalLayer(); };
    });

    // Pet Studio bindings
    scroller.querySelectorAll("[data-select-pet]").forEach((btn) => {
      btn.onclick = () => {
        const nextId = btn.dataset.selectPet;
        state.petActiveId = nextId;
        state.petBotBindings[state.petActiveBotKey] = nextId;
        if (state.assistant.followPet) {
          state.assistant.avatarPetId = nextId;
          state.assistant.avatarMode = "followPet";
        }
        emitHaptic("pet", `切换伴读宠物 → ${activePetDisplayName(nextId)}`);
        showToast(`已换为「${activePetDisplayName(nextId)}」${state.assistant.followPet ? "（助手头像同步跟随）" : "（助手保留独立头像）"}`);
        renderAll();
      };
    });
    const nickIn = document.getElementById("petNicknameInput");
    if (nickIn) nickIn.oninput = (e) => {
      state.petNicknames[state.petActiveId] = e.target.value;
      const actorEl = document.getElementById("petActor");
      if (actorEl) actorEl.title = `${e.target.value || "小克"}：只可水平拽，轻点或三连戳`;
    };
    const pickCust = document.getElementById("btnPickCustomPet");
    const fileCust = document.getElementById("petCustomFileInput");
    if (pickCust && fileCust) {
      pickCust.onclick = () => fileCust.click();
      fileCust.onchange = (e) => {
        const f = e.target.files?.[0];
        if (!f) return;
        const reader = new FileReader();
        reader.onload = () => {
          state.petCustomPhoto = reader.result;
          state.petActiveId = "custom";
          state.petBotBindings[state.petActiveBotKey] = "custom";
          emitHaptic("confirm", "导入自定义宠物立绘");
          showToast("已导入自定义图片（带轻量呼吸动效）");
          renderAll();
        };
        reader.readAsDataURL(f);
      };
    }
    const togBreathe = document.getElementById("btnToggleCustomBreathe");
    if (togBreathe) togBreathe.onclick = () => { state.petCustomBreathe = !state.petCustomBreathe; emitHaptic("selection", "切单图呼吸动画"); renderAll(); };

    scroller.querySelectorAll("[data-pet-mood]").forEach((btn) => {
      btn.onclick = () => {
        emitHaptic("pet", `切换${activePetDisplayName()}状态: ${btn.dataset.petMood}`);
        setPetMood(btn.dataset.petMood, ["attention", "error", "waking"].includes(btn.dataset.petMood) ? 2600 : 0);
        renderAll();
      };
    });
    const swFollow = document.getElementById("swFollowPet");
    if (swFollow) swFollow.onclick = () => {
      state.assistant.followPet = !state.assistant.followPet;
      state.assistant.avatarMode = state.assistant.followPet ? "followPet" : (state.assistant.avatarPhoto ? "photo" : "monogram");
      emitHaptic("selection", state.assistant.followPet ? "助手头像联动宠物" : "助手头像松绑独立");
      showToast(state.assistant.followPet ? "助手头像跟随伴读宠物" : "已解耦：可点击正文头像单独设置");
      renderAll();
    };
    const btnSizeR = document.getElementById("btnPetSizeRuler");
    if (btnSizeR) btnSizeR.onclick = () => { emitHaptic("silent", "打开宠物 StopRuler"); state.stopPickerKind = "petSize"; renderModalLayer(); };
    const swVis = document.getElementById("swPetVisible");
    if (swVis) swVis.onclick = () => {
      state.petVisible = !state.petVisible;
      state.petSnoozeUntil = null;
      emitHaptic("selection", `立宠显隐 → ${state.petVisible ? "显示" : "隐藏"}`);
      renderAll();
    };
    const bSnooze = document.getElementById("btnPetSnooze");
    if (bSnooze) bSnooze.onclick = () => {
      if (state.petSnoozeUntil && state.petSnoozeUntil > Date.now()) {
        state.petSnoozeUntil = null;
        emitHaptic("pet", "提前叫醒立宠");
        showToast("已回到输入框上沿");
      } else {
        state.petSnoozeUntil = Date.now() + 3600 * 1000;
        state.petBubble = null;
        emitHaptic("light", "收起立宠 1 小时");
        showToast("先歇 1 小时（正文头像不受影响）");
      }
      renderAll();
    };
    const bBubble = document.getElementById("btnTriggerPetBubble");
    if (bBubble) bBubble.onclick = () => {
      if (!isPetVisibleNow()) { showToast("立宠已收起，只影响输入框上沿"); return; }
      if (state.petActivity === "lively") {
        emitHaptic("pet", "跨对话冒泡");
        state.petBubble = { chat: "memory", text: "架构师：已整理 2 条设计原则" };
        renderBottomDock();
      } else {
        emitHaptic("silent", "安静/极简模式下不主动冒泡");
        showToast(`当前为「${state.petActivity === "quiet" ? "安静" : "极简"}」模式，仅做动作不冒泡打扰`);
      }
    };
    scroller.querySelectorAll("[data-pet-activity]").forEach((btn) => {
      btn.onclick = () => {
        state.petActivity = btn.dataset.petActivity;
        if (state.petActivity !== "lively") state.petBubble = null;
        emitHaptic("selection", `互动活跃度 → ${state.petActivity}`);
        renderAll();
      };
    });
    scroller.querySelectorAll("[data-pet-bot]").forEach((btn) => {
      btn.onclick = () => {
        state.petActiveBotKey = btn.dataset.petBot;
        state.petActiveId = state.petBotBindings[state.petActiveBotKey] || "xiaoke";
        emitHaptic("selection", `切换按助手绑定宠物 → ${activePetDisplayName()}`);
        showToast(`已切至 ${state.petActiveBotKey === "architect" ? "架构师" : state.assistant.name} 对话 · 立宠同步为 ${activePetDisplayName()}`);
        renderAll();
      };
    });
  }

  // ==================== Scene 2: Onboarding (4 Steps), Desk Home, Empty Chat ====================
  function renderOnboardingHomeScene(scroller) {
    const subNav = `
      <div class="pill-row">
        <button type="button" class="filter-pill ${state.onboardSub === "onboard" ? "active" : ""}" data-oh-sub="onboard">首次引导 (4页)</button>
        <button type="button" class="filter-pill ${state.onboardSub === "home" ? "active" : ""}" data-oh-sub="home">桌面首页 (Home)</button>
        <button type="button" class="filter-pill ${state.onboardSub === "empty" ? "active" : ""}" data-oh-sub="empty">空对话 (题词)</button>
      </div>
    `;

    let body = "";
    if (state.onboardSub === "onboard") {
      const steps = [
        { title: "私人的个人代理，留在你自己的手机上", sub: "密钥存在 iOS 钥匙串 Vault，笔记、对话与四层记忆全是本地 SQLite，不上传私有服务器。" },
        { title: "会读文件、跑终端，也会敲网页", sub: "0.36 只读并发加倍提速；但涉及发信或远程命令行前，必定先问过你的批准单。" },
        { title: "挑一套你一眼能看懂的称谓习惯", sub: "支持随时 1 键互切日常直白与书卷雅称；开启书卷时默认展示温和的日常小字旁注。" },
        { title: "现在就连接你的第一个模型服务吧", sub: "兼容 OpenAI / Anthropic / DeepSeek / Ollama；也可先进入真实示例桌台逛一逛。" }
      ];
      const cur = steps[state.onboardStep];
      body = `
        <div class="clio-card" style="padding:18px 16px; text-align:center;">
          <canvas id="emptyPetCanvas" data-pet-canvas="1" width="48" height="48" style="width:74px;height:74px;image-rendering:pixelated;margin:0 auto 10px;"></canvas>
          <div class="font-mark" style="font-size:19px; font-weight:700; margin-bottom:7px; text-align:left;">${cur.title}</div>
          <div class="font-reading" style="font-size:13.5px; color:var(--ink-secondary); text-align:left; margin-bottom:14px;">${cur.sub}</div>
          ${state.onboardStep === 2 ? `
            <div style="display:grid; grid-template-columns:1fr 1fr; gap:8px; margin-bottom:14px;">
              <button type="button" class="clio-inner-block" style="padding:10px; border:2px solid ${state.tone === "daily" ? "var(--accent)" : "var(--rule)"}; cursor:pointer; text-align:left;" id="obPickDaily">
                <div style="font-weight:700; font-size:13.5px; margin-bottom:3px;">日常直白</div>
                <div style="font-size:11.5px; color:var(--ink-secondary);">首页 · 记忆 · 设置 · 终端</div>
              </button>
              <button type="button" class="clio-inner-block" style="padding:10px; border:2px solid ${state.tone === "literary" ? "var(--accent)" : "var(--rule)"}; cursor:pointer; text-align:left;" id="obPickLit">
                <div style="font-weight:700; font-size:13.5px; margin-bottom:3px;" class="font-mark">书卷雅称</div>
                <div style="font-size:11.5px; color:var(--ink-secondary);">窗前 · 拾遗 · 调弦 · 斗室</div>
              </button>
            </div>
          ` : ""}
          <div style="display:flex; justify-content:center; gap:6px; margin-bottom:14px;">
            ${[0, 1, 2, 3].map((i) => `<span style="height:6px; width:${i === state.onboardStep ? "18px" : "6px"}; border-radius:999px; background:${i === state.onboardStep ? "var(--accent)" : "var(--rule)"}; transition:all 200ms;"></span>`).join("")}
          </div>
          <button type="button" class="filter-pill active" style="width:100%; padding:10px;" id="obNextStep">${state.onboardStep < 3 ? "继续下一页" : "连接模型（或进入桌台）"}</button>
        </div>
      `;
    } else if (state.onboardSub === "home") {
      body = `
        <div style="display:flex; align-items:flex-end; justify-content:space-between; margin-bottom:12px;">
          <div>
            <div class="font-mark" style="font-size:21px; font-weight:700;">晚上好</div>
            <div style="font-size:13px; color:var(--ink-secondary);">今天想理顺哪件事？</div>
          </div>
          <button type="button" class="filter-pill active" id="homeQuickSearch">🔍 全域搜索</button>
        </div>
        <div style="display:flex; gap:8px; overflow-x:auto; padding-bottom:6px; margin-bottom:10px;">
          <button type="button" class="filter-pill active" data-home-go="chat">🐾 ${escHtml(state.assistant.name)}（默认助手）</button>
          <button type="button" class="filter-pill" data-home-go="memory">❖ 架构师名帖</button>
        </div>
        <div class="clio-card" style="padding:12px 13px; margin-bottom:10px; border-left:3px solid var(--warn);" data-home-go="approval">
          <div style="display:flex; justify-content:space-between; align-items:center;">
            <strong style="font-size:13.5px;">⛨ ${escHtml(state.assistant.name)}在等你${t("approvalSheet")}</strong>
            <span style="font-size:12px; color:var(--accent); font-weight:600;">去看看 ›</span>
          </div>
          <div style="font-size:12px; color:var(--ink-secondary); margin-top:3px;">ssh_run：Prod-CN2 重新载入 nginx（读过外网）</div>
        </div>
        <div class="clio-card" style="padding:12px 13px; margin-bottom:12px;">
          <div style="font-size:11.5px; color:var(--accent); font-weight:600; margin-bottom:3px;">✉ 晨信简报 · 07:30 已生成</div>
          <div style="font-size:12.5px; color:var(--ink-secondary); line-height:1.45;">昨晚已整理 2 条新记忆进入「近期」，设计系统 2.0 全部对比度已核对通过。</div>
        </div>
        <div class="section-title">${t("conversations")}（去重整洁流）</div>
        <div class="row-card">
          <button type="button" class="row-item pressable" data-home-go="chat"><span class="status-dot busy"></span><div style="flex:1;"><div>${escHtml(state.assistant.name)} · 0.36 发布前体检</div><div style="font-size:11.5px; color:var(--ink-secondary);">已生成 18 种 Markdown 与对比表</div></div><span style="font-size:11px; color:var(--ink-tertiary);">刚刚</span></button>
          <button type="button" class="row-item pressable" data-home-go="tools"><span class="status-dot"></span><div style="flex:1;"><div>120Hz 聊天瓦片优化</div><div style="font-size:11.5px; color:var(--ink-secondary);">并发工具与 PlanReveal 零跳测验</div></div><span style="font-size:11px; color:var(--ink-tertiary);">昨天</span></button>
        </div>
      `;
    } else {
      body = `
        <div class="state-empty-box" style="min-height:420px;">
          <canvas id="emptyPetCanvas" data-pet-canvas="1" width="48" height="48" style="width:66px;height:66px;image-rendering:pixelated;margin-bottom:10px;"></canvas>
          <div class="font-mark" style="font-size:21px; font-weight:700; margin-bottom:6px;">
            ${(state.lang === "A" || state.lang === "AC") ? "案头纸清，静候开口" : (state.lang === "B" ? "Clio Ready · 等待任务输入" : "微风正好，随时开始聊聊")}
          </div>
          <div style="font-size:12.5px; color:var(--ink-secondary); max-width:255px; margin-bottom:16px; line-height:1.5;">
            常用问题点一下直接发给 ${escHtml(state.assistant.name)}（支持实时 15Hz 流式响应）
          </div>
          <div style="display:flex; flex-direction:column; gap:8px; width:100%; max-width:280px;">
            <button type="button" class="clio-card" style="padding:10px 13px; text-align:left; font-size:13px; cursor:pointer;" data-starter="帮我查书案里的 PDF 找出 Liquid Glass 红线">📄 检索书案里的 PDF：查 Liquid Glass 红线</button>
            <button type="button" class="clio-card" style="padding:10px 13px; text-align:left; font-size:13px; cursor:pointer;" data-starter="在远山 Prod-CN2 检查 nginx 配置文件合法性">⌘ 在远山检查 Nginx 配置并呈交审批单</button>
          </div>
        </div>
      `;
    }

    scroller.innerHTML = subNav + body;
    scroller.querySelectorAll("[data-oh-sub]").forEach((b) => {
      b.onclick = () => { emitHaptic("silent", "切换引导/首页子视图"); state.onboardSub = b.dataset.ohSub; renderViewport({ resetScroll: true }); };
    });
    const obDaily = scroller.querySelector("#obPickDaily");
    const obLit = scroller.querySelector("#obPickLit");
    if (obDaily) obDaily.onclick = () => { state.tone = "daily"; emitHaptic("selection", "选择日常词典"); renderAll(); };
    if (obLit) obLit.onclick = () => { state.tone = "literary"; emitHaptic("selection", "选择书卷词典"); renderAll(); };
    const obNext = scroller.querySelector("#obNextStep");
    if (obNext) obNext.onclick = () => {
      if (state.onboardStep < 3) { state.onboardStep += 1; emitHaptic("silent", "引导下一页"); renderViewport(); }
      else { state.onboardStep = 0; state.onboardSub = "home"; emitHaptic("confirm", "完成引导进入首页"); renderViewport(); }
    };
    const qS = scroller.querySelector("#homeQuickSearch");
    if (qS) qS.onclick = () => switchScene("search");
    scroller.querySelectorAll("[data-home-go]").forEach((el) => {
      el.onclick = () => { emitHaptic("silent", "从首页进入"); switchScene(el.dataset.homeGo); };
    });
    scroller.querySelectorAll("[data-starter]").forEach((btn) => {
      btn.onclick = () => sendUserMessage(btn.dataset.starter);
    });
  }

  // ==================== Scene 4: Tools (0.36 Concurrency + 7-State Semantics + PlanCard) ====================
  function renderToolsScene(scroller) {
    const scenarios = {
      pending: { steps: [{ name: "web_search", status: "pending", ms: "排队中" }, { name: "read_file", status: "pending", ms: "排队中" }], note: "尚未开始执行" },
      running: { steps: [{ name: "web_search", status: "running", ms: "进行中" }, { name: "read_file", status: "succeeded", ms: "0.08s" }], note: "顶栏仅示「沉吟」，此处显真实步骤，底栏不重复挂状态卡" },
      succeeded: { steps: [{ name: "read_file", status: "succeeded", ms: "0.08s" }, { name: "pdf_fts_search", status: "succeeded", ms: "0.21s" }, { name: "webdav_probe", status: "succeeded", ms: "0.33s" }], note: "全部步骤真实成功才显示绿色 ✓" },
      partial: { steps: [{ name: "read_file", status: "succeeded", ms: "0.08s" }, { name: "pdf_fts_search", status: "succeeded", ms: "0.21s" }, { name: "web_search", status: "failed", ms: "超时" }], note: "3 项中 1 项失败 → 聚合标黄 △「部分成功」" },
      failed: { steps: [{ name: "web_search · Bing", status: "failed", ms: "拦截/超时" }, { name: "web_search · DDG", status: "failed", ms: "1.80s 失败" }], note: "修复旧 BUG：搜索失败时绝不能亮绿色 ✓ 完成" },
      cancelled: { steps: [{ name: "shell · npm test", status: "cancelled", ms: "已停下" }], note: "用户主动停止，保留已输出日志" },
      waiting_approval: { steps: [{ name: "web_read", status: "succeeded", ms: "0.42s" }, { name: "ssh_run", status: "pending", ms: "候印中" }], note: "读过外网触发写操作 → 高优抬升到批准单" }
    };
    const cur = scenarios[state.toolDemoState] || scenarios.partial;
    const aggKey = resolveToolAggregateStatus(cur.steps, { waitingApproval: state.toolDemoState === "waiting_approval" });
    const meta = (TOKENS.toolStatuses7 || []).find((x) => x.key === aggKey) || { key: aggKey, icon: "●", label: aggKey };
    const statusPills = (TOKENS.toolStatuses7 || []).map((st) => `
      <button type="button" class="filter-pill ${state.toolDemoState === st.key ? "active" : ""}" style="font-size:11px; padding:3px 9px;" data-tool-demo="${st.key}">${st.icon} ${st.label}</button>
    `).join("");

    const stepBadgeChar = (s) => s === "succeeded" ? "✓" : (s === "failed" ? "✕" : (s === "running" ? "◐" : (s === "cancelled" ? "■" : "○")));
    const stepBadgeCls = (s) => s === "succeeded" ? "ok" : (s === "failed" ? "fail" : "doing");
    const railBorder = (color) => ((state.lang === "B" || state.lang === "AC") ? `border-left: 2.5px solid ${color};` : "");

    scroller.innerHTML = `
      <div class="msg-user-wrap"><div class="msg-user-bubble">演示 7 态工具执行语义（修复搜索失败却误亮绿色完成 ✓ 的缺陷）</div></div>
      <div class="msg-assistant">
        <div class="clio-card" style="padding:10px 12px; margin-bottom:4px;">
          <div style="font-size:11.5px; color:var(--ink-secondary); margin-bottom:6px;">切换工具执行终态对照（禁止把“跑完了”直接画成绿色成功）：</div>
          <div style="display:flex; gap:5px; flex-wrap:wrap;">${statusPills}</div>
        </div>

        <div class="thinking-box" style="${railBorder("var(--ink-tertiary)")}">
          <button type="button" class="thinking-toggle" id="btnToggleThink">
            <span>✦ 已${t("thinking")} <span class="font-mono">2.4s</span> · 148 字</span>
            <span>${state.thinkingOpen ? "▾" : "▸"}</span>
          </button>
          ${state.thinkingOpen ? `<div class="thinking-body">1. 按「顶栏只示会话状态 / 正文示步骤详情 / 输入框保发送停止 / Dock 只抬待审批或接管」分工去重。<br>2. ${escHtml(cur.note)}</div>` : ""}
        </div>

        <div class="trace-card" style="${state.lang === "C" ? "border-radius:22px; background:color-mix(in srgb, var(--accent-wash) 42%, var(--surface));" : ""}">
          <button type="button" class="trace-summary" id="btnToggleTrace">
            <span class="tool-state-badge ${escHtml(aggKey)}">${escHtml(meta.icon)} ${escHtml(meta.label)}</span>
            <span style="font-size:12px; color:var(--ink-secondary); overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">${escHtml(cur.note)}</span>
            <span style="margin-left:auto; font-size:11px; color:var(--ink-tertiary);" class="font-mono">${state.traceOpen ? "▾" : "▸"}</span>
          </button>
          ${state.traceOpen ? `
            <div class="trace-steps">
              <div class="concurrency-tag">⚡ 0.36 只读并发组 · 状态严格由子步骤失败数/待批状态推导</div>
              ${cur.steps.map((s) => `
                <div class="trace-step-row">
                  <span class="step-badge ${stepBadgeCls(s.status)}">${stepBadgeChar(s.status)}</span>
                  <span style="${s.status === "failed" ? "color:var(--danger);" : ""}">${escHtml(s.name)}</span>
                  <span class="font-mono" style="font-size:11px; color:${s.status === "failed" ? "var(--danger)" : "var(--ink-tertiary)"};">${escHtml(s.ms)}</span>
                </div>
              `).join("")}
              <div style="display:flex; gap:8px; margin-top:4px; flex-wrap:wrap;">
                <button type="button" class="filter-pill" id="btnOpenDiffFile">查看 Diff 改动卡</button>
                <button type="button" class="filter-pill" id="btnGoAskScene">回答主动提问 (InlineAsk) ›</button>
              </div>
            </div>
          ` : ""}
        </div>
        <div class="font-reading"><p class="prose-p">另外：真机截图中 <span class="inline-code">198.18.0.0/15</span> 代理环境下的 Fake-IP 冲突已独立登记在工程排障栏（不削弱公网 SSRF 防护），不阻塞本次排版与交互定稿。</p></div>
      </div>
    `;
    scroller.querySelectorAll("[data-tool-demo]").forEach((b) => {
      b.onclick = () => { state.toolDemoState = b.dataset.toolDemo; emitHaptic("selection", `工具终态对照 → ${state.toolDemoState}`); renderViewport(); };
    });
    scroller.querySelector("#btnToggleThink").onclick = () => { emitHaptic("silent", "折展思考块"); state.thinkingOpen = !state.thinkingOpen; renderViewport(); };
    scroller.querySelector("#btnToggleTrace").onclick = () => { emitHaptic("silent", "折展工具轨迹"); state.traceOpen = !state.traceOpen; renderViewport(); };
    const bDiff = scroller.querySelector("#btnOpenDiffFile");
    if (bDiff) bDiff.onclick = () => { state.previewFile = "diff"; switchScene("files"); renderModalLayer(); };
    const bAsk = scroller.querySelector("#btnGoAskScene");
    if (bAsk) bAsk.onclick = () => switchScene("ask");
  }

  // ==================== Scene 5: InlineAsk (0.36 Non-Secret In-Chat Question Card) ====================
  function renderInlineAskScene(scroller) {
    const scopes = ["Prod-CN2", "Staging-HK", "仅本地沙箱生成"];
    const checks = [
      { key: "wcag", label: "WCAG AA 自动对账" },
      { key: "nginx", label: "Nginx 语法校验" },
      { key: "webdav", label: "WebDAV 自动上传" }
    ];
    const atLimit = state.askChecks.length >= 2;

    scroller.innerHTML = `
      <div class="msg-user-wrap"><div class="msg-user-bubble">准备跑发布前验证，有什么要我确认范围的直接问我。</div></div>
      <div class="clio-card" style="padding:14px; display:flex; flex-direction:column; gap:11px;">
        <div style="display:flex; align-items:center; gap:7px;">
          <span style="color:var(--accent); font-size:16px;">❖</span>
          <strong style="font-size:14.5px;">${escHtml(state.assistant.name)}想请教一个非涉密问题</strong>
          <span class="font-mono" style="margin-left:auto; font-size:10.5px; color:var(--ink-tertiary);">InlineAsk · 0.36</span>
        </div>
        <div style="font-size:12px; color:var(--ink-secondary); line-height:1.45;">选定验证环境与检查项后立即开跑（涉密口令仍严守隔离规则，绝对不进此卡）。</div>

        <div>
          <div style="font-size:12px; font-weight:600; margin-bottom:6px;">1. 目标运行环境（单选）</div>
          <div style="display:flex; gap:6px; flex-wrap:wrap;">
            ${scopes.map((s) => `<button type="button" class="filter-pill ${state.askScope === s ? "active" : ""}" data-ask-scope="${s}">${s}</button>`).join("")}
          </div>
        </div>

        <div>
          <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:6px;">
            <span style="font-size:12px; font-weight:600;">2. 校验项目（多选，最多 2 项）</span>
            <span class="filter-pill" style="font-size:10.5px; padding:1px 8px; ${atLimit ? "border-color:var(--warn); color:var(--warn);" : ""}">${state.askChecks.length}/2 已选</span>
          </div>
          <div style="display:flex; gap:6px; flex-wrap:wrap;">
            ${checks.map((c) => {
              const on = state.askChecks.includes(c.key);
              return `<button type="button" class="filter-pill ${on ? "active" : ""}" data-ask-chk="${c.key}">${on ? "✓ " : ""}${c.label}</button>`;
            }).join("")}
            <button type="button" class="filter-pill ${state.askCustomOpen ? "active" : ""}" id="btnAskCustomToggle">＋ 补充说明</button>
          </div>
          ${state.askCustomOpen ? `<input class="settings-search" id="askCustomInput" style="width:100%; margin:8px 0 0; border-radius:12px;" placeholder="补充额外约束条件…" value="${escHtml(state.askCustomText)}" />` : ""}
        </div>

        <div style="background:var(--surface-subtle); border-radius:var(--r-inner); padding:8px 10px; font-size:11.5px; color:var(--ink-secondary);">
          🔒 <strong>涉密隔离边界：</strong>检测到需要 SSH 私钥或 WebDAV 口令时，系统自动隐藏此处输入框并改弹加密 <span class="inline-code">FormSheet</span> 钥匙串表单。
        </div>

        <div style="display:flex; justify-content:space-between; align-items:center; border-top:0.5px solid var(--rule); padding-top:9px;">
          <button type="button" class="reply-action-btn" id="btnAskCancel">取消</button>
          ${state.askSubmitted
            ? `<button type="button" class="filter-pill" id="btnAskReset">✓ 已回传给 ${escHtml(state.assistant.name)} · 重测</button>`
            : `<button type="button" class="filter-pill active" id="btnAskSubmit">提交回答，继续运行</button>`}
        </div>
      </div>
    `;

    scroller.querySelectorAll("[data-ask-scope]").forEach((b) => {
      b.onclick = () => { emitHaptic("selection", `切换范围: ${b.dataset.askScope}`); state.askScope = b.dataset.askScope; state.askSubmitted = false; renderViewport(); };
    });
    scroller.querySelectorAll("[data-ask-chk]").forEach((b) => {
      b.onclick = () => {
        const k = b.dataset.askChk;
        if (state.askChecks.includes(k)) {
          state.askChecks = state.askChecks.filter((x) => x !== k);
          emitHaptic("selection", "取消勾选项");
        } else if (state.askChecks.length < 2) {
          state.askChecks.push(k);
          emitHaptic("selection", "勾选项");
        } else {
          emitHaptic("alert", "超出多选上限 (最多2项)");
          showToast("最多同时勾选 2 项");
        }
        state.askSubmitted = false;
        renderViewport();
      };
    });
    const cusT = scroller.querySelector("#btnAskCustomToggle");
    if (cusT) cusT.onclick = () => { state.askCustomOpen = !state.askCustomOpen; renderViewport(); };
    const cusIn = scroller.querySelector("#askCustomInput");
    if (cusIn) cusIn.oninput = (e) => { state.askCustomText = e.target.value; };
    const cBtn = scroller.querySelector("#btnAskCancel");
    if (cBtn) cBtn.onclick = () => { emitHaptic("silent", "取消 InlineAsk"); switchScene("chat"); };
    const sBtn = scroller.querySelector("#btnAskSubmit");
    if (sBtn) sBtn.onclick = () => { emitHaptic("confirm", "提交 InlineAsk 回答"); state.askSubmitted = true; showToast("已回传非密表单结果"); renderViewport(); };
    const rBtn = scroller.querySelector("#btnAskReset");
    if (rBtn) rBtn.onclick = () => { state.askSubmitted = false; renderViewport(); };
  }

  // ==================== Scene 6: Approval Suite ====================
  function renderApprovalScene(scroller) {
    const statusMap = {
      pending: "",
      once: `<div style="color:var(--ok); font-weight:600; font-size:13px;">✓ 已准许本次执行</div>`,
      trust: `<div style="color:var(--ok); font-weight:600; font-size:13px;">✓ 本对话已知风险放行</div>`,
      rejected: `<div style="color:var(--danger); font-weight:600; font-size:13px;">✕ 已${t("rejectBtn")}该操作</div>`
    };

    scroller.innerHTML = `
      <div class="msg-user-wrap"><div class="msg-user-bubble">把刚刚拉回来的网页数据整理进 Prod-CN2 Nginx 配置并重载</div></div>
      <div class="clio-card inline-approval" style="${state.lang === "B" ? "border-left: 3px solid var(--warn);" : ""}">
        <div style="display:flex; align-items:center; justify-content:space-between; gap:8px;">
          <span style="font-weight:600; font-size:14.5px;">⛨ ${escHtml(state.assistant.name)}这一步需要你确认</span>
          <button type="button" class="filter-pill active" id="btnOpenFullApproval" style="padding:4px 11px; font-size:11.5px;">展开全屏${t("approvalSheet")} ⤢</button>
        </div>
        <div class="taint-banner"><span>⚠</span><span>${t("webWarn")}（三重冗余编码：色 + 盾 + 文）</span></div>
        <div class="clio-inner-block" style="padding:9px 11px;">
          <div style="display:flex; justify-content:space-between; font-size:11.5px; color:var(--ink-secondary); margin-bottom:4px;">
            <span>目标环境：<strong style="color:var(--ink);">远山 · Prod-CN2</strong></span>
            <span class="font-mono">ssh_run</span>
          </div>
          <pre class="code-pre" style="padding:4px 0 0;">cp /tmp/parsed.conf /etc/nginx/conf.d/site.conf && nginx -t && systemctl reload nginx</pre>
        </div>
        ${state.inlineApprovalStatus === "pending" ? `
          <div style="display:flex; gap:8px; justify-content:flex-end; margin-top:4px; flex-wrap:wrap;">
            <button type="button" class="filter-pill" id="btnInlineReject">${t("rejectBtn")}</button>
            <button type="button" class="filter-pill" id="btnInlineTrust" style="color:var(--warn);">已知风险放行</button>
            <button type="button" class="filter-pill active" id="btnInlineOnce">${t("approveOnce")}</button>
          </div>
        ` : `
          <div style="display:flex; align-items:center; justify-content:space-between;">
            ${statusMap[state.inlineApprovalStatus]}
            <button type="button" class="filter-pill" id="btnResetApproval">重置演示</button>
          </div>
        `}
      </div>
    `;
    scroller.querySelector("#btnOpenFullApproval").onclick = () => { emitHaptic("silent", "展开全屏审批单"); state.fullApprovalVerdict = null; state.fullApprovalOpen = true; renderModalLayer(); };
    const bOnce = scroller.querySelector("#btnInlineOnce");
    if (bOnce) bOnce.onclick = () => { emitHaptic("confirm", "就地批准"); state.inlineApprovalStatus = "once"; renderAll(); };
    const bTrust = scroller.querySelector("#btnInlineTrust");
    if (bTrust) bTrust.onclick = () => { emitHaptic("alert", "已知外网风险放行"); state.inlineApprovalStatus = "trust"; renderAll(); };
    const bRej = scroller.querySelector("#btnInlineReject");
    if (bRej) bRej.onclick = () => { emitHaptic("alert", "拒绝操作"); state.inlineApprovalStatus = "rejected"; renderAll(); };
    const bRst = scroller.querySelector("#btnResetApproval");
    if (bRst) bRst.onclick = () => { emitHaptic("silent", "重置审批"); state.inlineApprovalStatus = "pending"; renderAll(); };
  }

  // ==================== Scene 7: Unified Global Search & IA Sidebar ====================
  function renderSearchScene(scroller) {
    function buildSearchResultsHtml() {
      const q = state.globalQuery.trim().toLowerCase();
      const hits = SEARCH_CORPUS.filter((item) => {
        const tabMatch = state.globalTab === "all" || item.type === state.globalTab;
        if (!tabMatch) return false;
        if (!q) return true;
        return item.title.toLowerCase().includes(q) || item.snippet.toLowerCase().includes(q) || item.owner.toLowerCase().includes(q);
      });
      const tabsHtml = `
        <div class="pill-row">
          ${[["all", "全部"], ["chat", "对话 FTS5"], ["memory", "记忆 拾遗"], ["file", "文件 & PDF"]].map(([k, lbl]) => {
            const cnt = SEARCH_CORPUS.filter((x) => (k === "all" || x.type === k) && (!q || x.title.toLowerCase().includes(q) || x.snippet.toLowerCase().includes(q))).length;
            return `<button type="button" class="filter-pill ${state.globalTab === k ? "active" : ""}" data-gs-tab="${k}">${lbl} (${cnt})</button>`;
          }).join("")}
        </div>
      `;
      const listHtml = `
        <div style="display:flex; flex-direction:column; gap:8px;">
          ${hits.length ? hits.map((h) => `
            <button type="button" class="clio-card" style="padding:11px 13px; text-align:left; cursor:pointer;" data-gs-go="${h.target}">
              <div style="display:flex; align-items:center; gap:6px; margin-bottom:3px;">
                <span class="filter-pill" style="font-size:10px; padding:1px 7px; background:var(--accent-wash); color:var(--accent); border-color:transparent;">${h.type === "chat" ? "对话" : (h.type === "memory" ? "记忆" : "文件/PDF")}</span>
                <strong style="font-size:13.5px;">${escHtml(h.title)}</strong>
                <span style="margin-left:auto; font-size:10.5px; color:var(--ink-tertiary);">直达 ›</span>
              </div>
              <div style="font-size:11px; color:var(--ink-tertiary); margin-bottom:3px;">${escHtml(h.owner)}</div>
              <div style="font-size:12.5px; color:var(--ink-secondary); line-height:1.45;">${escHtml(h.snippet)}</div>
            </button>
          `).join("") : `<div class="clio-card" style="padding:20px; text-align:center; font-size:13px; color:var(--ink-secondary);">在三大检索库里都没有找到「${escHtml(state.globalQuery)}」</div>`}
        </div>
      `;
      return tabsHtml + listHtml;
    }

    function refreshSearchResults() {
      const wrap = scroller.querySelector("#globalResultsWrap");
      if (!wrap) return;
      wrap.innerHTML = buildSearchResultsHtml();
      const clr = scroller.querySelector("#btnClearGlobalQ");
      if (clr) clr.style.display = state.globalQuery ? "inline-block" : "none";
      wrap.querySelectorAll("[data-gs-tab]").forEach((b) => { b.onclick = () => { emitHaptic("selection", "切搜索范围"); state.globalTab = b.dataset.gsTab; refreshSearchResults(); }; });
      wrap.querySelectorAll("[data-gs-go]").forEach((b) => { b.onclick = () => { emitHaptic("silent", "从搜索结果直达"); switchScene(b.dataset.gsGo); }; });
    }

    scroller.innerHTML = `
      <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:9px;">
        <span style="font-size:20px; font-weight:700;" class="font-mark">全局统一搜索</span>
        <button type="button" class="filter-pill active" id="btnPreviewNewSidebar">☰ 拉出重构侧栏 IA</button>
      </div>
      <div class="privacy-strip">
        <span>⛨</span>
        <span><strong>权限隔离：</strong>仅限本人主动搜索；永不索引密码匣，删除记忆同事务剔除 FTS5，撤销挂载目录实时清理，绝不对 Agent 静默开放。</span>
      </div>
      <div class="settings-search">
        <span style="opacity:0.6;">🔍</span>
        <input id="globalSearchInput" placeholder="跨 对话 · 四层记忆 · 文件/PDF FTS5 同步检索（支持中文拼音）" value="${escHtml(state.globalQuery)}" />
        <button type="button" id="btnClearGlobalQ" style="border:0;background:transparent;color:var(--ink-tertiary);cursor:pointer;display:${state.globalQuery ? "inline-block" : "none"};">✕</button>
      </div>
      <div id="globalResultsWrap"></div>
    `;
    scroller.querySelector("#btnPreviewNewSidebar").onclick = () => { emitHaptic("silent", "打开重构后侧栏 IA"); state.sidebarOpen = true; renderModalLayer(); };
    const gIn = scroller.querySelector("#globalSearchInput");
    attachImeSafeInput(gIn, (val) => { state.globalQuery = val; refreshSearchResults(); });
    const cBtn = scroller.querySelector("#btnClearGlobalQ");
    if (cBtn) cBtn.onclick = () => { state.globalQuery = ""; if (gIn) { gIn.value = ""; gIn.focus(); } refreshSearchResults(); };
    refreshSearchResults();
  }

  // ==================== Scene 8: Models & 4-Role Allocation ====================
  function renderModelsScene(scroller) {
    scroller.innerHTML = `
      <div style="font-size:20px; font-weight:700; margin-bottom:9px;" class="font-mark">${t("modelsTitle")}</div>
      <div class="section-title">即时切换当前会话模型 · 顶栏示简称，此页与选单示完整 Model ID</div>
      <div class="row-card">
        ${MODEL_CATALOG.map((m) => {
          const picked = state.activeModel.code === m.code;
          return `
            <button type="button" class="row-item pressable" data-pick-model="${m.code}">
              <span class="vendor-badge" style="width:28px;height:28px;font-size:12px;">${m.vendor[0]}<span class="vendor-sub">${m.sub}</span></span>
              <div style="flex:1; min-width:0;">
                <div style="display:flex; gap:6px; align-items:center;"><strong style="font-size:13.5px;">${escHtml(m.shortName || resolveShortModelName(m.code))}</strong><span class="filter-pill" style="font-size:10px; padding:1px 6px;">${m.role}</span></div>
                <div class="font-mono" style="font-size:11px; color:var(--ink-secondary); overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">${escHtml(m.code)}</div>
                <div style="font-size:11px; color:var(--ink-tertiary);">${m.note}</div>
              </div>
              <span style="font-size:12px; font-weight:600; color:${picked ? "var(--accent)" : "var(--ink-tertiary)"};">${picked ? "✓ 当前" : "切换"}</span>
            </button>
          `;
        }).join("")}
      </div>

      <div class="section-title">已探测思考深度（触发 Selection 触觉）</div>
      <div class="clio-card" style="padding:11px 13px; display:flex; gap:7px; flex-wrap:wrap;">
        ${["关闭", "低", "中", "高", "自动"].map((lvl) => `<button type="button" class="filter-pill ${state.activeModel.thinking === lvl ? "active" : ""}" data-pick-think="${lvl}">${lvl}</button>`).join("")}
      </div>
    `;
    scroller.querySelectorAll("[data-pick-model]").forEach((b) => {
      b.onclick = () => {
        const found = MODEL_CATALOG.find((x) => x.code === b.dataset.pickModel);
        if (found) { state.activeModel = { ...found }; emitHaptic("selection", `切换模型 ${found.code}`); showToast(`已切为 ${found.code}（仅本对话）`); renderAll(); }
      };
    });
    scroller.querySelectorAll("[data-pick-think]").forEach((b) => {
      b.onclick = () => { state.activeModel.thinking = b.dataset.pickThink; emitHaptic("selection", `思考档 ${b.dataset.pickThink}`); renderAll(); };
    });
  }

  // ==================== Scene 9: Files & PDF FTS5 Knowledge Base ====================
  function renderFilesScene(scroller) {
    const allFiles = [
      { id: "md", name: "设计系统2.0结论.md", meta: "本地 · 18.4 KB · 刚刚", tag: "Markdown", mount: false },
      { id: "html", name: "对比度与性能看板.html", meta: "本地 · 离线互动预览 · 12.1 KB", tag: "HTML 沙箱", mount: false },
      { id: "diff", name: "patch-0.36.diff", meta: "本地 · 3 处改动 · 4.8 KB", tag: "Diff", mount: false },
      { id: "pdf", name: "iOS26-HIG-Materials.pdf", meta: "书案资料库 · FTS5 全文已索引 42 页", tag: "PDF · 0.36", mount: false },
      { id: "mount", name: "iCloud / 工作笔记目录", meta: "外部挂载 · Security-Scoped Bookmark 已授权", tag: "已挂载", mount: true }
    ];

    function refreshFilesList() {
      const wrap = scroller.querySelector("#filesResultsWrap");
      if (!wrap) return;
      const q = state.fileQuery.trim().toLowerCase();
      const files = allFiles.filter((f) => !q || f.name.toLowerCase().includes(q) || f.meta.toLowerCase().includes(q));
      wrap.innerHTML = files.length ? `
        <div class="row-card">
          ${files.map((f) => `
            <button type="button" class="row-item pressable" data-open-file="${f.id}">
              <span class="icon-badge" style="background:${f.mount ? "var(--ok)" : "var(--accent)"}; border-radius:calc(28px * ${TOKENS.languages[state.lang].radii.badgeRatio});">${f.mount ? "🔗" : (f.id === "pdf" ? "📑" : (f.id === "html" ? "✦" : "📄"))}</span>
              <div style="flex:1; min-width:0;">
                <div style="font-size:14px; font-weight:600;">${f.name}</div>
                <div style="font-size:11.5px; color:var(--ink-secondary);">${f.meta}</div>
              </div>
              <span class="filter-pill" style="font-size:10.5px; padding:2px 8px;">${f.tag}</span>
            </button>
          `).join("")}
        </div>
      ` : `<div class="clio-card" style="padding:18px; text-align:center; font-size:13px; color:var(--ink-secondary);">未找到匹配「${escHtml(state.fileQuery)}」的书案文档</div>`;
      wrap.querySelectorAll("[data-open-file]").forEach((btn) => {
        btn.onclick = () => { emitHaptic("silent", `打开预览: ${btn.dataset.openFile}`); state.previewFile = btn.dataset.openFile; renderModalLayer(); };
      });
    }

    scroller.innerHTML = `
      <div style="font-size:20px; font-weight:700; margin-bottom:9px;" class="font-mark">${t("files")} ${hintBadge("文件与知识库")}</div>
      <div class="settings-search"><span style="opacity:0.6;">🔍</span><input id="fileSearchInput" placeholder="搜索文件名、PDF 或外部挂载目录" value="${escHtml(state.fileQuery)}" /></div>
      <div id="filesResultsWrap"></div>
    `;
    const fInp = scroller.querySelector("#fileSearchInput");
    attachImeSafeInput(fInp, (val) => { state.fileQuery = val; refreshFilesList(); });
    refreshFilesList();
  }

  // ==================== Scene 10: Browser Roam · Alpine Den · SSH Hills ====================
  function renderRoamDenScene(scroller) {
    const nav = `
      <div class="pill-row">
        <button type="button" class="filter-pill ${state.roamSub === "roam" ? "active" : ""}" data-rd-sub="roam">内置浏览器 Roam</button>
        <button type="button" class="filter-pill ${state.roamSub === "den" ? "active" : ""}" data-rd-sub="den">Alpine 终端</button>
        <button type="button" class="filter-pill ${state.roamSub === "ssh" ? "active" : ""}" data-rd-sub="ssh">SSH 远山主机</button>
      </div>
    `;
    let body = "";
    if (state.roamSub === "roam") {
      body = `
        <div class="clio-card" style="padding:10px 12px; margin-bottom:10px;">
          <div style="display:flex; align-items:center; gap:7px; background:var(--surface-subtle); border-radius:999px; padding:6px 11px; margin-bottom:9px;">
            <span style="font-size:11px; color:var(--ok);">🔒</span>
            <span class="font-mono" style="font-size:11px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; flex:1;">${escHtml(state.roamUrl)}</span>
          </div>
          <div class="font-reading" style="font-size:13.5px; background:var(--surface); padding:8px; border-radius:var(--r-inner); border:0.5px solid var(--rule);">
            <strong>Apple HIG · Materials</strong><br>
            Don't use Liquid Glass in the content layer. Use standard system materials for sheets and controls over content.
          </div>
        </div>
        ${state.roamHandoffActive ? `
          <div class="clio-card" style="padding:11px 13px; border-left:3px solid var(--warn); display:flex; align-items:center; justify-content:space-between; gap:8px;">
            <div>
              <div style="font-size:13px; font-weight:700;">✋ 远游 · 请你手工登录验证</div>
              <div style="font-size:11.5px; color:var(--ink-secondary);">遇到验证码/登录拦截：Clio 红线禁止自动绕过，请本人完成后点右侧继续。</div>
            </div>
            <button type="button" class="filter-pill active" id="btnFinishHandoff">我好了</button>
          </div>
        ` : `<div class="clio-card" style="padding:11px; font-size:12.5px; color:var(--ok);">✓ 已完成手动操作并归还网页上下文给小克（受外网 Taint 保护）。</div>`}
      `;
    } else if (state.roamSub === "den") {
      body = `
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:8px;">
          <div style="font-size:12px; color:var(--ink-secondary); display:flex; align-items:center; gap:5px;">
            <span class="status-dot ${state.denStatus === "running" ? "busy" : ""}"></span>
            <span>${state.denStatus === "running" ? "正在运行命令…" : "Alpine Linux · 就绪"}</span>
          </div>
          ${state.denStatus === "running" ? `<button type="button" class="filter-pill" id="btnDenStop" style="color:var(--danger);">■ 停止</button>` : `<button type="button" class="filter-pill" id="btnDenClear">清空</button>`}
        </div>
        <div class="terminal-box" id="denLogBox">
          ${state.denLogs.map((l) => l.kind === "cmd" ? `<div style="margin-top:6px;"><span style="color:var(--accent); font-weight:700;"># </span><strong>${escHtml(l.text)}</strong></div>` : (l.kind === "note" ? `<div style="color:var(--ink-tertiary);">— ${escHtml(l.text)}</div>` : `<pre style="margin:2px 0; white-space:pre-wrap; font-family:inherit;">${escHtml(l.text)}</pre>`)).join("")}
        </div>
        <div style="display:flex; gap:6px; flex-wrap:wrap; margin-top:8px;">
          ${["ls -la", "uname -a", "df -h", "help"].map((cmd) => `<button type="button" class="filter-pill font-mono" style="font-size:11px;" data-run-cmd="${cmd}">${cmd}</button>`).join("")}
        </div>
      `;
    } else {
      body = `
        <div class="section-title">远程主机（工作台直达 · 点击试连）</div>
        <div class="clio-card" style="padding:13px; margin-bottom:10px;">
          <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:6px;">
            <strong>香港节点 · Prod-CN2</strong>
            <span class="filter-pill" style="font-size:10.5px; color:var(--ok); border-color:var(--ok);">● 24ms 在线</span>
          </div>
          <div class="font-mono" style="font-size:11.5px; color:var(--ink-secondary); margin-bottom:4px;">ops@203.0.113.42:22 · 钥匙登录</div>
          <div class="font-mono" style="font-size:10.5px; color:var(--ink-tertiary);">SHA256: xK9qR...v8Lm (已受信任)</div>
        </div>
        <div class="clio-card" style="padding:13px;">
          <div style="font-size:13px; font-weight:600; margin-bottom:4px;">手机本机公钥（Ed25519）</div>
          <div class="font-mono" style="font-size:10.5px; color:var(--ink-secondary); word-break:break-all; margin-bottom:8px;">ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIClioDeviceKey clio@iphone</div>
          <button type="button" class="filter-pill active" id="btnCopySshKey">${state.sshKeyCopied ? "✓ 公钥已复制" : "一键复制公钥"}</button>
        </div>
      `;
    }

    scroller.innerHTML = nav + body;
    scroller.querySelectorAll("[data-rd-sub]").forEach((b) => { b.onclick = () => { emitHaptic("silent", "切工作台页"); state.roamSub = b.dataset.rdSub; renderViewport({ resetScroll: true }); }; });
    const fBtn = scroller.querySelector("#btnFinishHandoff");
    if (fBtn) fBtn.onclick = () => { emitHaptic("confirm", "归还浏览器控制"); state.roamHandoffActive = false; renderViewport(); };
    const kBtn = scroller.querySelector("#btnCopySshKey");
    if (kBtn) kBtn.onclick = () => { emitHaptic("light", "复制 SSH 公钥"); state.sshKeyCopied = true; renderViewport(); };
    const bClear = scroller.querySelector("#btnDenClear");
    if (bClear) bClear.onclick = () => { state.denLogs = [{ kind: "note", text: "已清空终端输出" }]; renderViewport(); };
    scroller.querySelectorAll("[data-run-cmd]").forEach((btn) => { btn.onclick = () => runTerminalCommand(btn.dataset.runCmd); });
  }

  // ==================== Scene 11: MCP Connectors & Skills ====================
  function renderExtScene(scroller) {
    scroller.innerHTML = `
      <div class="section-title">MCP 连接器（OAuth 与远山自建已打通）</div>
      <div class="row-card">
        <div class="row-item"><span class="icon-badge" style="background:var(--ok);">G</span><div style="flex:1;"><div>Google Workspace (Drive/Gmail)</div><div style="font-size:11.5px; color:var(--ink-secondary);">OAuth 已授权 · 借来 9 件工具</div></div><span class="filter-pill" style="font-size:10.5px; color:var(--ok);">已连接</span></div>
        <div class="row-item"><span class="icon-badge" style="background:var(--accent);">⌥</span><div style="flex:1;"><div>GitHub MCP Server</div><div style="font-size:11.5px; color:var(--ink-secondary);">Read-Only Token · 只读检索</div></div><span class="filter-pill" style="font-size:10.5px; color:var(--ok);">已连接</span></div>
        <div class="row-item"><span class="icon-badge" style="background:#A9772F;">🔗</span><div style="flex:1;"><div>自建 Playwright 浏览器（远山隧道）</div><div style="font-size:11.5px; color:var(--ink-secondary);">经 Prod-CN2 127.0.0.1:8931 映射</div></div><span class="filter-pill" style="font-size:10.5px;">去远山 ›</span></div>
      </div>
      <div class="section-title">技能目录 Skills (书案/技能/*.md)</div>
      <div class="row-card">
        ${state.skills.map((sk) => `
          <button type="button" class="row-item pressable" data-toggle-skill="${sk.id}">
            <span class="icon-badge" style="background:${sk.on ? "var(--accent)" : "var(--ink-tertiary)"};">✦</span>
            <div style="flex:1;"><div class="font-mono" style="font-size:13px; font-weight:600;">${sk.name}</div><div style="font-size:11.5px; color:var(--ink-secondary);">${sk.desc}</div></div>
            <span class="filter-pill ${sk.on ? "active" : ""}" style="font-size:11px;">${sk.on ? "开启" : "停用"}</span>
          </button>
        `).join("")}
      </div>
    `;
    scroller.querySelectorAll("[data-toggle-skill]").forEach((b) => {
      b.onclick = () => {
        const sk = state.skills.find((x) => x.id === b.dataset.toggleSkill);
        if (sk) { sk.on = !sk.on; emitHaptic("selection", `切换技能 ${sk.name}`); renderViewport(); }
      };
    });
  }

  // ==================== Scene 12: 4-Layer Memory & Flip NameCard ====================
  function renderMemoryScene(scroller) {
    const subNav = `
      <div class="pill-row">
        <button type="button" class="filter-pill ${state.memorySub === "layers" ? "active" : ""}" data-mem-sub="layers">${t("memory")} 四层库 ${hintBadge("长期记忆")}</button>
        <button type="button" class="filter-pill ${state.memorySub === "cards" ? "active" : ""}" data-mem-sub="cards">旅伴名帖 · 可翻转</button>
      </div>
    `;
    if (state.memorySub === "cards") {
      scroller.innerHTML = subNav + `
        <div class="clio-card" id="nameCardBox" style="padding:18px; min-height:330px; display:flex; flex-direction:column; justify-content:space-between; cursor:pointer; background:${state.cardFlipped ? "var(--accent-wash)" : "var(--surface)"};">
          ${state.cardFlipped ? `
            <div style="margin:auto; text-align:center;">
              <div class="wordmark-clio" style="font-size:34px; margin-bottom:10px;">Clio</div>
              <div class="clio-seal-stamp" style="margin:0 auto 12px;">${escHtml((state.assistant.sealChar || "克").slice(0, 1))}</div>
              <div style="font-size:12px; color:var(--ink-secondary);">名帖背面 · 分享图卡自动隐藏隐私记忆数字</div>
            </div>
          ` : `
            <div style="text-align:center; padding:8px 0;">
              <div class="chat-avatar-btn lg" style="margin:0 auto;">${renderAvatarMarkup("assistant", 64)}</div>
              <div class="font-mark" style="font-size:22px; font-weight:700; margin-top:8px;">${escHtml(state.assistant.name)}</div>
              <div style="font-size:12px; color:var(--ink-secondary);">${escHtml(state.assistant.subtitle)}</div>
            </div>
            <div style="display:grid; grid-template-columns:1fr 1fr 1fr; border-top:0.5px solid var(--rule); border-bottom:0.5px solid var(--rule); padding:9px 0; text-align:center; font-size:11.5px;">
              <div><div style="color:var(--ink-tertiary);">性格</div><strong>温和清晰</strong></div>
              <div><div style="color:var(--ink-tertiary);">记得</div><strong>${state.memories.length} 件事</strong></div>
              <div><div style="color:var(--ink-tertiary);">模型</div><strong class="font-mono">${state.activeModel.vendor}</strong></div>
            </div>
            <div style="display:flex; justify-content:space-between; align-items:center; font-size:11px; color:var(--ink-tertiary);">
              <span class="wordmark-clio" style="font-size:14px;">Clio · 名帖</span>
              <span>点按卡片翻转查看背面 ↻</span>
            </div>
          `}
        </div>
      `;
      scroller.querySelector("#nameCardBox").onclick = () => { emitHaptic("light", "翻转旅伴名帖"); state.cardFlipped = !state.cardFlipped; renderViewport(); drawAllPetCanvases(performance.now()); };
    } else {
      const filters = [
        { key: "all", label: "全部" }, { key: "pinned", label: t("memoryPinned") },
        { key: "surface", label: t("memorySurface") }, { key: "deep", label: t("memoryDeep") },
        { key: "archived", label: t("memoryArchived") }
      ];
      const items = state.memories.filter((m) => state.memoryFilter === "all" || m.layer === state.memoryFilter);
      scroller.innerHTML = subNav + `
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;">
          <span style="font-size:12px; color:var(--ink-secondary);">已从设置 4 步深处提升至侧栏 1 tap 直达</span>
          <button type="button" class="filter-pill active" id="btnAddMemory">＋ 记一条</button>
        </div>
        <div class="pill-row">
          ${filters.map((f) => `<button type="button" class="filter-pill ${state.memoryFilter === f.key ? "active" : ""}" data-mem-filter="${f.key}">${f.label} ${f.key === "all" ? state.memories.length : state.memories.filter((m) => m.layer === f.key).length}</button>`).join("")}
        </div>
        <div style="display:flex; flex-direction:column; gap:8px;">
          ${items.map((m) => `
            <div class="clio-card" style="padding:11px 13px;">
              <div style="display:flex; align-items:center; gap:6px; margin-bottom:5px; flex-wrap:wrap;">
                <span class="filter-pill" style="font-size:10.5px; padding:1px 8px; background:var(--accent-wash); color:var(--accent); border-color:transparent;">${filters.find((x) => x.key === m.layer)?.label || m.layer}</span>
                <span class="filter-pill" style="font-size:10.5px; padding:1px 8px;">${m.source === "bot" ? `${m.bot} 写入` : "手写受保护"}</span>
                <span style="margin-left:auto; font-size:11px; color:var(--ink-tertiary);">${m.date}</span>
              </div>
              <div style="font-size:13.5px; line-height:1.5; margin-bottom:7px;">${escHtml(m.text)}</div>
              <div style="display:flex; gap:8px;">
                <button type="button" class="filter-pill" style="font-size:11px; padding:3px 9px;" data-mem-promote="${m.id}">${m.layer === "pinned" ? "移回近期" : "设为" + t("memoryPinned")}</button>
                ${m.source === "bot" ? `<button type="button" class="filter-pill" style="font-size:11px; padding:3px 9px; color:var(--danger);" data-mem-undo="${m.id}">撤回</button>` : ""}
              </div>
            </div>
          `).join("")}
        </div>
      `;
      scroller.querySelectorAll("[data-mem-filter]").forEach((b) => { b.onclick = () => { emitHaptic("selection", "切记忆层"); state.memoryFilter = b.dataset.memFilter; renderViewport(); }; });
      scroller.querySelectorAll("[data-mem-promote]").forEach((b) => {
        b.onclick = () => { const it = state.memories.find((x) => x.id === b.dataset.memPromote); if (it) it.layer = it.layer === "pinned" ? "surface" : "pinned"; emitHaptic("detent", "调整记忆优先级"); renderViewport(); };
      });
      scroller.querySelectorAll("[data-mem-undo]").forEach((b) => {
        b.onclick = () => { emitHaptic("alert", "撤回自动记忆"); state.memories = state.memories.filter((x) => x.id !== b.dataset.memUndo); renderViewport(); };
      });
      const addM = scroller.querySelector("#btnAddMemory");
      if (addM) addM.onclick = () => { emitHaptic("light", "手写记忆"); state.memories.unshift({ id: "m" + Date.now(), layer: "surface", kind: "note", text: "新记一条：已自动屏蔽 sk-*** 密钥前缀保护安全", source: "user", date: "刚刚" }); renderViewport(); };
    }
    scroller.querySelectorAll("[data-mem-sub]").forEach((b) => { b.onclick = () => { emitHaptic("silent", "切换记忆/名帖"); state.memorySub = b.dataset.memSub; renderViewport({ resetScroll: true }); drawAllPetCanvases(performance.now()); }; });
  }

  // ==================== Scene 13: Apple-Grade 8+1 Settings Home & 19 Push Sub-Pages ====================
  function getSettingsValueMap() {
    const palText = state.lang === "AC"
      ? TOKENS.languages.AC.palettes[state.acPalette].name
      : TOKENS.languages[state.lang].name;
    const faceMap = { auto: "随主题", serif: "书卷", sans: "苹方", wenkai: "文楷" };
    const hapMap = { off: "关", gentle: "轻柔", standard: "标准", crisp: "清脆" };
    const engMap = { builtin: "内置", brave: "Brave", tavily: "Tavily", searxng: "SearXNG" };
    const preMap = { strict: "严格", balanced: "平衡", auto: "放手", readonly: "仅读" };
    return {
      providers: "3 家已连",
      models_cfg: state.activeModel.code,
      appearance: `${palText} · ${state.tone === "literary" ? "书卷" : "日常"}`,
      typography: `${state.readingSize}pt · ${state.lineHeight}×`,
      motion_haptics: state.reduceMotion ? "减弱动态" : `${hapMap[state.hapticIntensity] || "标准"}触觉`,
      chat_display: `头像${state.showChatFaces ? "开" : "关"} · 思考${state.chatShowThinking ? "开" : "关"}`,
      voice: state.voiceMode === "cloud" ? state.voiceModel : "系统听写",
      memory_rules: `${state.memories.length} 条 · ${state.memAutoRecall ? "自动" : "手动"}`,
      goPet: isPetVisibleNow() ? `${activePetDisplayName()} · ${Math.round(state.petSizeFactor * 100)}%` : "已收起",
      morning: state.morningBriefOn ? `每天 ${state.morningTime}` : "已关闭",
      extensions: `${state.skills.filter((x) => x.on).length} 个技能开启`,
      search_engine: engMap[state.searchEngine] || "内置",
      workspace: "Prod-CN2",
      permissions: `${preMap[state.grantPreset] || "平衡"} · 外网拦`,
      vault: state.vaultUnlocked ? "已暂时解锁" : "Face ID 锁",
      privacy: state.faceIdLockOn ? "面容锁开" : "未设锁",
      notifications: state.liveIslandOn ? "实况 + 通知" : "常规通知",
      backup: "今日已备份",
      usage_diag: "42.4% · 正常",
      about: "0.36 · DS 2.0"
    };
  }

  function renderSettingsScene(scroller) {
    if (state.settingsSub) {
      renderSettingsSubPage(scroller, state.settingsSub);
      drawAllPetCanvases(performance.now());
      return;
    }
    renderSettingsHome(scroller);
    drawAllPetCanvases(performance.now());
  }

  function renderSettingsHome(scroller) {
    function buildSettingsResultsHtml() {
      const q = state.settingsQuery.trim().toLowerCase();
      const valMap = getSettingsValueMap();
      const groupsMap = new Map();
      SETTINGS_CATALOG.forEach((it) => {
        const hit = !q
          || it.title.toLowerCase().includes(q)
          || it.line.toLowerCase().includes(q)
          || it.kw.toLowerCase().includes(q)
          || it.group.toLowerCase().includes(q);
        if (!hit) return;
        if (!groupsMap.has(it.group)) groupsMap.set(it.group, []);
        groupsMap.get(it.group).push(it);
      });

      const heroHtml = q ? "" : `
        <div class="settings-hero-card slim">
          <div class="settings-hero-profiles">
            <button type="button" class="settings-hero-profile-btn" data-edit-identity="assistant">
              <span class="chat-avatar-btn" style="width:34px;height:34px;">${renderAvatarMarkup("assistant", 34)}</span>
              <div style="flex:1; min-width:0;">
                <div style="font-size:13.5px; font-weight:600; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;">${escHtml(state.assistant.name)}</div>
                <div style="font-size:11px; color:var(--ink-tertiary); white-space:nowrap; overflow:hidden; text-overflow:ellipsis;">助手 · ${escHtml((state.assistant.sealChar || "克").slice(0, 1))}印</div>
              </div>
              <span class="settings-chevron">${sfIcon("chevronRight", 12)}</span>
            </button>
            <button type="button" class="settings-hero-profile-btn" data-edit-identity="me">
              <span class="chat-avatar-btn" style="width:34px;height:34px;">${renderAvatarMarkup("me", 34)}</span>
              <div style="flex:1; min-width:0;">
                <div style="font-size:13.5px; font-weight:600; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;">${escHtml(state.userProfile.name)}</div>
                <div style="font-size:11px; color:var(--ink-tertiary); white-space:nowrap; overflow:hidden; text-overflow:ellipsis;">我的头像</div>
              </div>
              <span class="settings-chevron">${sfIcon("chevronRight", 12)}</span>
            </button>
          </div>
        </div>
      `;

      const groupsHtml = Array.from(groupsMap.entries()).map(([gName, items]) => `
        <div class="settings-section-title">${gName}</div>
        <div class="settings-row-card">
          ${items.map((it) => `
            <button type="button" class="settings-row" data-cat-id="${it.id}">
              <span class="sf-badge" style="background:${it.tint};">${sfIcon(it.icon, 15)}</span>
              <span class="settings-row-main">
                <div class="settings-row-title">${it.title}</div>
                ${(q || it.line) ? `<div class="settings-row-sub">${q ? `[${it.group}] ` : ""}${it.line}</div>` : ""}
              </span>
              <span class="settings-row-right">
                <span class="settings-row-val font-mono" id="settingVal-${it.id}">${escHtml(valMap[it.id] || "")}</span>
                <span class="settings-chevron">${sfIcon("chevronRight", 12)}</span>
              </span>
            </button>
          `).join("")}
        </div>
      `).join("");

      const emptyHtml = groupsMap.size === 0
        ? `<div class="clio-card" style="padding:20px; text-align:center; font-size:13px; color:var(--ink-secondary); margin-bottom:14px;">没有匹配「${escHtml(state.settingsQuery)}」的设置项</div>`
        : "";

      return heroHtml + groupsHtml + emptyHtml + `<div class="settings-footer-note">Clio 0.36 · 数据、记忆与钥匙串密码全部留在你自己的手机上</div>`;
    }

    function refreshSettingsResults() {
      const wrap = scroller.querySelector("#settingsResultsWrap");
      if (!wrap) return;
      wrap.innerHTML = buildSettingsResultsHtml();
      const sClr = scroller.querySelector("#btnClearSettingsQ");
      if (sClr) sClr.style.display = state.settingsQuery ? "inline-block" : "none";
      wrap.querySelectorAll("[data-edit-identity]").forEach((b) => { b.onclick = () => openIdentityEditor(b.dataset.editIdentity); });
      wrap.querySelectorAll("[data-cat-id]").forEach((b) => {
        b.onclick = () => {
          const it = SETTINGS_CATALOG.find((x) => x.id === b.dataset.catId);
          if (!it) return;
          if (it.scene) {
            emitHaptic("silent", `进入 ${it.title}`);
            switchScene(it.scene);
          } else if (it.sub) {
            emitHaptic("silent", `Push → ${it.title}`);
            state.settingsSub = it.sub;
            renderViewport({ resetScroll: true });
          }
        };
      });
      drawAllPetCanvases(performance.now());
    }

    scroller.innerHTML = `
      <div class="settings-page-head">
        <div style="font-size:22px; font-weight:700; letter-spacing:-0.01em;" class="font-mark">${t("settings")} ${hintBadge("设置")}</div>
        <span style="font-size:11.5px; color:var(--ink-tertiary);">${state.lang === "AC" ? TOKENS.languages.AC.palettes[state.acPalette].name : TOKENS.languages[state.lang].name}</span>
      </div>
      <div class="settings-search" style="margin-bottom:14px;">
        <span style="opacity:0.55; display:inline-flex;">${sfIcon("globe", 14)}</span>
        <input id="settingsSearchInput" placeholder="搜设置 (行距 · 头像 · 密码 · ssh · 步数)" value="${escHtml(state.settingsQuery)}" />
        <button type="button" id="btnClearSettingsQ" style="border:0;background:transparent;color:var(--ink-tertiary);cursor:pointer;display:${state.settingsQuery ? "inline-block" : "none"};">✕</button>
      </div>
      <div id="settingsResultsWrap"></div>
    `;

    const sInp = scroller.querySelector("#settingsSearchInput");
    attachImeSafeInput(sInp, (val) => { state.settingsQuery = val; refreshSettingsResults(); });
    const sClr = scroller.querySelector("#btnClearSettingsQ");
    if (sClr) sClr.onclick = () => { state.settingsQuery = ""; if (sInp) { sInp.value = ""; sInp.focus(); } refreshSettingsResults(); };
    refreshSettingsResults();
  }

  function renderSettingsSubPage(scroller, subId) {
    const itemMeta = SETTINGS_CATALOG.find((x) => x.sub === subId) || { title: "设置详情", id: subId };
    const rightActionMap = {
      appearance: { id: "btnResetApp", label: "还原默认" },
      typography: { id: "btnResetTypo", label: "还原默认" },
      providers: { id: "btnMockAddProv", label: "＋ 添加" }
    };
    const rAct = rightActionMap[subId];
    const headerNav = `
      <div class="settings-sub-nav">
        <button type="button" class="settings-back-btn" id="btnSettingsBack">${sfIcon("chevronLeft", 13)}<span>${t("settings")}</span></button>
        <div class="settings-sub-title">${escHtml(itemMeta.title)}</div>
        ${rAct ? `<button type="button" class="settings-sub-action" id="${rAct.id}">${rAct.label}</button>` : `<span style="width:48px; flex-shrink:0;"></span>`}
      </div>
    `;

    let body = "";
    if (subId === "appearance") {
      body = `
        <div class="settings-section-title">浅深外观与色彩基准</div>
        <div class="clio-card" style="padding:12px; margin-bottom:14px;">
          <div style="display:flex; gap:6px; margin-bottom:11px;">
            ${[["light", "浅色纸面"], ["dark", "深色夜墨"], ["oled", "OLED 纯黑"]].map(([m, lbl]) => `
              <button type="button" class="filter-pill ${state.mode === m ? "active" : ""}" style="flex:1; text-align:center;" data-sub-mode="${m}">${lbl}</button>
            `).join("")}
          </div>
          <div style="font-size:12px; font-weight:600; color:var(--ink-secondary); margin-bottom:7px;">定稿「素笺·栖息」双头牌主色盘</div>
          <div class="palette-cards-2">
            <button type="button" class="palette-card ${state.lang === "AC" && state.acPalette === "paper_dai" ? "active" : ""}" style="background:#F8F5EE; color:#1F1E1B;" data-pick-ac-pal="paper_dai">
              <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:6px;">
                <strong style="font-size:13px;">素笺黛蓝</strong>
                <span style="width:16px;height:16px;border-radius:4px;background:#B5382A;color:#FBF3EA;font-size:10px;display:inline-flex;align-items:center;justify-content:center;font-family:var(--font-mark);">克</span>
              </div>
              <div style="display:flex; gap:4px; align-items:center;">
                <span style="width:18px;height:18px;border-radius:50%;background:#35587B;"></span>
                <span style="width:18px;height:18px;border-radius:50%;background:#EAE2D3;border:0.5px solid #E2DACB;"></span>
                <span style="font-size:11px; color:#57534A; margin-left:auto;">暖纸黛蓝</span>
              </div>
            </button>
            <button type="button" class="palette-card ${state.lang === "AC" && state.acPalette === "oat_pine" ? "active" : ""}" style="background:#F5F3EE; color:#1E2420;" data-pick-ac-pal="oat_pine">
              <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:6px;">
                <strong style="font-size:13px;">栖息松绿</strong>
                <span style="width:16px;height:16px;border-radius:4px;background:#9A492B;color:#FCFAF6;font-size:10px;display:inline-flex;align-items:center;justify-content:center;font-family:var(--font-mark);">克</span>
              </div>
              <div style="display:flex; gap:4px; align-items:center;">
                <span style="width:18px;height:18px;border-radius:50%;background:#276454;"></span>
                <span style="width:18px;height:18px;border-radius:50%;background:#E3EAE5;border:0.5px solid #DFDAD0;"></span>
                <span style="font-size:11px; color:#4D5750; margin-left:auto;">燕麦松绿</span>
              </div>
            </button>
          </div>
        </div>

        <div class="settings-section-title">语言气质对照与状态光氛</div>
        <div class="row-card" style="margin-bottom:14px;">
          <div class="row-item" style="flex-direction:column; align-items:stretch; gap:7px;">
            <span style="font-size:12.5px; font-weight:600;">设计语言方案</span>
            <div style="display:flex; gap:5px; flex-wrap:wrap;">
              ${[["AC", "定稿 · 素笺栖息"], ["A", "A · 素笺"], ["B", "B · 清器"], ["C", "C · 栖息"]].map(([k, lbl]) => `
                <button type="button" class="filter-pill ${state.lang === k ? "active" : ""}" style="font-size:11.5px;" data-sub-lang="${k}">${lbl}</button>
              `).join("")}
            </div>
          </div>
          <button type="button" class="switch-row" id="swSubAmbientGlow">
            <div style="flex:1; min-width:0;">
              <div style="font-weight:500;">顶底静态状态光氛</div>
              <div style="font-size:11.5px; color:var(--ink-tertiary);">仅在顶/底静态栏极轻微透出任务态（减透明自动变细线）</div>
            </div>
            <span class="ios-switch ${state.ambientGlowOn ? "on" : ""}"></span>
          </button>
        </div>

        <div class="settings-section-title">称谓习惯（日常 / 书卷）</div>
        <div class="row-card">
          <div class="row-item" style="display:grid; grid-template-columns:1fr 1fr; gap:8px;">
            <button type="button" class="clio-inner-block" style="padding:9px 10px; text-align:left; cursor:pointer; border:2px solid ${state.tone === "daily" ? "var(--accent)" : "var(--rule)"};" data-sub-tone="daily">
              <div style="font-weight:700; font-size:13px;">日常直白</div>
              <div style="font-size:11px; color:var(--ink-secondary); margin-top:2px;">首页 · 记忆 · 设置 · 终端</div>
            </button>
            <button type="button" class="clio-inner-block" style="padding:9px 10px; text-align:left; cursor:pointer; border:2px solid ${state.tone === "literary" ? "var(--accent)" : "var(--rule)"};" data-sub-tone="literary">
              <div style="font-weight:700; font-size:13px;" class="font-mark">书卷雅称</div>
              <div style="font-size:11px; color:var(--ink-secondary); margin-top:2px;">窗前 · 拾遗 · 调弦 · 斗室</div>
            </button>
          </div>
          <button type="button" class="switch-row" id="swSubDailyHint">
            <div style="flex:1; min-width:0;">
              <div style="font-weight:500;">书卷模式附带日常旁注</div>
              <div style="font-size:11.5px; color:var(--ink-tertiary);">如「拾遗 (记忆)」，新上手无门槛</div>
            </div>
            <span class="ios-switch ${state.showHintBadge ? "on" : ""}"></span>
          </button>
        </div>
      `;
    } else if (subId === "typography") {
      const hWeights = [["medium", "适中"], ["semibold", "半粗 (推荐)"], ["bold", "粗体"]];
      body = `
        <div class="clio-card" style="padding:12px 13px; margin-bottom:12px;">
          <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:5px;">
            <span style="font-size:11px; color:var(--ink-tertiary);">实时排版小样（与用户气泡 / AI 正文 / 长文共引擎）</span>
            <button type="button" class="filter-pill" id="btnSubOpenFontCompare" style="font-size:10.5px; padding:2px 8px;">Aa 5字体对照</button>
          </div>
          ${renderFontStatusStripHtml()}
          <div class="font-reading" id="typoLiveSample">
            <div class="prose-h3" style="margin:0 0 4px;">Clio 使用 SQLite FTS5 优化长对话</div>
            <p class="prose-p">支持 <span class="inline-code">120 Hz</span> ProMotion（8.33 ms），累计 12,840 Tokens；「中文引号」、“英文混排”、🐱 ≈ ± √。</p>
            <p class="prose-p" style="font-size:calc(var(--effective-reading-size) - 1px); color:var(--ink-secondary);">单一 SafeLineBox（lineSpacing=0）确保切文楷↔苹方基线节奏稳定。</p>
          </div>
        </div>

        <div class="settings-section-title">快速阅读预设（一键起步，可再细调）</div>
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:7px; margin-bottom:14px;">
          ${TOKENS.readingPresets.map((p) => `
            <button type="button" class="clio-card" style="padding:9px 10px; text-align:left; cursor:pointer; border:${state.activeReadingPreset === p.id ? "2px solid var(--accent)" : "0.5px solid var(--rule)"};" data-pick-preset="${p.id}">
              <div style="font-weight:700; font-size:13px;">${p.name}</div>
              <div style="font-size:11px; color:var(--ink-secondary); margin-top:2px;">${p.desc}</div>
            </button>
          `).join("")}
        </div>

        <div class="settings-section-title">正文字体（内部自动光学校准，不暴露复杂滑杆）</div>
        <div class="row-card" style="margin-bottom:14px;">
          ${[["editorial", "书卷默认（New York 英数 + 苹方中文）"], ["sans", "现代无衬线（苹方 / SF Pro）"], ["serif", "传统宋体（STSongti-SC）"], ["wenkai", "Clio Kai（霞鹜文楷 · +4.5% 视觉校准）"]].map(([fKey, fLbl]) => {
            const prof = TOKENS.fontOpticalProfiles[fKey];
            return `
              <button type="button" class="row-item pressable" data-pick-face="${fKey}">
                <span style="flex:1; font-family:${prof.fontCss}; font-size:14.5px;">${fLbl}</span>
                <span style="color:var(--accent); font-weight:700;">${state.readingFace === fKey ? "✓" : ""}</span>
              </button>
            `;
          }).join("")}
        </div>

        <div class="settings-section-title">正文排版与界面缩放（区分正文字号 vs 界面字号）</div>
        <div class="settings-row-card" style="margin-bottom:14px;">
          ${[
            ["size", "正文字号（AI / 用户气泡 / 长文）", `${state.readingSize} 点`],
            ["lineHeight", "正文行距", `${state.lineHeight} 倍`],
            ["paragraphGap", "段落间距", `${state.paragraphGap} 点`],
            ["uiScale", "界面字号与控件缩放", `${Math.round(state.uiScale * 100)}%`]
          ].map(([rKey, rTitle, rVal]) => `
            <button type="button" class="settings-row" data-open-ruler="${rKey}">
              <span class="settings-row-main"><div class="settings-row-title">${rTitle}</div></span>
              <span class="settings-row-right">
                <span class="settings-row-val font-mono" id="settingVal-${rKey}" style="color:var(--accent); font-weight:600;">${rVal} ⇵</span>
              </span>
            </button>
          `).join("")}
        </div>

        <div class="row-card">
          <button type="button" class="disclosure-toggle" data-toggle-disclosure="typoAdvOpen">
            <span>更多版式细调（标题字重 · CLREQ 标点挤压）</span>
            <span>${state.typoAdvOpen ? "▾" : "▸"}</span>
          </button>
          ${state.typoAdvOpen ? `
            <div class="disclosure-body">
              <div class="row-item" style="justify-content:space-between; flex-wrap:wrap; gap:8px;">
                <span style="font-size:13.5px; font-weight:500;">标题字重阶梯</span>
                <div style="display:flex; gap:5px;">
                  ${hWeights.map(([wk, wLbl]) => `<button type="button" class="filter-pill ${state.headingWeight === wk ? "active" : ""}" style="font-size:11.5px; padding:3px 9px;" data-pick-hw="${wk}">${wLbl}</button>`).join("")}
                </div>
              </div>
              <button type="button" class="switch-row" id="swClreq">
                <div style="flex:1; min-width:0;"><div style="font-weight:500;">W3C 中文标点挤压与混排微距</div><div style="font-size:11.5px; color:var(--ink-tertiary);">只作用于视图渲染，复制原文保持纯净；iPad/横屏另显阅读宽度</div></div>
                <span class="ios-switch ${state.clreqSqueeze ? "on" : ""}"></span>
              </button>
            </div>
          ` : ""}
        </div>
      `;
    } else if (subId === "motion_haptics") {
      body = `
        <div class="row-card" style="margin-bottom:14px;">
          <button type="button" class="switch-row" id="swSubStreamReveal">
            <div style="flex:1; min-width:0;"><div style="font-weight:500;">流式文字渐显</div><div style="font-size:11.5px; color:var(--ink-tertiary);">自适应速率与墨韵局部渐显；开启减弱动态时自动降级为直接追平</div></div>
            <span class="ios-switch ${state.streamingRevealOn ? "on" : ""}"></span>
          </button>
          <button type="button" class="switch-row" id="swSubRm">
            <div style="flex:1; min-width:0;"><div style="font-weight:500;">减弱动态效果</div><div style="font-size:11.5px; color:var(--ink-tertiary);">将弹簧与渐显动画收敛为极简切换</div></div>
            <span class="ios-switch ${state.reduceMotion ? "on" : ""}"></span>
          </button>
          <div class="row-item" style="flex-direction:column; align-items:stretch; gap:7px;">
            <span style="font-size:13.5px; font-weight:500;">触觉反馈强度（普通按钮始终保持静默）</span>
            <div style="display:flex; gap:6px; flex-wrap:wrap;">
              ${[["off", "关闭"], ["gentle", "轻柔"], ["standard", "标准"], ["crisp", "清脆"]].map(([hk, hLbl]) => `
                <button type="button" class="filter-pill ${state.hapticIntensity === hk ? "active" : ""}" style="font-size:11.5px;" data-pick-hap="${hk}">${hLbl}</button>
              `).join("")}
            </div>
          </div>
        </div>
        <div class="settings-section-title">CoreHaptics 语义试振（观察右侧监视器波形）</div>
        <div class="clio-card" style="padding:12px; display:flex; gap:6px; flex-wrap:wrap;">
          <button type="button" class="filter-pill" data-sub-test-hap="selection">切模型 Selection</button>
          <button type="button" class="filter-pill" data-sub-test-hap="detent">刻度吸合 Detent</button>
          <button type="button" class="filter-pill" data-sub-test-hap="pet">轻戳小克 PetWake</button>
          <button type="button" class="filter-pill active" data-sub-test-hap="confirm">盖朱印三段 thud()</button>
        </div>
      `;
    } else if (subId === "chat_display") {
      body = `
        <div class="settings-section-title">正文头像即时效果预览</div>
        <div class="mini-chat-preview" style="margin-bottom:14px;">
          <div style="display:flex; justify-content:flex-end; align-items:center; gap:7px;">
            <span style="background:var(--my-bubble); color:var(--ink); padding:6px 11px; border-radius:14px 14px 4px 14px; font-size:12.5px;">帮我看看这段排版</span>
            ${state.showChatFaces ? `<span class="chat-avatar-btn" style="width:26px;height:26px;">${renderAvatarMarkup("me", 26)}</span>` : ""}
          </div>
          <div>
            ${state.showChatFaces ? `<div style="display:flex; align-items:center; gap:6px; margin-bottom:4px;"><span class="chat-avatar-btn" style="width:24px;height:24px;">${renderAvatarMarkup("assistant", 24)}</span><strong style="font-size:11.5px; color:var(--ink-secondary);">${escHtml(state.assistant.name)}</strong></div>` : ""}
            <div class="font-reading" style="font-size:13px; color:var(--ink);">已按 1.65× 行高排好，开启双方头像时不会挤压正文和表格宽度。</div>
          </div>
        </div>

        <div class="row-card" style="margin-bottom:14px;">
          <button type="button" class="switch-row" id="swSubChatFaces">
            <div style="flex:1; min-width:0;"><div style="font-weight:500;">聊天正文显示双方头像</div><div style="font-size:11.5px; color:var(--ink-tertiary);">默认关闭保留最大阅读留白；开启后可在正文点头像直改</div></div>
            <span class="ios-switch ${state.showChatFaces ? "on" : ""}"></span>
          </button>
          <button type="button" class="switch-row" data-toggle-bool="chatShowThinking">
            <div style="flex:1; min-width:0;"><div style="font-weight:500;">保留思考过程摘要</div></div>
            <span class="ios-switch ${state.chatShowThinking ? "on" : ""}"></span>
          </button>
          <button type="button" class="switch-row" data-toggle-bool="chatTraceDefaultOpen">
            <div style="flex:1; min-width:0;"><div style="font-weight:500;">默认展开工具执行细节</div></div>
            <span class="ios-switch ${state.chatTraceDefaultOpen ? "on" : ""}"></span>
          </button>
          <button type="button" class="switch-row" data-toggle-bool="chatShowStats">
            <div style="flex:1; min-width:0;"><div style="font-weight:500;">回复末尾显示耗时与字数</div></div>
            <span class="ios-switch ${state.chatShowStats ? "on" : ""}"></span>
          </button>
        </div>

        <div class="row-card">
          <button type="button" class="disclosure-toggle" data-toggle-disclosure="agentPolicyOpen">
            <span>Agent 执行策略（唯一数据源 · 步数/并发/重试）</span>
            <span>${state.agentPolicyOpen ? "▾" : "▸"}</span>
          </button>
          ${state.agentPolicyOpen ? `
            <div class="disclosure-body">
              <div class="row-item" style="justify-content:space-between; flex-wrap:wrap; gap:6px;">
                <span style="font-size:13px;">单轮最多工具步数</span>
                <div style="display:flex; gap:5px;">
                  ${[8, 16, 24, 32].map((n) => `<button type="button" class="filter-pill font-mono ${state.agentMaxSteps === n ? "active" : ""}" style="font-size:11px; padding:2px 8px;" data-agent-steps="${n}">${n}</button>`).join("")}
                </div>
              </div>
              <div class="row-item" style="justify-content:space-between; flex-wrap:wrap; gap:6px;">
                <span style="font-size:13px;">0.36 只读工具并发上限</span>
                <div style="display:flex; gap:5px;">
                  ${[2, 4, 6].map((n) => `<button type="button" class="filter-pill font-mono ${state.agentReadConcurrency === n ? "active" : ""}" style="font-size:11px; padding:2px 8px;" data-agent-conc="${n}">${n} 路</button>`).join("")}
                </div>
              </div>
              <div class="row-item" style="justify-content:space-between; flex-wrap:wrap; gap:6px;">
                <span style="font-size:13px;">工具失败自动重试</span>
                <div style="display:flex; gap:5px;">
                  ${[0, 1, 2].map((n) => `<button type="button" class="filter-pill font-mono ${state.agentToolRetry === n ? "active" : ""}" style="font-size:11px; padding:2px 8px;" data-agent-retry="${n}">${n} 次</button>`).join("")}
                </div>
              </div>
              <button type="button" class="switch-row" data-toggle-bool="chatConfirmStop">
                <div style="flex:1; min-width:0;"><div style="font-weight:500;">长任务停止前二次防误触确认</div></div>
                <span class="ios-switch ${state.chatConfirmStop ? "on" : ""}"></span>
              </button>
            </div>
          ` : ""}
        </div>
      `;
    } else if (subId === "voice") {
      body = `
        <div class="row-card" style="margin-bottom:14px;">
          <div class="row-item" style="flex-direction:column; align-items:stretch; gap:7px;">
            <span style="font-size:13.5px; font-weight:500;">听写识别引擎</span>
            <div style="display:flex; gap:6px;">
              <button type="button" class="filter-pill ${state.voiceMode === "system" ? "active" : ""}" style="flex:1; text-align:center;" data-voice-mode="system">iOS 本地听写（离线）</button>
              <button type="button" class="filter-pill ${state.voiceMode === "cloud" ? "active" : ""}" style="flex:1; text-align:center;" data-voice-mode="cloud">云端大模型（更准）</button>
            </div>
          </div>
          ${state.voiceMode === "cloud" ? `
            <div class="row-item" style="flex-direction:column; align-items:stretch; gap:6px;">
              <span style="font-size:12px; color:var(--ink-secondary);">云端语音模型（密钥存钥匙串）</span>
              <div style="display:flex; gap:6px; flex-wrap:wrap;">
                ${["Groq Whisper v3", "SenseVoice-Small", "OpenAI Whisper"].map((vm) => `<button type="button" class="filter-pill ${state.voiceModel === vm ? "active" : ""}" style="font-size:11.5px;" data-voice-model="${vm}">${vm}</button>`).join("")}
              </div>
            </div>` : ""}
          <button type="button" class="switch-row" data-toggle-bool="voiceMuteHaptics">
            <div style="flex:1; min-width:0;"><div style="font-weight:500;">按住说话时自动屏蔽震动</div><div style="font-size:11.5px; color:var(--ink-tertiary);">防止 Taptic 马达杂音混入麦克风录音</div></div>
            <span class="ios-switch ${state.voiceMuteHaptics ? "on" : ""}"></span>
          </button>
        </div>
      `;
    } else if (subId === "memory_rules") {
      body = `
        <div class="row-card" style="margin-bottom:14px;">
          <button type="button" class="row-item pressable" id="btnSubJumpMemory">
            <span class="sf-badge" style="background:#A9554C;">${sfIcon("brain", 15)}</span>
            <div style="flex:1;"><div style="font-weight:600;">打开四层记忆库（管理全部条目）</div><div style="font-size:11.5px; color:var(--ink-secondary);">当前共 ${state.memories.length} 条 · 可编辑或撤回 AI 写入</div></div>
            <span class="settings-chevron">${sfIcon("chevronRight", 12)}</span>
          </button>
        </div>
        <div class="row-card">
          <button type="button" class="switch-row" data-toggle-bool="memAutoRecall"><div style="flex:1;"><div style="font-weight:500;">对话时自动检索记忆</div></div><span class="ios-switch ${state.memAutoRecall ? "on" : ""}"></span></button>
          <button type="button" class="switch-row" data-toggle-bool="memAutoWrite"><div style="flex:1;"><div style="font-weight:500;">允许助手自动记录稳定偏好</div></div><span class="ios-switch ${state.memAutoWrite ? "on" : ""}"></span></button>
          <button type="button" class="switch-row" data-toggle-bool="memNightOrganize"><div style="flex:1;"><div style="font-weight:500;">夜间自动归并重复记忆</div><div style="font-size:11.5px; color:var(--ink-tertiary);">使用低费率小模型静默整理</div></div><span class="ios-switch ${state.memNightOrganize ? "on" : ""}"></span></button>
        </div>
      `;
    } else if (subId === "morning") {
      body = `
        <div class="row-card">
          <button type="button" class="switch-row" data-toggle-bool="morningBriefOn"><div style="flex:1;"><div style="font-weight:500;">每日晨信简报</div><div style="font-size:11.5px; color:var(--ink-tertiary);">汇总昨日重要待办与记忆整理结果</div></div><span class="ios-switch ${state.morningBriefOn ? "on" : ""}"></span></button>
          <div class="row-item" style="justify-content:space-between; flex-wrap:wrap; gap:6px;">
            <span style="font-size:13.5px;">送达时刻</span>
            <div style="display:flex; gap:5px;">
              ${["07:00", "07:30", "08:30", "09:00"].map((tm) => `<button type="button" class="filter-pill font-mono ${state.morningTime === tm ? "active" : ""}" style="font-size:11.5px; padding:3px 9px;" data-morning-time="${tm}">${tm}</button>`).join("")}
            </div>
          </div>
          <button type="button" class="switch-row" data-toggle-bool="nightJournalOn"><div style="flex:1;"><div style="font-weight:500;">夜间伴读手札</div></div><span class="ios-switch ${state.nightJournalOn ? "on" : ""}"></span></button>
        </div>
      `;
    } else if (subId === "providers") {
      body = `
        <div class="settings-section-title">已配置服务商（API 密钥存钥匙串）</div>
        <div class="row-card" style="margin-bottom:14px;">
          ${[
            ["DeepSeek", "api.deepseek.com · 42ms", "3 个模型", "var(--ok)"],
            ["Anthropic 直连", "api.anthropic.com · 118ms", "Claude 4 系列", "var(--ok)"],
            ["Google Gemini", "generativelanguage.googleapis.com", "Imagen 3 生图", "var(--accent)"]
          ].map(([pn, pHost, pTag, pCol]) => `
            <div class="row-item">
              <span class="sf-badge" style="background:var(--accent); font-weight:700; font-size:13px;">${pn[0]}</span>
              <div style="flex:1; min-width:0;"><div style="font-weight:600; font-size:14px;">${pn}</div><div class="font-mono" style="font-size:11px; color:var(--ink-tertiary); overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">${pHost}</div></div>
              <span style="font-size:11.5px; color:${pCol}; font-weight:600;">● ${pTag}</span>
            </div>
          `).join("")}
        </div>
        <div class="settings-footer-note">所有 API 密钥只保存在 iOS 钥匙串中，不经过任何第三方中转服务器。</div>
      `;
    } else if (subId === "models_cfg") {
      body = `
        <div class="settings-section-title">四类常用角色分配</div>
        <div class="row-card" style="margin-bottom:14px;">
          ${MODEL_CATALOG.map((m) => `
            <button type="button" class="row-item pressable" data-sub-pick-model="${m.code}">
              <span class="vendor-badge" style="width:26px;height:26px;font-size:11px;">${m.vendor[0]}</span>
              <div style="flex:1; min-width:0;"><div class="font-mono" style="font-weight:600; font-size:13px;">${m.code}</div><div style="font-size:11.5px; color:var(--ink-secondary);">${m.role} · ${m.note}</div></div>
              <span style="color:var(--accent); font-weight:700;">${state.activeModel.code === m.code ? "✓ 当前" : ""}</span>
            </button>
          `).join("")}
        </div>
        <div class="row-card" style="margin-bottom:14px;">
          <div class="row-item" style="flex-direction:column; align-items:stretch; gap:7px;">
            <span style="font-size:13.5px; font-weight:500;">默认思考深度</span>
            <div style="display:flex; gap:6px; flex-wrap:wrap;">
              ${["关闭", "低", "中", "高", "自动"].map((tk) => `<button type="button" class="filter-pill ${state.activeModel.thinking === tk ? "active" : ""}" style="font-size:11.5px;" data-sub-pick-think="${tk}">${tk}</button>`).join("")}
            </div>
          </div>
        </div>
        <div class="row-card">
          <button type="button" class="disclosure-toggle" data-toggle-disclosure="modelAdvOpen">
            <span>高级推理参数（唯一数据源 · 温度/输出/请求重试）</span>
            <span>${state.modelAdvOpen ? "▾" : "▸"}</span>
          </button>
          ${state.modelAdvOpen ? `
            <div class="disclosure-body">
              <div class="row-item" style="justify-content:space-between; flex-wrap:wrap; gap:6px;">
                <span style="font-size:13px;">采样温度 (Temperature)</span>
                <div style="display:flex; gap:5px;">
                  ${[0.2, 0.7, 1.0].map((v) => `<button type="button" class="filter-pill font-mono ${state.modelTemp === v ? "active" : ""}" style="font-size:11px; padding:2px 8px;" data-model-temp="${v}">${v}</button>`).join("")}
                </div>
              </div>
              <div class="row-item" style="justify-content:space-between; flex-wrap:wrap; gap:6px;">
                <span style="font-size:13px;">上下文上限与自动压缩触发</span>
                <div style="display:flex; gap:5px;">
                  ${["60%", "75%", "90%"].map((v) => `<button type="button" class="filter-pill font-mono ${state.modelCtxRatio === v ? "active" : ""}" style="font-size:11px; padding:2px 8px;" data-model-ctx="${v}">${v}</button>`).join("")}
                </div>
              </div>
              <div class="row-item" style="justify-content:space-between; flex-wrap:wrap; gap:6px;">
                <span style="font-size:13px;">模型接口请求重试</span>
                <div style="display:flex; gap:5px;">
                  ${[1, 2, 3].map((v) => `<button type="button" class="filter-pill font-mono ${state.modelReqRetry === v ? "active" : ""}" style="font-size:11px; padding:2px 8px;" data-model-retry="${v}">${v} 次</button>`).join("")}
                </div>
              </div>
            </div>
          ` : ""}
        </div>
      `;
    } else if (subId === "extensions") {
      body = `
        <div class="row-card" style="margin-bottom:14px;">
          <button type="button" class="row-item pressable" id="btnSubJumpExt">
            <span class="sf-badge" style="background:#A9772F;">${sfIcon("plug", 15)}</span>
            <div style="flex:1;"><div style="font-weight:600;">管理全部 MCP 连接器</div><div style="font-size:11.5px; color:var(--ink-secondary);">Google Workspace · GitHub · 远山隧道 MCP</div></div>
            <span class="settings-chevron">${sfIcon("chevronRight", 12)}</span>
          </button>
        </div>
        <div class="settings-section-title">快捷开关 · 技能目录</div>
        <div class="row-card">
          ${state.skills.map((sk) => `
            <button type="button" class="switch-row" data-sub-skill="${sk.id}">
              <div style="flex:1; min-width:0;"><div class="font-mono" style="font-weight:600; font-size:13px;">${sk.name}</div><div style="font-size:11.5px; color:var(--ink-tertiary);">${sk.desc}</div></div>
              <span class="ios-switch ${sk.on ? "on" : ""}"></span>
            </button>
          `).join("")}
        </div>
      `;
    } else if (subId === "search_engine") {
      body = `
        <div class="row-card">
          ${[["builtin", "Clio 内置直连索引（免配置）"], ["brave", "Brave Search API"], ["tavily", "Tavily AI 科研聚合"], ["searxng", "自建 SearXNG 节点"]].map(([ek, eLbl]) => `
            <button type="button" class="row-item pressable" data-pick-search="${ek}">
              <span style="flex:1; font-size:13.5px;">${eLbl}</span>
              <span style="color:var(--accent); font-weight:700;">${state.searchEngine === ek ? "✓" : ""}</span>
            </button>
          `).join("")}
        </div>
      `;
    } else if (subId === "workspace") {
      body = `
        <div class="row-card" style="margin-bottom:14px;">
          <button type="button" class="row-item pressable" data-jump-roam="den"><span class="sf-badge" style="background:#A9772F;">${sfIcon("terminal", 15)}</span><div style="flex:1;"><div style="font-weight:600;">Alpine 本地终端（斗室）</div><div style="font-size:11.5px; color:var(--ink-secondary);">内置离线 Linux · Maple Mono 2:1 等宽</div></div><span class="settings-chevron">${sfIcon("chevronRight", 12)}</span></button>
          <button type="button" class="row-item pressable" data-jump-roam="ssh"><span class="sf-badge" style="background:#35587B;">${sfIcon("globe", 15)}</span><div style="flex:1;"><div style="font-weight:600;">SSH 远程主机（远山）</div><div style="font-size:11.5px; color:var(--ink-secondary);">Prod-CN2 · Ed25519 公钥已信任</div></div><span class="settings-chevron">${sfIcon("chevronRight", 12)}</span></button>
          <button type="button" class="row-item pressable" id="btnSubJumpFiles"><span class="sf-badge" style="background:#286644;">${sfIcon("cloud", 15)}</span><div style="flex:1;"><div style="font-weight:600;">书案外部挂载目录与 PDF 库</div><div style="font-size:11.5px; color:var(--ink-secondary);">1 个 iCloud 文件夹已授权访问</div></div><span class="settings-chevron">${sfIcon("chevronRight", 12)}</span></button>
        </div>
      `;
    } else if (subId === "permissions") {
      body = `
        <div class="settings-section-title">工具执行预设级别</div>
        <div class="row-card" style="margin-bottom:14px;">
          ${[["strict", "严谨 · 每步外部操作先问我"], ["balanced", "平衡 · 只读放行，写入与外网拦截"], ["auto", "放手 · 本地常用操作直接跑"], ["readonly", "仅只读 · 严禁任何修改"]].map(([pk, pLbl]) => `
            <button type="button" class="row-item pressable" data-pick-grant="${pk}">
              <span style="flex:1; font-size:13.5px;">${pLbl}</span>
              <span style="color:var(--accent); font-weight:700;">${state.grantPreset === pk ? "✓" : ""}</span>
            </button>
          `).join("")}
        </div>
        <div class="row-card">
          <button type="button" class="switch-row" data-toggle-bool="taintGuardOn">
            <div style="flex:1; min-width:0;"><div style="font-weight:500;">外网内容 Taint 安全卫士</div><div style="font-size:11.5px; color:var(--ink-tertiary);">同轮对话读过网页后，写文件或发命令强制拦截审批</div></div>
            <span class="ios-switch ${state.taintGuardOn ? "on" : ""}"></span>
          </button>
        </div>
      `;
    } else if (subId === "vault") {
      body = state.vaultUnlocked ? `
        <div class="taint-banner" style="margin-bottom:12px; background:var(--accent-wash); color:var(--accent); border-color:transparent;">
          <span>✓</span><span>已通过面容 ID 解锁 · 以下秘密永不进入模型上下文</span>
        </div>
        <div class="row-card" style="margin-bottom:12px;">
          <div class="row-item"><div style="flex:1;"><div style="font-weight:600;">WebDAV 备份口令</div><div class="font-mono" style="font-size:11.5px; color:var(--ink-tertiary);">•••••••••••• (Keychain)</div></div><span class="filter-pill" style="font-size:11px;">仅手填表单可见</span></div>
          <div class="row-item"><div style="flex:1;"><div style="font-weight:600;">Prod-CN2 Ed25519 私钥</div><div class="font-mono" style="font-size:11.5px; color:var(--ink-tertiary);">SHA256: xK9qR...v8Lm</div></div><span class="filter-pill" style="font-size:11px;">硬件隔离</span></div>
        </div>
        <button type="button" class="filter-pill" style="width:100%; padding:9px;" id="btnVaultLock">立即重新上锁</button>
      ` : `
        <div class="vault-lock-box">
          <span class="sf-badge" style="width:46px; height:46px; background:#286644; border-radius:13px;">${sfIcon("faceid", 24)}</span>
          <div class="font-mark" style="font-size:17px; font-weight:700;">密码匣已由面容 ID 保护</div>
          <div style="font-size:12.5px; color:var(--ink-secondary); max-width:250px; line-height:1.5;">
            这里的个人密码与私钥仅留在手机系统钥匙串中，模型永远无权读取，也不随云备份明文导出。
          </div>
          <button type="button" class="filter-pill active" style="padding:8px 20px; margin-top:4px;" id="btnVaultUnlock">使用面容 ID 解锁查看</button>
        </div>
      `;
    } else if (subId === "privacy") {
      body = `
        <div class="row-card">
          <button type="button" class="switch-row" data-toggle-bool="faceIdLockOn"><div style="flex:1;"><div style="font-weight:500;">打开 Clio 时验证面容 ID</div></div><span class="ios-switch ${state.faceIdLockOn ? "on" : ""}"></span></button>
          <button type="button" class="switch-row" data-toggle-bool="bgPrivacyBlur"><div style="flex:1;"><div style="font-weight:500;">切回桌面时自动模糊防窥</div></div><span class="ios-switch ${state.bgPrivacyBlur ? "on" : ""}"></span></button>
        </div>
      `;
    } else if (subId === "notifications") {
      body = `
        <div class="row-card">
          <button type="button" class="switch-row" data-toggle-bool="notifyDone"><div style="flex:1;"><div style="font-weight:500;">长任务完成与待审批通知</div></div><span class="ios-switch ${state.notifyDone ? "on" : ""}"></span></button>
          <button type="button" class="switch-row" data-toggle-bool="liveIslandOn"><div style="flex:1;"><div style="font-weight:500;">灵动岛实时进度条 (Live Activity)</div><div style="font-size:11.5px; color:var(--ink-tertiary);">显示当前思考或并发工具进展</div></div><span class="ios-switch ${state.liveIslandOn ? "on" : ""}"></span></button>
          <button type="button" class="switch-row" data-toggle-bool="bgKeepAwake"><div style="flex:1;"><div style="font-weight:500;">切后台保活长任务继续跑</div></div><span class="ios-switch ${state.bgKeepAwake ? "on" : ""}"></span></button>
        </div>
      `;
    } else if (subId === "backup") {
      body = `
        <div class="row-card" style="margin-bottom:14px;">
          <button type="button" class="switch-row" data-toggle-bool="backupEncryptKeys"><div style="flex:1;"><div style="font-weight:500;">备份中包含 API 密钥</div><div style="font-size:11.5px; color:var(--ink-tertiary);">强制独立 AES-GCM 口令加密（不含信匣密码）</div></div><span class="ios-switch ${state.backupEncryptKeys ? "on" : ""}"></span></button>
          <button type="button" class="row-item pressable" id="btnSubMakeBackup"><div style="flex:1;"><div style="font-weight:600;">立即导出加密备份包</div><div style="font-size:11.5px; color:var(--ink-tertiary);">${state.lastBackupAt}</div></div><span style="color:var(--accent); font-weight:600;">生成 ›</span></button>
        </div>
        <div class="settings-section-title">WebDAV 云端快照</div>
        <div class="row-card">
          <button type="button" class="row-item pressable" id="btnSubDavRestore"><div style="flex:1;"><strong>clio-2026-11-25.clioenc</strong><div style="font-size:11.5px; color:var(--ink-tertiary);">坚果云 WebDAV · 42.6 MB</div></div><span class="filter-pill" style="font-size:11px;">解锁恢复</span></button>
        </div>
      `;
    } else if (subId === "usage_diag") {
      body = `
        <div class="clio-card" style="padding:14px; margin-bottom:14px;">
          <div style="display:flex; justify-content:space-between; align-items:baseline; margin-bottom:6px;">
            <span style="font-size:12px; color:var(--ink-secondary);">当前上下文窗口占用</span>
            <span class="font-mono" style="font-size:18px; font-weight:700;">42.4%</span>
          </div>
          <div style="height:8px; border-radius:999px; background:var(--surface-subtle); overflow:hidden; margin-bottom:9px;"><div style="width:42.4%; height:100%; background:var(--accent);"></div></div>
          <div style="display:grid; grid-template-columns:1fr 1fr 1fr; gap:8px; text-align:center; font-size:11.5px;">
            <div><strong class="font-mono" style="font-size:15px;">54.3k</strong><div style="color:var(--ink-tertiary);">输入</div></div>
            <div><strong class="font-mono" style="font-size:15px;">12.8k</strong><div style="color:var(--ink-tertiary);">输出</div></div>
            <div><strong class="font-mono" style="font-size:15px; color:var(--ok);">68%</strong><div style="color:var(--ink-tertiary);">缓存命中</div></div>
          </div>
        </div>
        <div class="row-card" style="margin-bottom:14px;">
          <div class="row-item"><div style="flex:1;"><div style="font-weight:500;">SQLite + PDF 全文知识库</div></div><span class="font-mono" style="font-size:12px; color:var(--ok);">34.2 MB</span></div>
        </div>
        <div class="row-card">
          <button type="button" class="disclosure-toggle" data-toggle-disclosure="diagDevOpen">
            <span>开发者与诊断工具（FrameMeter / 实验室）</span>
            <span>${state.diagDevOpen ? "▾" : "▸"}</span>
          </button>
          ${state.diagDevOpen ? `
            <div class="disclosure-body">
              <div class="row-item"><div style="flex:1;"><div style="font-weight:500;">120Hz 聊天滚屏性能监测</div><div style="font-size:11px; color:var(--ink-tertiary);">[待实体真机 iPhone 录屏验证]</div></div><span class="font-mono" style="font-size:12px; color:var(--warn);">待测</span></div>
              <button type="button" class="row-item pressable" id="btnSubOpenMotionLab"><div style="flex:1;"><div style="font-weight:600; color:var(--accent);">打开动效与触觉实验室</div></div><span class="settings-chevron">${sfIcon("chevronRight", 12)}</span></button>
            </div>
          ` : ""}
        </div>
      `;
    } else if (subId === "about") {
      const sealCh = escHtml((state.assistant.sealChar || "克").slice(0, 1));
      body = `
        <div class="clio-card" style="padding:20px 16px; text-align:center; margin-bottom:14px;">
          <div style="display:inline-flex; align-items:center; gap:9px; margin-bottom:8px;">
            <span class="wordmark-clio" style="font-size:34px;">Clio</span>
            <span class="clio-seal-stamp" style="width:28px;height:28px;font-size:16px;border-radius:5px;transform:none;box-shadow:none;animation:none;">${sealCh}</span>
          </div>
          <div class="font-mono" style="font-size:12px; color:var(--ink-secondary); margin-bottom:4px;">版本 0.36 · Design System 2.0 (素笺·栖息)</div>
          <div style="font-size:12px; color:var(--ink-tertiary);">个人手机上的本地优先 AI 伴读助手</div>
        </div>
        <div class="row-card">
          <div class="row-item"><div style="flex:1;"><div style="font-weight:500;">开源许可</div><div style="font-size:11.5px; color:var(--ink-tertiary);">GPL-3.0 · github.com/lllhr94/Clio</div></div></div>
          <div class="row-item"><div style="flex:1;"><div style="font-weight:500;">字体与开源致谢</div><div style="font-size:11.5px; color:var(--ink-tertiary);">霞鹜文楷 / 马善政毛笔字 / Maple Mono / HanaAgent (Apache-2.0) / iSH</div></div></div>
        </div>
      `;
    }

    scroller.innerHTML = `<div class="settings-sub-page">${headerNav}${body}</div>`;

    // Bind back & interactive controls
    scroller.querySelector("#btnSettingsBack").onclick = () => {
      emitHaptic("silent", "返回设置主页");
      state.settingsSub = null;
      renderViewport({ resetScroll: true });
    };
    const rApp = scroller.querySelector("#btnResetApp");
    if (rApp) rApp.onclick = () => {
      state.lang = "AC"; state.acPalette = "paper_dai"; state.mode = "light"; state.tone = "literary"; state.ambientGlowOn = true; state.showHintBadge = true;
      emitHaptic("confirm", "还原外观默认"); showToast("已还原为「素笺·栖息」默认外观"); renderAll();
    };
    const rTypo = scroller.querySelector("#btnResetTypo");
    if (rTypo) rTypo.onclick = () => {
      state.readingFace = "editorial"; state.activeReadingPreset = "editorial"; state.readingSize = 17; state.lineHeight = 1.65; state.paragraphGap = 13; state.uiScale = 1.0; state.headingWeight = "semibold"; state.clreqSqueeze = true;
      emitHaptic("confirm", "还原排版默认"); showToast("已还原默认书卷字号与版式"); renderAll();
    };
    const openFCmp = scroller.querySelector("#btnSubOpenFontCompare");
    if (openFCmp) openFCmp.onclick = () => { state.fontCompareOpen = true; switchScene("chat"); };
    scroller.querySelectorAll("[data-pick-preset]").forEach((b) => {
      b.onclick = () => {
        const p = TOKENS.readingPresets.find((x) => x.id === b.dataset.pickPreset);
        if (!p) return;
        state.activeReadingPreset = p.id;
        state.readingFace = p.readingFace;
        state.readingSize = p.readingSize;
        state.lineHeight = p.lineHeight;
        state.paragraphGap = p.paragraphGap;
        emitHaptic("selection", `应用阅读预设 → ${p.name}`);
        showToast(`已切换「${p.name}」阅读预设`);
        renderAll();
      };
    });
    scroller.querySelectorAll("[data-toggle-disclosure]").forEach((b) => {
      b.onclick = () => { const k = b.dataset.toggleDisclosure; state[k] = !state[k]; emitHaptic("silent", `展开/收起 ${k}`); renderViewport(); };
    });
    scroller.querySelectorAll("[data-model-temp]").forEach((b) => { b.onclick = () => { state.modelTemp = Number(b.dataset.modelTemp); emitHaptic("selection", `Temperature → ${state.modelTemp}`); renderViewport(); }; });
    scroller.querySelectorAll("[data-model-ctx]").forEach((b) => { b.onclick = () => { state.modelCtxRatio = b.dataset.modelCtx; emitHaptic("selection", `压缩比例 → ${state.modelCtxRatio}`); renderViewport(); }; });
    scroller.querySelectorAll("[data-model-retry]").forEach((b) => { b.onclick = () => { state.modelReqRetry = Number(b.dataset.modelRetry); emitHaptic("selection", `模型请求重试 → ${state.modelReqRetry}`); renderViewport(); }; });
    scroller.querySelectorAll("[data-agent-steps]").forEach((b) => { b.onclick = () => { state.agentMaxSteps = Number(b.dataset.agentSteps); emitHaptic("selection", `最大步数 → ${state.agentMaxSteps}`); renderViewport(); }; });
    scroller.querySelectorAll("[data-agent-conc]").forEach((b) => { b.onclick = () => { state.agentReadConcurrency = Number(b.dataset.agentConc); emitHaptic("selection", `只读并发 → ${state.agentReadConcurrency}`); renderViewport(); }; });
    scroller.querySelectorAll("[data-agent-retry]").forEach((b) => { b.onclick = () => { state.agentToolRetry = Number(b.dataset.agentRetry); emitHaptic("selection", `工具重试 → ${state.agentToolRetry}`); renderViewport(); }; });
    const addProv = scroller.querySelector("#btnMockAddProv");
    if (addProv) addProv.onclick = () => { emitHaptic("silent", "新建服务商引导"); state.onboardSub = "onboard"; state.onboardStep = 3; switchScene("onboarding_home"); };

    scroller.querySelectorAll("[data-sub-mode]").forEach((b) => { b.onclick = () => { state.mode = b.dataset.subMode; emitHaptic("selection", `切外观 ${state.mode}`); renderAll(); }; });
    scroller.querySelectorAll("[data-pick-ac-pal]").forEach((b) => { b.onclick = () => { state.lang = "AC"; state.acPalette = b.dataset.pickAcPal; emitHaptic("selection", `切换主盘 ${b.dataset.pickAcPal}`); renderAll(); }; });
    scroller.querySelectorAll("[data-sub-lang]").forEach((b) => { b.onclick = () => { state.lang = b.dataset.subLang; state.tone = TOKENS.languages[state.lang].defaultTone || "daily"; emitHaptic("detent", `切换语言 ${state.lang}`); renderAll(); }; });
    scroller.querySelectorAll("[data-sub-tone]").forEach((b) => { b.onclick = () => { state.tone = b.dataset.subTone; emitHaptic("selection", `切称谓 ${state.tone}`); renderAll(); }; });
    const swGlow = scroller.querySelector("#swSubAmbientGlow");
    if (swGlow) swGlow.onclick = () => { state.ambientGlowOn = !state.ambientGlowOn; emitHaptic("selection", "切状态光氛"); renderAll(); };
    const swHint = scroller.querySelector("#swSubDailyHint");
    if (swHint) swHint.onclick = () => { state.showHintBadge = !state.showHintBadge; emitHaptic("selection", "切日常旁注"); renderAll(); };

    scroller.querySelectorAll("[data-pick-face]").forEach((b) => { b.onclick = () => { state.readingFace = b.dataset.pickFace; emitHaptic("selection", `切正文字体 ${state.readingFace}`); renderAll(); }; });
    scroller.querySelectorAll("[data-open-ruler]").forEach((b) => { b.onclick = () => { emitHaptic("silent", `打开 StopRuler ${b.dataset.openRuler}`); state.stopPickerKind = b.dataset.openRuler; renderModalLayer(); }; });
    scroller.querySelectorAll("[data-pick-hw]").forEach((b) => { b.onclick = () => { state.headingWeight = b.dataset.pickHw; emitHaptic("selection", `切标题字重 ${state.headingWeight}`); renderAll(); }; });
    const swCl = scroller.querySelector("#swClreq");
    if (swCl) swCl.onclick = () => { state.clreqSqueeze = !state.clreqSqueeze; emitHaptic("selection", "切标点挤压"); renderViewport(); };

    const swRev = scroller.querySelector("#swSubStreamReveal");
    if (swRev) swRev.onclick = () => { state.streamingRevealOn = !state.streamingRevealOn; emitHaptic("selection", `流式渐显 → ${state.streamingRevealOn ? "开" : "关"}`); renderViewport(); };
    const swRm = scroller.querySelector("#swSubRm");
    if (swRm) swRm.onclick = () => { state.reduceMotion = !state.reduceMotion; emitHaptic("selection", "切减弱动态"); renderAll(); };
    scroller.querySelectorAll("[data-pick-hap]").forEach((b) => { b.onclick = () => { state.hapticIntensity = b.dataset.pickHap; emitHaptic("detent", `触觉强度 → ${state.hapticIntensity}`); renderViewport(); }; });
    scroller.querySelectorAll("[data-sub-test-hap]").forEach((b) => { b.onclick = () => emitHaptic(b.dataset.subTestHap, `试振: ${b.textContent}`); });

    const swCf = scroller.querySelector("#swSubChatFaces");
    if (swCf) swCf.onclick = () => { state.showChatFaces = !state.showChatFaces; emitHaptic("selection", `正文双方头像 → ${state.showChatFaces ? "开" : "关"}`); renderAll(); };
    scroller.querySelectorAll("[data-toggle-bool]").forEach((b) => {
      b.onclick = () => {
        const k = b.dataset.toggleBool;
        state[k] = !state[k];
        emitHaptic("selection", `切换 ${k}`);
        renderViewport();
      };
    });

    scroller.querySelectorAll("[data-voice-mode]").forEach((b) => { b.onclick = () => { state.voiceMode = b.dataset.voiceMode; emitHaptic("selection", "切听写引擎"); renderViewport(); }; });
    scroller.querySelectorAll("[data-voice-model]").forEach((b) => { b.onclick = () => { state.voiceModel = b.dataset.voiceModel; emitHaptic("selection", "选语音模型"); renderViewport(); }; });
    scroller.querySelectorAll("[data-morning-time]").forEach((b) => { b.onclick = () => { state.morningTime = b.dataset.morningTime; emitHaptic("selection", `晨信时刻 ${state.morningTime}`); renderViewport(); }; });

    const jMem = scroller.querySelector("#btnSubJumpMemory");
    if (jMem) jMem.onclick = () => switchScene("memory");
    scroller.querySelectorAll("[data-sub-pick-model]").forEach((b) => { b.onclick = () => { const f = MODEL_CATALOG.find((x) => x.code === b.dataset.subPickModel); if (f) state.activeModel = { ...f }; emitHaptic("selection", `切默认模型 ${b.dataset.subPickModel}`); renderAll(); }; });
    scroller.querySelectorAll("[data-sub-pick-think]").forEach((b) => { b.onclick = () => { state.activeModel.thinking = b.dataset.subPickThink; emitHaptic("selection", `思考深度 ${state.activeModel.thinking}`); renderAll(); }; });
    const jExt = scroller.querySelector("#btnSubJumpExt");
    if (jExt) jExt.onclick = () => switchScene("ext");
    scroller.querySelectorAll("[data-sub-skill]").forEach((b) => { b.onclick = () => { const sk = state.skills.find((x) => x.id === b.dataset.subSkill); if (sk) sk.on = !sk.on; emitHaptic("selection", "切技能状态"); renderViewport(); }; });
    scroller.querySelectorAll("[data-pick-search]").forEach((b) => { b.onclick = () => { state.searchEngine = b.dataset.pickSearch; emitHaptic("selection", "切搜索引擎"); renderViewport(); }; });
    scroller.querySelectorAll("[data-jump-roam]").forEach((b) => { b.onclick = () => { state.roamSub = b.dataset.jumpRoam; switchScene("roam_den"); }; });
    const jFiles = scroller.querySelector("#btnSubJumpFiles");
    if (jFiles) jFiles.onclick = () => switchScene("files");
    scroller.querySelectorAll("[data-pick-grant]").forEach((b) => { b.onclick = () => { state.grantPreset = b.dataset.pickGrant; emitHaptic("detent", `切权限预设 ${state.grantPreset}`); renderViewport(); }; });
    const bVUnl = scroller.querySelector("#btnVaultUnlock");
    if (bVUnl) bVUnl.onclick = () => { state.vaultUnlocked = true; emitHaptic("confirm", "面容 ID 解锁密码匣"); renderViewport(); };
    const bVLck = scroller.querySelector("#btnVaultLock");
    if (bVLck) bVLck.onclick = () => { state.vaultUnlocked = false; emitHaptic("selection", "重新锁上密码匣"); renderViewport(); };
    const bMkBk = scroller.querySelector("#btnSubMakeBackup");
    if (bMkBk) bMkBk.onclick = () => { emitHaptic("confirm", "AES-GCM 备份生成完毕"); state.lastBackupAt = "刚刚已生成 · 42.8 MB"; showToast("已生成加密备份包 ✓"); renderViewport(); };
    const bDavR = scroller.querySelector("#btnSubDavRestore");
    if (bDavR) bDavR.onclick = () => { emitHaptic("detent", "校验 WebDAV 口令"); showToast("口令验证通过，准备恢复数据"); };
    const bMlab = scroller.querySelector("#btnSubOpenMotionLab");
    if (bMlab) bMlab.onclick = () => switchScene("motion_lab");
  }

  // ==================== Scene 14: Split CarePage (Backup/WebDAV & Flighty Usage/Diag) ====================
  function renderCareScene(scroller) {
    const subNav = `
      <div class="pill-row">
        <button type="button" class="filter-pill ${state.careSub === "backup" ? "active" : ""}" data-care-sub="backup">加密备份与 WebDAV</button>
        <button type="button" class="filter-pill ${state.careSub === "usage" ? "active" : ""}" data-care-sub="usage">用量统计与 120Hz 诊断</button>
      </div>
    `;
    if (state.careSub === "backup") {
      scroller.innerHTML = subNav + `
        <div class="section-title">本地加密打包（已从 1583 行 CarePage 拆出）</div>
        <div class="row-card">
          <div class="row-item"><div style="flex:1;"><div>备份含 API 密钥（强制独立口令加密）</div><div style="font-size:11.5px; color:var(--ink-secondary);">注：信匣 (Vault) 敏感个人密码永不导出</div></div><span class="filter-pill active" style="font-size:11px;">已加密</span></div>
          <button type="button" class="row-item pressable" id="btnMakeBackup"><span class="icon-badge" style="background:var(--accent);">📦</span><div style="flex:1;"><strong>立即生成 AES-GCM 本地备份包</strong><div style="font-size:11.5px; color:var(--ink-secondary);">${state.lastBackupAt}</div></div><span>›</span></button>
        </div>
        <div class="section-title">WebDAV 云端快照恢复列表</div>
        <div class="row-card">
          <button type="button" class="row-item pressable" id="btnDavRestore"><span class="icon-badge" style="background:var(--ok);">☁</span><div style="flex:1;"><strong>clio-2026-11-25.clioenc</strong><div style="font-size:11.5px; color:var(--ink-secondary);">坚果云 WebDAV · 42.6 MB · 完整四层记忆</div></div><span class="filter-pill" style="font-size:11px;">解锁恢复</span></button>
        </div>
      `;
      scroller.querySelector("#btnMakeBackup").onclick = () => { emitHaptic("confirm", "AES-GCM 备份生成完毕"); state.lastBackupAt = "刚刚已生成 · 42.8 MB"; renderViewport(); showToast("已生成加密备份包 ✓"); };
      scroller.querySelector("#btnDavRestore").onclick = () => { emitHaptic("detent", "校验 WebDAV 解密口令"); showToast("口令验证通过，准备恢复数据"); };
    } else {
      scroller.innerHTML = subNav + `
        <div class="clio-card" style="padding:14px; margin-bottom:10px;">
          <div style="display:flex; justify-content:space-between; align-items:baseline; margin-bottom:6px;">
            <span style="font-size:12px; color:var(--ink-secondary);">当前对话上下文负载</span>
            <span class="font-mono" style="font-size:18px; font-weight:700;">42.4%</span>
          </div>
          <div style="height:8px; border-radius:999px; background:var(--surface-subtle); overflow:hidden; margin-bottom:8px;">
            <div style="width:42.4%; height:100%; background:var(--accent);"></div>
          </div>
          <div style="display:grid; grid-template-columns:1fr 1fr 1fr; gap:8px; text-align:center; font-size:11.5px;">
            <div><strong class="font-mono" style="font-size:16px;">54.3k</strong><div style="color:var(--ink-tertiary);">累计输入</div></div>
            <div><strong class="font-mono" style="font-size:16px;">12.8k</strong><div style="color:var(--ink-tertiary);">输出</div></div>
            <div><strong class="font-mono" style="font-size:16px; color:var(--ok);">68%</strong><div style="color:var(--ink-tertiary);">缓存命中</div></div>
          </div>
        </div>
        <div class="section-title">存储占用与 120Hz 掉帧探测 (Hitches)</div>
        <div class="row-card">
          <div class="row-item"><div style="flex:1;"><strong>SQLite + PDF FTS5 知识库</strong><div style="font-size:11.5px; color:var(--ink-secondary);">34.2 MB · 零碎片</div></div><span class="font-mono" style="font-size:11.5px; color:var(--ok);">健康</span></div>
          <div class="row-item"><div style="flex:1;"><strong>UIKit 聊天掉帧监测</strong><div style="font-size:11.5px; color:var(--ink-secondary);">真实真机帧耗时归零待实体 iPhone 验证</div></div><span class="font-mono" style="font-size:11.5px; color:var(--warn);">[待真机实录]</span></div>
        </div>
      `;
    }
    scroller.querySelectorAll("[data-care-sub]").forEach((b) => { b.onclick = () => { emitHaptic("silent", "切养护标签"); state.careSub = b.dataset.careSub; renderViewport({ resetScroll: true }); }; });
  }

  // ==================== Scene 15: Interactive Motion & Haptics Lab (Deliverable #10) ====================
  function renderMotionLabScene(scroller) {
    const langCfg = TOKENS.languages[state.lang];
    const mt = langCfg.motionTiers;

    scroller.innerHTML = `
      <div style="font-size:19px; font-weight:700; margin-bottom:6px;" class="font-mark">物理动效与触觉实验室</div>
      <div style="font-size:12px; color:var(--ink-secondary); margin-bottom:10px;">
        Deliverable #10 · 当前模式：<strong>${langCfg.name}</strong>（切换方向 A/B/C 可直接比较阻尼与过冲区别）
      </div>

      <div class="clio-card" style="padding:12px 13px; margin-bottom:10px;">
        <div style="font-size:12.5px; font-weight:700; margin-bottom:6px;">① 四档标准 Motion Token 弹簧阶梯对比</div>
        <div style="display:flex; gap:5px; flex-wrap:wrap; margin-bottom:8px;">
          ${[["instant", "Instant · 80-120ms"], ["quick", "Quick · 150-220ms"], ["standard", "Standard · 250-350ms"], ["expressive", "Expressive · 400-600ms"]].map(([k, lbl]) => `
            <button type="button" class="filter-pill ${state.motionTierDemo === k ? "active" : ""}" style="font-size:11px;" data-ml-tier="${k}">${lbl}</button>
          `).join("")}
        </div>
        <div style="font-size:11.5px; font-family:var(--font-mono); color:var(--ink-secondary); margin-bottom:8px;">
          duration=${mt[state.motionTierDemo].ms}ms · response=${mt[state.motionTierDemo].response}s · damp=${mt[state.motionTierDemo].damping} · overshoot=${mt[state.motionTierDemo].overshoot}
        </div>
        <div class="motion-track"><div class="motion-ball" id="motionSpringBall"></div></div>
        <button type="button" class="filter-pill active" style="margin-top:8px; width:100%;" id="btnFireSpring">触发弹簧运动 ⇄</button>
      </div>

      <div class="clio-card" style="padding:12px 13px; margin-bottom:10px;">
        <div style="font-size:12.5px; font-weight:700; margin-bottom:4px;">② 动画可打断与手势中途接管（ColorOS/HIG 规则）</div>
        <div style="font-size:11.5px; color:var(--ink-secondary); margin-bottom:7px;">点按钮启动慢速滑行，随时用手指/鼠标按住蓝色滑块反向拖动抢夺控制权！</div>
        <div class="interrupt-track" id="interruptTrack">
          <div class="interrupt-knob" id="interruptKnob" style="left:calc(3px + (100% - 54px) * ${(state.interruptPos / 100).toFixed(4)});">拖/点</div>
        </div>
        <div style="display:flex; gap:8px; margin-top:8px;">
          <button type="button" class="filter-pill active" id="btnStartInterruptSlide">发起 700ms 滑动</button>
          <span class="font-mono" id="interruptStatusLabel" style="font-size:11px; color:var(--ink-tertiary); align-self:center;">就绪</span>
        </div>
      </div>

      <div class="clio-card" style="padding:12px 13px; margin-bottom:10px;">
        <div style="font-size:12.5px; font-weight:700; margin-bottom:6px;">③ 键盘联动锚点 &amp; 沉浸控件协调</div>
        <div style="display:flex; gap:6px; flex-wrap:wrap; margin-bottom:8px;">
          <button type="button" class="filter-pill ${state.keyboardSyncLocked ? "active" : ""}" id="btnToggleKbMode">${state.keyboardSyncLocked ? "DS 2.0：键盘 1:1 锚点锁定" : "旧BUG：失步遮挡对照"}</button>
          <button type="button" class="filter-pill" id="btnToggleKbRaise">${state.keyboardDemoRaised ? "收起演示键盘" : "弹出演示键盘"}</button>
        </div>
        <div style="border:0.5px solid var(--rule); border-radius:var(--r-inner); padding:8px; background:var(--bg); height:98px; display:flex; flex-direction:column; justify-content:space-between; overflow:hidden;">
          <div style="font-size:11.5px; transform:translateY(${!state.keyboardSyncLocked && state.keyboardDemoRaised ? "22px" : "0px"}); transition:transform 260ms ease; color:var(--ink);">
            末尾消息：「已验证 keyboardSpacerView 同步 + Paper Scrim 无穿透……」
          </div>
          <div style="height:${state.keyboardDemoRaised ? "42px" : "16px"}; background:var(--surface-subtle); border-radius:8px; display:flex; align-items:center; justify-content:center; font-size:10.5px; color:var(--ink-secondary); transition:height 260ms ease;">
            ${state.keyboardDemoRaised ? "模拟系统键盘占高（42px）" : "键盘已收起"}
          </div>
        </div>
      </div>

      <div class="clio-card stream-lab-card" style="padding:12px 13px; margin-bottom:10px;">
        <div style="display:flex; justify-content:space-between; align-items:center; gap:6px; flex-wrap:wrap;">
          <strong style="font-size:12.5px;">⑤ Telegram 级流式揭示 A / B / C 同源对照实验室</strong>
          <span class="font-mono" style="font-size:10.5px; color:var(--ok);" id="streamLabSelStatus">定稿块重建: 0 · 选区稳</span>
        </div>
        <div style="display:flex; gap:4px; flex-wrap:wrap;" id="streamLabTraceRow">
          ${[
            ["slow", "慢速稳定"], ["fast", "高速稳定"], ["jitter", "抖动不均"],
            ["stall", "网络停顿 1.2s"], ["burst", "大块突增"], ["error", "中途出错保字"]
          ].map(([k, lbl]) => `<button type="button" class="filter-pill ${state.streamLabTrace === k ? "active" : ""}" style="font-size:10.5px; padding:2px 8px;" data-sl-trace="${k}">${lbl}</button>`).join("")}
        </div>
        <div style="display:flex; gap:5px; flex-wrap:wrap;">
          <button type="button" class="filter-pill active" id="btnSlRunAll">▶ 同步跑 A / B / C 对照</button>
          <button type="button" class="filter-pill" id="btnSlStop">■ 中途停止</button>
          <button type="button" class="filter-pill" id="btnSlToggleFont">切换文楷↔苹方 (${state.streamLabFont === "wenkai" ? "文楷" : "书卷"})</button>
        </div>
        <div class="stream-lab-metrics">
          <div class="stream-lab-metric"><span>首字 / 策略</span><strong id="slMetricTtft">就绪</strong></div>
          <div class="stream-lab-metric"><span>积压(A / B / C)</span><strong id="slMetricBacklog">0 / 0 / 0</strong></div>
          <div class="stream-lab-metric"><span>解析耗时</span><strong id="slMetricParse">0.0 ms</strong></div>
        </div>
        <div style="display:grid; grid-template-columns:1fr; gap:7px;">
          <div class="stream-lab-pane font-reading" style="font-family:${state.streamLabFont === "wenkai" ? "var(--font-wenkai)" : "var(--font-editorial)"};">
            <div style="font-size:10.5px; color:var(--ink-tertiary); margin-bottom:4px; font-family:var(--font-ui);">A · 旧固定 66ms 批次（网络抖动停顿+突增重绘）</div>
            <div id="slPaneA"></div>
          </div>
          <div class="stream-lab-pane font-reading" style="font-family:${state.streamLabFont === "wenkai" ? "var(--font-wenkai)" : "var(--font-editorial)"};">
            <div style="font-size:10.5px; color:var(--ink-tertiary); margin-bottom:4px; font-family:var(--font-ui);">B · EWMA 自适应平滑追加（增量块，无渐变边）</div>
            <div id="slPaneB"></div>
          </div>
          <div class="stream-lab-pane font-reading" style="font-family:${state.streamLabFont === "wenkai" ? "var(--font-wenkai)" : "var(--font-editorial)"}; border-color:var(--accent);">
            <div style="font-size:10.5px; color:var(--accent); font-weight:600; margin-bottom:4px; font-family:var(--font-ui);">C · 定稿方案：Telegram 级 EWMA + 墨韵渐显（高速/减动效自动降级）</div>
            <div id="slPaneC"></div>
          </div>
        </div>
      </div>

      <div class="clio-card" style="padding:12px 13px;">
        <div style="font-size:12.5px; font-weight:700; margin-bottom:6px;">④ 第十五节 CoreHaptics 语义点检表</div>
        <div style="display:flex; gap:6px; flex-wrap:wrap;">
          <button type="button" class="filter-pill" data-ml-haptic="silent">普通按钮（静默）</button>
          <button type="button" class="filter-pill" data-ml-haptic="selection">切模型 Selection</button>
          <button type="button" class="filter-pill" data-ml-haptic="light">发送 Light</button>
          <button type="button" class="filter-pill" data-ml-haptic="detent">刻度 Detent</button>
          <button type="button" class="filter-pill" data-ml-haptic="pet">戳小克 PetWake</button>
          <button type="button" class="filter-pill" data-ml-haptic="confirm">批准 AHAP</button>
        </div>
      </div>
    `;

    scroller.querySelectorAll("[data-ml-tier]").forEach((b) => {
      b.onclick = () => { state.motionTierDemo = b.dataset.mlTier; emitHaptic("selection", `测算弹簧 ${state.motionTierDemo}`); renderViewport(); };
    });

    let ballRight = false;
    const ball = scroller.querySelector("#motionSpringBall");
    const fireBtn = scroller.querySelector("#btnFireSpring");
    if (fireBtn && ball) {
      fireBtn.onclick = () => {
        const tier = langCfg.motionTiers[state.motionTierDemo];
        ballRight = !ballRight;
        ball.style.transition = state.reduceMotion ? "transform 120ms linear" : `transform ${tier.ms}ms ${tier.cubic}`;
        ball.style.transform = ballRight ? "translateX(230px)" : "translateX(0px)";
        emitHaptic("selection", `${state.motionTierDemo} (${tier.ms}ms)`);
      };
    }

    // Interruptible animation sandbox using requestAnimationFrame so pointerdown grabs EXACT current position!
    const intTrack = scroller.querySelector("#interruptTrack");
    const intKnob = scroller.querySelector("#interruptKnob");
    const intLabel = scroller.querySelector("#interruptStatusLabel");
    let animRaf = null;
    let draggingInt = false;

    const startSlideAnim = (toVal) => {
      cancelAnimationFrame(animRaf);
      const fromVal = state.interruptPos;
      const startT = performance.now();
      const dur = state.reduceMotion ? 120 : 700;
      if (intLabel) intLabel.textContent = "平滑滑动中（可随时点击打断）";
      function step(now) {
        if (draggingInt) return;
        const p = Math.min(1, (now - startT) / dur);
        const eased = 1 - Math.pow(1 - p, 3);
        state.interruptPos = fromVal + (toVal - fromVal) * eased;
        if (intKnob) intKnob.style.left = `calc(3px + (100% - 54px) * ${(state.interruptPos / 100).toFixed(4)})`;
        if (p < 1) animRaf = requestAnimationFrame(step);
        else if (intLabel) intLabel.textContent = `到达终点 (${Math.round(state.interruptPos)}%)`;
      }
      animRaf = requestAnimationFrame(step);
    };

    const btnSlide = scroller.querySelector("#btnStartInterruptSlide");
    if (btnSlide) btnSlide.onclick = () => {
      state.interruptTarget = state.interruptPos > 50 ? 0 : 100;
      startSlideAnim(state.interruptTarget);
    };

    if (intKnob && intTrack) {
      intKnob.onpointerdown = (e) => {
        e.preventDefault();
        cancelAnimationFrame(animRaf);
        draggingInt = true;
        intKnob.setPointerCapture(e.pointerId);
        if (intLabel) intLabel.textContent = "✦ 已即时打断，手指 1:1 接管中";
        emitHaptic("pet", "中途打断动画并接管");
      };
      intKnob.onpointermove = (e) => {
        if (!draggingInt) return;
        const rect = intTrack.getBoundingClientRect();
        const pct = Math.min(100, Math.max(0, ((e.clientX - rect.left) / rect.width) * 100));
        state.interruptPos = pct;
        intKnob.style.left = `calc(3px + (100% - 54px) * ${(pct / 100).toFixed(4)})`;
      };
      intKnob.onpointerup = intKnob.onpointercancel = () => {
        if (!draggingInt) return;
        draggingInt = false;
        const snapTo = state.interruptPos >= 50 ? 100 : 0;
        startSlideAnim(snapTo);
      };
    }

    const kbMode = scroller.querySelector("#btnToggleKbMode");
    if (kbMode) kbMode.onclick = () => { state.keyboardSyncLocked = !state.keyboardSyncLocked; renderViewport(); };
    const kbRaise = scroller.querySelector("#btnToggleKbRaise");
    if (kbRaise) kbRaise.onclick = () => { state.keyboardDemoRaised = !state.keyboardDemoRaised; renderViewport(); };

    scroller.querySelectorAll("[data-ml-haptic]").forEach((b) => {
      b.onclick = () => emitHaptic(b.dataset.mlHaptic, `实验室触发: ${b.textContent}`);
    });

    scroller.querySelectorAll("[data-sl-trace]").forEach((b) => {
      b.onclick = () => { state.streamLabTrace = b.dataset.slTrace; emitHaptic("selection", `切换压测序列 ${state.streamLabTrace}`); renderViewport(); };
    });
    const slRun = scroller.querySelector("#btnSlRunAll");
    if (slRun) slRun.onclick = () => runStreamComparisonLab();
    const slStop = scroller.querySelector("#btnSlStop");
    if (slStop) slStop.onclick = () => stopStreamComparisonLab();
    const slFont = scroller.querySelector("#btnSlToggleFont");
    if (slFont) slFont.onclick = () => { state.streamLabFont = state.streamLabFont === "wenkai" ? "editorial" : "wenkai"; emitHaptic("selection", "对照实验室切字体"); renderViewport(); };
  }

  // ==================== P0 Hardened Incremental Markdown Engine ====================
  const graphemeSegmenter = (typeof Intl !== "undefined" && typeof Intl.Segmenter === "function")
    ? new Intl.Segmenter("zh-Hans", { granularity: "grapheme" })
    : null;

  function splitGraphemes(text) {
    const s = String(text || "");
    if (!s) return [];
    if (graphemeSegmenter) {
      const out = [];
      for (const seg of graphemeSegmenter.segment(s)) {
        out.push(seg.segment);
      }
      return out;
    }
    return Array.from(s);
  }

  function matchFenceStart(t) { return t.match(/^(`{3,}|~{3,})(.*)$/); }
  function isMathStart(t) { return t.startsWith("$$"); }
  function matchHeadingStart(t) { return t.match(/^(#{1,6})\s+(.*)$/); }
  function isHrLine(t) { return /^([-*_])(?:\s*\1){2,}$/.test(t); }
  function isTableStart(t) { return t.startsWith("|"); }
  function isTableHeaderAt(lines, idx) {
    if (!lines || idx < 0 || idx + 1 >= lines.length) return false;
    const head = lines[idx].trim();
    const delim = lines[idx + 1].trim();
    return head.startsWith("|") && delim.startsWith("|") && /^\|[\s|:-]*-+[\s|:-]*$/.test(delim);
  }
  function matchOrderedListStart(t) { return t.match(/^\d+\.\s+(.*)$/); }
  function matchUnorderedListStart(t) { return t.match(/^[-*+]\s+(.*)$/); }
  function isQuoteStart(t) { return t.startsWith(">"); }

  function canStartNonParagraphBlock(trimmedLine, lines, idx) {
    if (!trimmedLine) return false;
    return Boolean(
      matchFenceStart(trimmedLine)
      || isMathStart(trimmedLine)
      || matchHeadingStart(trimmedLine)
      || isHrLine(trimmedLine)
      || isTableHeaderAt(lines, idx)
      || matchOrderedListStart(trimmedLine)
      || matchUnorderedListStart(trimmedLine)
      || isQuoteStart(trimmedLine)
    );
  }

  function renderInlineMd(raw, isStreaming) {
    let s = String(raw ?? "");
    const tokens = [];
    const stash = (htmlStr) => {
      const idx = tokens.length;
      tokens.push(htmlStr);
      return `\u0000TOK${idx}\u0000`;
    };

    // Extract complete inline code spans first so URLs/underscores/stars inside code are untouched.
    s = s.replace(/`([^`\n]+)`/g, (_, code) => stash(`<span class="inline-code">${escHtml(code)}</span>`));

    // During streaming, only style an unclosed inline code span if non-empty code text follows; never delete backticks!
    if (isStreaming) {
      const lastBt = s.lastIndexOf("`");
      if (lastBt !== -1) {
        const before = s.slice(0, lastBt);
        const after = s.slice(lastBt + 1);
        if (after.length > 0 && !after.includes("\n")) {
          s = before + stash(`<span class="inline-code">${escHtml(after)}</span>`);
        }
      }
    }

    // Extract completed safe http/https markdown links [label](https://...) before emphasis passes.
    s = s.replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, (_, label, url) => {
      return stash(`<a href="javascript:void(0)" class="prose-link" data-url="${escHtml(url)}">${escHtml(label)}</a>`);
    });

    // Extract bare URLs before emphasis so '*' inside URLs cannot mangle tags.
    s = s.replace(/https?:\/\/[^\s<]+/g, (url) => {
      return stash(`<a href="javascript:void(0)" class="prose-link" data-url="${escHtml(url)}">${escHtml(url)}</a>`);
    });

    s = escHtml(s);
    s = s.replace(/~~([^~\n]+)~~/g, "<del>$1</del>");
    s = s.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
    if (isStreaming) {
      s = s.replace(/\*\*([^*\n]+)$/, "<strong>$1</strong>");
    }
    s = s.replace(/(^|[^\*])\*([^*\n]+)\*/g, "$1<em>$2</em>");
    s = s.replace(/\u0000TOK(\d+)\u0000/g, (_, idx) => tokens[Number(idx)] || "");
    return s;
  }

  function parseStreamingMarkdownBlocks(rawMd, isStreaming) {
    const lines = String(rawMd ?? "").replace(/\r\n?/g, "\n").split("\n");
    const blocks = [];
    let i = 0;
    const maxLoops = lines.length + 8;
    let steps = 0;

    while (i < lines.length) {
      steps += 1;
      if (steps > maxLoops) break; // Defense-in-depth invariant guard
      const prevI = i;
      const line = lines[i];
      const trim = line.trim();
      if (!trim) {
        i++;
        continue;
      }

      // 1. Fenced Code Block
      const fm = matchFenceStart(trim);
      if (fm) {
        const fenceChar = fm[1][0];
        const fenceLen = fm[1].length;
        const lang = fm[2].trim() || "text";
        const rawLines = [line];
        const codeLines = [];
        i++;
        let closed = false;
        while (i < lines.length) {
          const cur = lines[i];
          const curTrim = cur.trim();
          rawLines.push(cur);
          if (curTrim.startsWith(fenceChar.repeat(fenceLen)) && curTrim.slice(fenceLen).replace(new RegExp(`^${fenceChar}*`), "").trim() === "") {
            closed = true;
            i++;
            break;
          }
          codeLines.push(cur);
          i++;
        }
        const badge = (!closed && isStreaming) ? " · 生成中" : "";
        blocks.push({
          idx: blocks.length,
          type: "code",
          raw: rawLines.join("\n"),
          closed,
          html: `<div class="clio-inner-block" style="margin:6px 0 8px;"><div class="code-header"><span class="font-mono">${escHtml(lang)} · 2:1 grid${badge}</span><span style="font-size:10.5px; color:var(--ink-tertiary);">只读预览</span></div><pre class="code-pre">${escHtml(codeLines.join("\n") || " ")}</pre></div>`
        });
        continue;
      }

      // 2. Math Display Block ($$ ... $$)
      if (isMathStart(trim)) {
        const rawLines = [line];
        const mathLines = [];
        const restAfter = trim.slice(2).trim();
        let closed = false;
        if (restAfter && restAfter.endsWith("$$") && restAfter.length >= 2) {
          mathLines.push(restAfter.slice(0, -2).trim());
          closed = true;
          i++;
        } else {
          if (restAfter) mathLines.push(restAfter);
          i++;
          while (i < lines.length) {
            const cur = lines[i];
            const curTrim = cur.trim();
            rawLines.push(cur);
            if (curTrim.startsWith("$$") || curTrim.endsWith("$$")) {
              const stripped = curTrim.replace(/^\$\$|\$\$$/g, "").trim();
              if (stripped) mathLines.push(stripped);
              closed = true;
              i++;
              break;
            }
            mathLines.push(curTrim);
            i++;
          }
        }
        blocks.push({
          idx: blocks.length,
          type: "math",
          raw: rawLines.join("\n"),
          closed,
          html: `<div class="prose-math"><div class="math-label">公式渲染${!closed && isStreaming ? " · 输入中" : ""}</div><div class="math-expr">${escHtml(mathLines.join(" ") || trim)}</div></div>`
        });
        continue;
      }

      // 3. Headings (# .. ###### + whitespace + text, clamped visually to H1..H4)
      const hm = matchHeadingStart(trim);
      if (hm) {
        const lvl = Math.min(4, hm[1].length);
        const body = hm[2];
        i++;
        blocks.push({
          idx: blocks.length,
          type: `h${lvl}`,
          raw: line,
          closed: true,
          html: body
            ? `<h${lvl} class="prose-h${lvl}">${renderInlineMd(body, isStreaming)}</h${lvl}>`
            : `<p class="prose-p">${escHtml(trim)}</p>`
        });
        continue;
      }

      // 4. Horizontal Rule
      if (isHrLine(trim)) {
        i++;
        blocks.push({
          idx: blocks.length,
          type: "hr",
          raw: line,
          closed: true,
          html: `<hr class="prose-hr" />`
        });
        continue;
      }

      // 5. Markdown Table (incremental safe: only upgrade once header + delimiter dash row exist)
      if (isTableHeaderAt(lines, i)) {
        const tLines = [];
        const rawLines = [];
        while (i < lines.length && isTableStart(lines[i].trim())) {
          rawLines.push(lines[i]);
          tLines.push(lines[i].trim());
          i++;
        }
        const parseCells = (row) => row.replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
        const headers = parseCells(tLines[0]);
        let startRow = 1;
        let aligns = headers.map(() => "left");
        if (tLines[1] && /^[\|\s:-]+$/.test(tLines[1])) {
          const sepCells = parseCells(tLines[1]);
          aligns = sepCells.map((sc) => (sc.endsWith(":") && !sc.startsWith(":") ? "num" : "left"));
          startRow = 2;
        }
        const bodyRows = tLines.slice(startRow).map(parseCells);
        blocks.push({
          idx: blocks.length,
          type: "table",
          raw: rawLines.join("\n"),
          closed: bodyRows.length > 0,
          html: `<div class="prose-table-wrap has-scroll" style="margin:6px 0 8px;"><table class="prose-table"><thead><tr>${headers.map((h, ci) => `<th class="${aligns[ci] === "num" ? "num" : ""}">${renderInlineMd(h, isStreaming)}</th>`).join("")}</tr></thead><tbody>${bodyRows.map((r) => `<tr>${headers.map((_, ci) => {
            const val = r[ci] || "";
            const isNumCol = aligns[ci] === "num" || /^\d[\d,.*×]*$/.test(val);
            return `<td class="${isNumCol ? "num font-mono" : ""}">${renderInlineMd(val, isStreaming)}</td>`;
          }).join("")}</tr>`).join("")}</tbody></table></div>`
        });
        continue;
      }

      // 6. Ordered List + nested Unordered List
      if (matchOrderedListStart(trim)) {
        const rawLines = [];
        let liHtml = "";
        while (i < lines.length) {
          const curT = lines[i].trim();
          const om = matchOrderedListStart(curT);
          if (!om) break;
          rawLines.push(lines[i]);
          i++;
          let subUl = "";
          while (i < lines.length) {
            const subT = lines[i].trim();
            const subM = /^\s+[-*+]\s+(.*)$/.test(lines[i]) ? subT.match(/^[-*+]\s+(.*)$/) : null;
            if (!subM) break;
            rawLines.push(lines[i]);
            subUl += `<li>${renderInlineMd(subM[1], isStreaming)}</li>`;
            i++;
          }
          liHtml += `<li>${renderInlineMd(om[1], isStreaming)}${subUl ? `<ul class="prose-list">${subUl}</ul>` : ""}</li>`;
        }
        blocks.push({
          idx: blocks.length,
          type: "ol",
          raw: rawLines.join("\n"),
          closed: true,
          html: `<ol class="prose-ol">${liHtml}</ol>`
        });
        continue;
      }

      // 7. Unordered List
      if (matchUnorderedListStart(trim)) {
        const rawLines = [];
        let liHtml = "";
        while (i < lines.length) {
          const um = matchUnorderedListStart(lines[i].trim());
          if (!um) break;
          rawLines.push(lines[i]);
          liHtml += `<li>${renderInlineMd(um[1], isStreaming)}</li>`;
          i++;
        }
        blocks.push({
          idx: blocks.length,
          type: "ul",
          raw: rawLines.join("\n"),
          closed: true,
          html: `<ul class="prose-list">${liHtml}</ul>`
        });
        continue;
      }

      // 8. Blockquote
      if (isQuoteStart(trim)) {
        const rawLines = [];
        const qLines = [];
        while (i < lines.length && isQuoteStart(lines[i].trim())) {
          rawLines.push(lines[i]);
          qLines.push(lines[i].trim().replace(/^>\s?/, ""));
          i++;
        }
        blocks.push({
          idx: blocks.length,
          type: "quote",
          raw: rawLines.join("\n"),
          closed: true,
          html: `<blockquote class="prose-quote">${renderInlineMd(qLines.join(" ") || ">", isStreaming)}</blockquote>`
        });
        continue;
      }

      // 9. Paragraph (strictly guaranteed to consume >= 1 line; handles standalone #, #tag, -, 1. safely)
      const pRaw = [];
      const pLines = [];
      while (i < lines.length) {
        const cur = lines[i];
        const pt = cur.trim();
        if (!pt) break;
        if (pLines.length > 0 && canStartNonParagraphBlock(pt, lines, i)) break;
        pRaw.push(cur);
        pLines.push(pt);
        i++;
      }
      if (pLines.length > 0) {
        blocks.push({
          idx: blocks.length,
          type: "paragraph",
          raw: pRaw.join("\n"),
          closed: true,
          html: `<p class="prose-p">${renderInlineMd(pLines.join(" "), isStreaming)}</p>`
        });
      }

      // Mathematical forward-progress guarantee: never allow i to stall!
      if (i <= prevI) {
        blocks.push({
          idx: blocks.length,
          type: "paragraph",
          raw: line,
          closed: true,
          html: `<p class="prose-p">${escHtml(line)}</p>`
        });
        i = prevI + 1;
      }
    }

    return blocks;
  }

  function renderStreamingMarkdown(rawMd, isStreaming) {
    const blocks = parseStreamingMarkdownBlocks(rawMd, isStreaming);
    if (!blocks.length) {
      return isStreaming
        ? `<p class="prose-p"><span class="streaming-caret" aria-hidden="true"></span></p>`
        : `<p class="prose-p">……</p>`;
    }
    const html = blocks.map((b, k) => `<div class="md-block" data-block-idx="${k}">${b.html}</div>`).join("");
    return isStreaming ? html + `<span class="streaming-caret" aria-hidden="true"></span>` : html;
  }

  // ==================== Scroll-Aware Chrome Controller ====================
  class ScrollChromeController {
    constructor(cfg = {}) {
      const defaults = (typeof TOKENS !== "undefined" && TOKENS.scrollAwareChrome) || {};
      this.enterDeltaPx = cfg.enterDeltaPx ?? defaults.enterDeltaPx ?? 44;
      this.exitDeltaPx = cfg.exitDeltaPx ?? defaults.exitDeltaPx ?? 56;
      this.nearBottomPx = cfg.nearBottomPx ?? defaults.nearBottomPx ?? 80;
      this.restoreBottomPx = cfg.restoreBottomPx ?? defaults.restoreBottomPx ?? 48;
      this.mode = "full";
      this.upAccum = 0;
      this.downAccum = 0;
    }

    handleScroll({ deltaY, distBottom, isScrollable, locked }) {
      if (locked || !isScrollable) {
        this.mode = "full";
        this.upAccum = 0;
        this.downAccum = 0;
        return this.mode;
      }
      if (distBottom <= this.restoreBottomPx) {
        this.mode = "full";
        this.upAccum = 0;
        this.downAccum = 0;
        return this.mode;
      }
      if (deltaY < 0) {
        this.downAccum = 0;
        if (distBottom <= this.nearBottomPx) {
          this.upAccum = 0;
          return this.mode;
        }
        this.upAccum += -deltaY;
        if (this.mode === "full" && this.upAccum >= this.enterDeltaPx) {
          this.mode = "immersive";
          this.upAccum = 0;
        }
      } else if (deltaY > 0) {
        this.downAccum += deltaY;
        this.upAccum = 0;
        if (this.mode === "immersive" && this.downAccum >= this.exitDeltaPx) {
          this.mode = "full";
          this.downAccum = 0;
        }
      }
      return this.mode;
    }
  }
  ScrollChromeController.programmaticUntil = 0;
  ScrollChromeController.markProgrammaticScroll = function (ms = 140) {
    ScrollChromeController.programmaticUntil = Date.now() + ms;
  };
  ScrollChromeController.isProgrammaticScroll = function () {
    return Date.now() <= ScrollChromeController.programmaticUntil;
  };

  function getChromeLockReason(st = state) {
    if (st.chatKeyboardOpen) return "keyboard_open";
    if (st.composerFocused) return "composer_focused";
    if (st.selectionActive) return "selection_active";
    if (st.voiceRecording) return "voice_recording";
    if (st.simVoiceOver) return "voiceover_active";
    if (st.pendingQuote) return "quote_editing";
    if (st.scene === "approval" && st.inlineApprovalStatus === "pending") return "pending_approval";
    if (st.scene === "ask" && !st.askSubmitted) return "pending_ask";
    if (st.scene === "roam_den" && st.roamSub === "roam" && st.roamHandoffActive) return "browser_handoff";
    return null;
  }

  function applyChromeModeTransition(nextMode, scroller) {
    if (state.chromeMode === nextMode) return;
    const beforeBottomDist = scroller ? (scroller.scrollHeight - scroller.scrollTop) : null;
    state.chromeMode = nextMode;
    syncImmersiveOverlays();
    const dock = document.getElementById("bottomDockArea");
    if (dock) {
      const canHideDock = (nextMode === "immersive") && !getChromeLockReason(state) && (state.scene === "chat" || state.scene === "pet");
      dock.classList.toggle("can-hide", canHideDock);
    }
    if (scroller && beforeBottomDist !== null) {
      ScrollChromeController.markProgrammaticScroll();
      scroller.scrollTop = Math.max(0, scroller.scrollHeight - beforeBottomDist);
    }
  }

  function restoreFullChrome(reasonLabel) {
    if (state.chromeMode !== "full") {
      applyChromeModeTransition("full", typeof document !== "undefined" ? document.getElementById("mainScroller") : null);
      if (reasonLabel) appendHapticLog?.(`[沉浸阅读 → 恢复控件] ${reasonLabel}`, "#94A3B8");
    } else if (typeof document !== "undefined") {
      syncImmersiveOverlays();
    }
  }

  // ==================== Telegram Upstream-Aligned Reveal Controller & Port Reference ====================
  // Verbatim JS math mirror of TelegramMessenger/Telegram-iOS (24638bc69bd083981b178dd1e7f921eebbf7fc46)
  // submodules/TelegramUI/Components/StreamingTextReveal/Sources/TextRevealController.swift (L4-89)
  class TelegramTextRevealControllerRef {
    static velocityTau = 0.12;
    static gapEwmaAlpha = 0.4;
    static initialGap = 0.5;
    static stallFloor = 0.10;
    static finalizeTime = 0.3;
    static frameDtCap = 0.05;
    static initialInputRate = 40.0;

    constructor(initialRevealedCount = 0, initialLength = 0, durationMultiplier = 1.0) {
      this.revealedCount = Number(initialRevealedCount);
      this.velocity = 0.0;
      this.avgInterArrival = TelegramTextRevealControllerRef.initialGap;
      this.lastSampleTime = null;
      this.lastSampleLength = null;
      this.predictedNextArrivalTime = null;
      this.chunkCount = 0;
      this.latestLength = initialLength;
      this.isFinalizing = false;
      this.lastFrameTime = null;
      this.durationMultiplier = Math.max(0.0001, durationMultiplier);
    }

    get currentGlyphCount() {
      return Math.trunc(this.revealedCount);
    }

    observeUpdate(latestLength, now) {
      if (this.lastSampleLength !== null) {
        if (latestLength > this.lastSampleLength) {
          if (this.lastSampleTime !== null) {
            const interArrival = Math.max(now - this.lastSampleTime, 0.001);
            this.avgInterArrival = TelegramTextRevealControllerRef.gapEwmaAlpha * interArrival
              + (1.0 - TelegramTextRevealControllerRef.gapEwmaAlpha) * this.avgInterArrival;
          }
          this.lastSampleTime = now;
          this.lastSampleLength = latestLength;
          this.predictedNextArrivalTime = now + this.avgInterArrival;
          this.chunkCount += 1;
        } else if (latestLength < this.lastSampleLength) {
          this.lastSampleLength = latestLength;
        }
      } else {
        this.lastSampleTime = now;
        this.lastSampleLength = latestLength;
        this.predictedNextArrivalTime = now + this.avgInterArrival;
        this.chunkCount += 1;
      }
      this.latestLength = latestLength;
      if (this.revealedCount > latestLength) {
        this.revealedCount = latestLength;
      }
    }

    finalize(finalLength) {
      this.latestLength = finalLength;
      this.isFinalizing = true;
      if (this.revealedCount > finalLength) {
        this.revealedCount = finalLength;
      }
    }

    tick(now) {
      const dt = Math.min(now - (this.lastFrameTime ?? now), TelegramTextRevealControllerRef.frameDtCap);
      const lag = Math.max(0.0, this.latestLength - this.revealedCount);
      let targetVelocity;
      if (this.isFinalizing) {
        targetVelocity = Math.max(this.velocity, lag / TelegramTextRevealControllerRef.finalizeTime);
      } else if (this.chunkCount < 2) {
        targetVelocity = lag > 0.0 ? TelegramTextRevealControllerRef.initialInputRate : 0.0;
      } else if (this.predictedNextArrivalTime !== null) {
        const timeToNext = Math.max(TelegramTextRevealControllerRef.stallFloor, this.predictedNextArrivalTime - now);
        targetVelocity = lag / timeToNext;
      } else {
        targetVelocity = lag > 0.0 ? TelegramTextRevealControllerRef.initialInputRate : 0.0;
      }
      const smoothing = Math.min(1.0, dt / TelegramTextRevealControllerRef.velocityTau);
      this.velocity += (targetVelocity - this.velocity) * smoothing;
      this.revealedCount = Math.min(this.latestLength, this.revealedCount + this.velocity * dt / this.durationMultiplier);
      this.lastFrameTime = now;
      const isComplete = this.isFinalizing && this.revealedCount >= this.latestLength;
      return { revealedGlyphCount: Math.trunc(this.revealedCount), isComplete };
    }
  }

  class ClioRevealController {
    constructor(opts = {}) {
      const cfg = (typeof TOKENS !== "undefined" && TOKENS.streamingReveal) || {};
      this.velocityTau = opts.velocityTau ?? cfg.velocityTau ?? 0.12;
      this.gapEwmaAlpha = opts.gapEwmaAlpha ?? cfg.gapEwmaAlpha ?? 0.4;
      this.initialGap = opts.initialGap ?? cfg.initialGap ?? 0.5;
      this.stallFloor = opts.stallFloor ?? cfg.stallFloor ?? 0.10;
      this.finalizeTime = opts.finalizeTime ?? cfg.finalizeTime ?? 0.3;
      this.frameDtCap = opts.frameDtCap ?? cfg.frameDtCap ?? 0.05;
      this.initialInputRate = opts.initialInputRate ?? cfg.initialInputRate ?? 40.0;
      this.burstBlurCutoff = opts.burstBlurCutoff ?? cfg.burstBlurCutoffCharsPerSec ?? 80;

      this.receivedText = "";
      this.graphemes = [];
      this.latestLength = 0;
      this.revealedCount = 0;
      this.velocity = 0;
      this.avgInterArrival = this.initialGap;
      this.lastSampleTime = null;
      this.lastSampleLength = null;
      this.predictedNextArrivalTime = null;
      this.chunkCount = 0;
      this.isFinalizing = false;
      this.stopped = false;
      this.errorMessage = null;
      this.lastFrameTime = null;
      this.firstTokenAt = null;
      this.startedAt = null;
      this.ttftMs = null;
    }

    get currentRevealedText() {
      const count = Math.max(0, Math.min(this.graphemes.length, Math.floor(this.revealedCount)));
      return this.graphemes.slice(0, count).join("");
    }

    get lifecycle() {
      if (this.errorMessage) return "error";
      if (this.stopped) return "stopped";
      if (this.isFinalizing && this.revealedCount >= this.latestLength) return "completed";
      if (this.isFinalizing) return "finalizing";
      if (this.latestLength === 0) return "waiting_first_token";
      if (this.velocity > this.burstBlurCutoff) return "burst_catchup";
      if (this.predictedNextArrivalTime !== null && this.lastFrameTime !== null && this.lastFrameTime > this.predictedNextArrivalTime && this.revealedCount >= this.latestLength) {
        return "stalled";
      }
      return "streaming";
    }

    observeUpdate(latestText, nowSec) {
      if (this.stopped) return;
      if (this.startedAt === null) this.startedAt = nowSec;
      const nextText = String(latestText ?? "");
      this.receivedText = nextText;
      this.graphemes = splitGraphemes(nextText);
      const latestLen = this.graphemes.length;

      if (latestLen > 0 && this.firstTokenAt === null) {
        this.firstTokenAt = nowSec;
        this.ttftMs = Math.max(0, Math.round((this.firstTokenAt - this.startedAt) * 1000));
      }

      if (this.lastSampleLength !== null) {
        if (latestLen > this.lastSampleLength) {
          if (this.lastSampleTime !== null) {
            const interArrival = Math.max(nowSec - this.lastSampleTime, 0.001);
            this.avgInterArrival = this.gapEwmaAlpha * interArrival + (1 - this.gapEwmaAlpha) * this.avgInterArrival;
          }
          this.lastSampleTime = nowSec;
          this.lastSampleLength = latestLen;
          this.predictedNextArrivalTime = nowSec + this.avgInterArrival;
          this.chunkCount += 1;
        } else if (latestLen < this.lastSampleLength) {
          this.lastSampleLength = latestLen;
        }
      } else {
        this.lastSampleTime = nowSec;
        this.lastSampleLength = latestLen;
        this.predictedNextArrivalTime = nowSec + this.avgInterArrival;
        this.chunkCount += 1;
      }

      this.latestLength = latestLen;
      if (this.revealedCount > latestLen) {
        this.revealedCount = latestLen;
      }
    }

    finalize(finalText) {
      if (typeof finalText === "string") {
        this.receivedText = finalText;
        this.graphemes = splitGraphemes(finalText);
        this.latestLength = this.graphemes.length;
      }
      this.isFinalizing = true;
      if (this.revealedCount > this.latestLength) {
        this.revealedCount = this.latestLength;
      }
    }

    stop() {
      this.stopped = true;
      this.isFinalizing = false;
      this.revealedCount = this.latestLength;
      this.velocity = 0;
    }

    fail(errorMsg) {
      this.errorMessage = String(errorMsg || "流式传输中断");
      this.stopped = true;
      this.isFinalizing = false;
      this.revealedCount = this.latestLength;
      this.velocity = 0;
    }

    tick(nowSec, opts = {}) {
      const prevCount = Math.floor(this.revealedCount);
      if (opts.hidden) {
        this.lastFrameTime = nowSec;
        return {
          revealedCount: prevCount,
          prevRevealedCount: prevCount,
          deltaCount: 0,
          velocity: 0,
          backlog: Math.max(0, this.latestLength - prevCount),
          useBlur: false,
          isComplete: false,
          lifecycle: "background_paused"
        };
      }
      if (opts.reduceMotion || opts.instantReveal) {
        this.revealedCount = this.latestLength;
        this.lastFrameTime = nowSec;
        const cur = Math.floor(this.revealedCount);
        return {
          revealedCount: cur,
          prevRevealedCount: prevCount,
          deltaCount: Math.max(0, cur - prevCount),
          velocity: 0,
          backlog: 0,
          useBlur: false,
          isComplete: this.isFinalizing || this.stopped,
          lifecycle: opts.reduceMotion ? "reduce_motion" : this.lifecycle
        };
      }

      const dt = Math.max(0, Math.min(nowSec - (this.lastFrameTime ?? nowSec), this.frameDtCap));
      const lag = Math.max(0, this.latestLength - this.revealedCount);
      let targetVelocity = 0;
      if (this.isFinalizing) {
        targetVelocity = lag > 0 ? Math.max(this.velocity, lag / this.finalizeTime) : 0;
      } else if (this.chunkCount < 2) {
        targetVelocity = lag > 0 ? this.initialInputRate : 0;
      } else if (this.predictedNextArrivalTime !== null) {
        const timeToNext = Math.max(this.stallFloor, this.predictedNextArrivalTime - nowSec);
        targetVelocity = lag / timeToNext;
      } else {
        targetVelocity = lag > 0 ? this.initialInputRate : 0;
      }

      const smoothing = dt > 0 ? Math.min(1, dt / this.velocityTau) : 0;
      this.velocity += (targetVelocity - this.velocity) * smoothing;
      this.revealedCount = Math.min(this.latestLength, this.revealedCount + this.velocity * dt);
      this.lastFrameTime = nowSec;

      const curCount = Math.floor(this.revealedCount);
      const isComplete = (this.isFinalizing && curCount >= this.latestLength) || this.stopped;
      return {
        revealedCount: curCount,
        prevRevealedCount: prevCount,
        deltaCount: Math.max(0, curCount - prevCount),
        velocity: this.velocity,
        backlog: Math.max(0, this.latestLength - curCount),
        useBlur: this.velocity <= this.burstBlurCutoff,
        isComplete,
        lifecycle: this.lifecycle
      };
    }
  }

  function selectionIntersectsNode(node, sel) {
    if (!node || !sel || !sel.rangeCount || !String(sel.toString() || "").trim()) return false;
    try {
      for (let r = 0; r < sel.rangeCount; r++) {
        const range = sel.getRangeAt(r);
        if (typeof range.intersectsNode === "function") {
          if (range.intersectsNode(node)) return true;
        }
        if (typeof node.contains === "function") {
          if (node.contains(range.startContainer) || node.contains(range.endContainer)) return true;
        }
      }
    } catch (_) {}
    return false;
  }

  function wrapTrailingTextGraphemes(rootEl, deltaCount, useBlur) {
    if (!rootEl || deltaCount <= 0 || typeof document === "undefined") return;
    const textNodes = [];
    const collect = (node) => {
      if (!node) return;
      if (node.nodeType === 3) {
        if (node.nodeValue && node.nodeValue.length > 0) textNodes.push(node);
        return;
      }
      const children = node.childNodes || [];
      for (let k = 0; k < children.length; k++) collect(children[k]);
    };
    collect(rootEl);
    if (!textNodes.length) return;

    let rem = deltaCount;
    for (let idx = textNodes.length - 1; idx >= 0 && rem > 0; idx--) {
      const tn = textNodes[idx];
      const clusters = splitGraphemes(tn.nodeValue || "");
      if (!clusters.length) continue;
      const take = Math.min(clusters.length, rem);
      rem -= take;
      const head = clusters.slice(0, clusters.length - take).join("");
      const tail = clusters.slice(clusters.length - take).join("");
      const parent = tn.parentNode;
      if (!parent || typeof parent.insertBefore !== "function") continue;
      const span = document.createElement("span");
      span.className = `reveal-chunk${useBlur ? " reveal-blur" : ""}`;
      span.textContent = tail;
      if (head) {
        tn.nodeValue = head;
        if (tn.nextSibling) parent.insertBefore(span, tn.nextSibling);
        else parent.appendChild(span);
      } else {
        parent.replaceChild(span, tn);
      }
    }
  }

  function unwrapRevealChunks(rootEl) {
    if (!rootEl || !rootEl.querySelectorAll || typeof document === "undefined") return;
    const spans = Array.from(rootEl.querySelectorAll(".reveal-chunk"));
    spans.forEach((span) => {
      const parent = span.parentNode;
      if (!parent) return;
      const tn = document.createTextNode(span.textContent || "");
      parent.replaceChild(tn, span);
    });
    if (rootEl.dataset) rootEl.dataset.hasRevealWrap = "0";
  }

  // Incremental Block DOM Reconciler: settled prior blocks are NEVER replaced; selected blocks & pending reveals are cleanly managed!
  function patchStreamingProseDom(containerEl, revealedText, isStreaming, opts = {}) {
    if (!containerEl) return { settledRebuilds: 0, deferredSelection: false, blockCount: 0 };
    const blocks = parseStreamingMarkdownBlocks(revealedText, isStreaming);
    const sel = opts.selection ?? (typeof window !== "undefined" && window.getSelection ? window.getSelection() : null);
    let settledRebuilds = 0;
    let deferredSelection = false;

    const existingBlocks = Array.from(containerEl.querySelectorAll ? containerEl.querySelectorAll(".md-block") : []);
    while (existingBlocks.length > blocks.length) {
      const extra = existingBlocks.pop();
      if (selectionIntersectsNode(extra, sel)) {
        if (extra.dataset) extra.dataset.deferredPending = "1";
        extra._deferredPayload = { remove: true, isStreaming };
        deferredSelection = true;
        break;
      }
      extra.remove();
    }

    const oldCaret = containerEl.querySelector ? containerEl.querySelector(".streaming-caret") : null;
    if (oldCaret && !isStreaming) oldCaret.remove();

    for (let k = 0; k < blocks.length; k++) {
      const b = blocks[k];
      let el = existingBlocks[k];
      const isFrontier = (k === blocks.length - 1);
      if (el) {
        const sameHtml = el.dataset?.blockHtml === b.html && el.dataset?.blockRaw === b.raw;
        const hasTemporaryWraps = el.dataset?.hasRevealWrap === "1";
        const hasDeferred = el.dataset?.deferredPending === "1";

        if (sameHtml && !hasDeferred) {
          if (!isStreaming && hasTemporaryWraps && !selectionIntersectsNode(el, sel)) {
            unwrapRevealChunks(el);
            if (el.dataset) el.dataset.blockStreaming = "0";
          }
          continue; // Settled unchanged block: zero DOM mutation / zero rebuild!
        }

        if (selectionIntersectsNode(el, sel)) {
          if (el.dataset) el.dataset.deferredPending = "1";
          el._deferredPayload = { raw: b.raw, html: b.html, type: b.type, isStreaming };
          deferredSelection = true;
          continue; // Protect user selection inside this block until selection clears!
        }

        if (!isFrontier) settledRebuilds += 1;
        if (el.dataset) {
          el.dataset.blockRaw = b.raw;
          el.dataset.blockHtml = b.html;
          el.dataset.blockType = b.type;
          el.dataset.blockStreaming = isStreaming ? "1" : "0";
          el.dataset.hasRevealWrap = "0";
          delete el.dataset.deferredPending;
        }
        delete el._deferredPayload;
        el.innerHTML = b.html;
      } else {
        el = document.createElement("div");
        el.className = "md-block";
        if (el.dataset) {
          el.dataset.blockIdx = String(k);
          el.dataset.blockRaw = b.raw;
          el.dataset.blockHtml = b.html;
          el.dataset.blockType = b.type;
          el.dataset.blockStreaming = isStreaming ? "1" : "0";
          el.dataset.hasRevealWrap = "0";
        } else {
          el.setAttribute("data-block-idx", String(k));
        }
        el.innerHTML = b.html;
        if (oldCaret && oldCaret.parentNode === containerEl) containerEl.insertBefore(el, oldCaret);
        else containerEl.appendChild(el);
      }

      if (isFrontier && isStreaming && opts.animateEdge && (opts.deltaCount || 0) > 0) {
        wrapTrailingTextGraphemes(el, opts.deltaCount, Boolean(opts.useBlur));
        if (el.dataset) el.dataset.hasRevealWrap = "1";
      }
    }

    if (isStreaming) {
      let caret = containerEl.querySelector ? containerEl.querySelector(".streaming-caret") : null;
      if (!caret) {
        caret = document.createElement("span");
        caret.className = "streaming-caret";
        caret.setAttribute("aria-hidden", "true");
        containerEl.appendChild(caret);
      }
    }

    return { settledRebuilds, deferredSelection, blockCount: blocks.length };
  }

  function flushDeferredProseBlocks(rootOverride = null, selectionOverride = null) {
    const scope = rootOverride || (typeof document !== "undefined" ? document : null);
    if (!scope || !scope.querySelectorAll) return 0;
    const sel = selectionOverride ?? (typeof window !== "undefined" && window.getSelection ? window.getSelection() : null);
    let flushed = 0;
    const pendingNodes = Array.from(scope.querySelectorAll(".md-block")).filter(
      (n) => n.dataset?.deferredPending === "1" || n.getAttribute?.("data-deferred-pending") === "1"
    );
    for (const el of pendingNodes) {
      if (selectionIntersectsNode(el, sel)) continue;
      const payload = el._deferredPayload;
      if (payload?.remove) {
        const parent = el.parentNode;
        el.remove();
        flushed += 1;
        if (parent && !state.streaming) parent.querySelector?.(".streaming-caret")?.remove();
        continue;
      }
      if (payload) {
        el.innerHTML = payload.html;
        if (el.dataset) {
          el.dataset.blockRaw = payload.raw;
          el.dataset.blockHtml = payload.html;
          el.dataset.blockType = payload.type || "paragraph";
          el.dataset.blockStreaming = payload.isStreaming ? "1" : "0";
          el.dataset.hasRevealWrap = "0";
          delete el.dataset.deferredPending;
        }
        delete el._deferredPayload;
        flushed += 1;
      } else {
        if (el.dataset) delete el.dataset.deferredPending;
        unwrapRevealChunks(el);
      }
    }
    if (!state.streaming && scope.querySelectorAll) {
      scope.querySelectorAll(".streaming-caret").forEach((c) => c.remove());
      const hadAnySelection = Boolean(sel && sel.rangeCount && String(sel.toString() || "").trim());
      if (!hadAnySelection) {
        scope.querySelectorAll("[data-deferred-collapse='1'], [data-deferred-collapse=\"1\"]").forEach((lw) => lw.remove());
      }
    }
    return flushed;
  }

  const STREAM_TRACES = {
    slow: [
      { dtMs: 120, chars: 8 }, { dtMs: 120, chars: 8 }, { dtMs: 120, chars: 9 }, { dtMs: 120, chars: 8 }
    ],
    fast: [
      { dtMs: 35, chars: 26 }, { dtMs: 35, chars: 28 }, { dtMs: 35, chars: 30 }
    ],
    jitter: [
      { dtMs: 45, chars: 14 }, { dtMs: 190, chars: 22 }, { dtMs: 40, chars: 9 }, { dtMs: 220, chars: 26 }, { dtMs: 65, chars: 18 }
    ],
    stall: [
      { dtMs: 60, chars: 18 }, { dtMs: 60, chars: 18 }, { dtMs: 1200, chars: 48 }, { dtMs: 50, chars: 24 }
    ],
    burst: [
      { dtMs: 80, chars: 12 }, { dtMs: 260, chars: 240 }, { dtMs: 90, chars: 180 }
    ],
    error: [
      { dtMs: 70, chars: 22 }, { dtMs: 90, chars: 24 }, { dtMs: 120, chars: 22, error: "连接中断：已保留前序成功正文" }
    ]
  };

  let labTimer = null;
  let labRaf = null;
  function stopStreamComparisonLab() {
    clearTimeout(labTimer);
    if (labRaf && typeof cancelAnimationFrame === "function") cancelAnimationFrame(labRaf);
    labTimer = null;
    labRaf = null;
  }

  function runStreamComparisonLab() {
    stopStreamComparisonLab();
    const paneA = document.getElementById("slPaneA");
    const paneB = document.getElementById("slPaneB");
    const paneC = document.getElementById("slPaneC");
    if (!paneA || !paneB || !paneC) return;

    paneA.innerHTML = "";
    paneB.innerHTML = "";
    paneC.innerHTML = "";

    const sample = SECTION46_SAMPLE.fullMarkdown;
    const gAll = splitGraphemes(sample);
    const trace = STREAM_TRACES[state.streamLabTrace] || STREAM_TRACES.jitter;
    const ctrlB = new ClioRevealController();
    const ctrlC = new ClioRevealController();

    let emitted = 0;
    let traceIdx = 0;
    let totalRebuildsB = 0;
    let totalRebuildsC = 0;
    let lastShownA = "";
    let stepNum = 0;
    const startSec = performance.now() / 1000;
    let ended = false;

    function pushNextChunk() {
      if (ended) return;
      const step = trace[traceIdx % trace.length];
      traceIdx++;
      labTimer = setTimeout(() => {
        stepNum++;
        if (step.error && stepNum >= 3) {
          ctrlB.fail(step.error);
          ctrlC.fail(step.error);
          ended = true;
          return;
        }
        emitted = Math.min(gAll.length, emitted + step.chars);
        const partial = gAll.slice(0, emitted).join("");
        const nowS = performance.now() / 1000;
        ctrlB.observeUpdate(partial, nowS);
        ctrlC.observeUpdate(partial, nowS);
        if (stepNum % 2 === 0 || emitted >= gAll.length) {
          lastShownA = partial;
          paneA.innerHTML = renderStreamingMarkdown(lastShownA, emitted < gAll.length);
        }
        if (emitted >= gAll.length) {
          ctrlB.finalize(sample);
          ctrlC.finalize(sample);
          ended = true;
        } else {
          pushNextChunk();
        }
      }, step.dtMs);
    }

    function tickLab() {
      const nowS = performance.now() / 1000;
      const t0 = performance.now();
      const stepB = ctrlB.tick(nowS, { reduceMotion: state.reduceMotion, hidden: false });
      const stepC = ctrlC.tick(nowS, { reduceMotion: state.reduceMotion, hidden: false });

      if (stepB.deltaCount > 0 || (stepB.isComplete && ctrlB.receivedText)) {
        const resB = patchStreamingProseDom(paneB, ctrlB.currentRevealedText, !stepB.isComplete, { animateEdge: false });
        totalRebuildsB += resB.settledRebuilds;
      }
      if (stepC.deltaCount > 0 || (stepC.isComplete && ctrlC.receivedText)) {
        const resC = patchStreamingProseDom(paneC, ctrlC.currentRevealedText, !stepC.isComplete, {
          animateEdge: !state.reduceMotion,
          deltaCount: stepC.deltaCount,
          useBlur: stepC.useBlur
        });
        totalRebuildsC += resC.settledRebuilds;
      }
      const parseMs = (performance.now() - t0).toFixed(2);

      const mTtft = document.getElementById("slMetricTtft");
      const mBk = document.getElementById("slMetricBacklog");
      const mPs = document.getElementById("slMetricParse");
      const mSel = document.getElementById("streamLabSelStatus");
      const lifecycleLabels = {
        waiting_first_token: "等首字",
        streaming: "平滑推进",
        burst_catchup: "突发加速",
        stalled: "微停等待",
        finalizing: "尾字收口",
        completed: "已定稿",
        stopped: "已停止",
        error: "保字降级"
      };
      if (mTtft) mTtft.textContent = `${ctrlC.ttftMs ?? Math.round((nowS - startSec) * 1000)}ms·${lifecycleLabels[ctrlC.lifecycle] || ctrlC.lifecycle}`;
      if (mBk) mBk.textContent = `${Math.max(0, emitted - splitGraphemes(lastShownA).length)}/${stepB.backlog}/${stepC.backlog}`;
      if (mPs) mPs.textContent = `${parseMs} ms`;
      if (mSel) mSel.textContent = `定稿重建 B:${totalRebuildsB} C:${totalRebuildsC}`;

      if (!stepB.isComplete || !stepC.isComplete || !ended) {
        labRaf = requestAnimationFrame(tickLab);
      }
    }

    pushNextChunk();
    labRaf = requestAnimationFrame(tickLab);
  }

  let streamTimer = null;
  let streamRaf = null;
  let activeRevealCtrl = null;
  let activeStreamMeta = null;

  function pauseOrCancelStreamTimers() {
    clearTimeout(streamTimer);
    if (streamRaf && typeof cancelAnimationFrame === "function") cancelAnimationFrame(streamRaf);
    streamTimer = null;
    streamRaf = null;
  }

  function settleActiveStreamInPlace(turn, finalText, opts = {}) {
    if (!turn) return;
    turn.streaming = false;
    turn.plainText = finalText;
    turn.renderedRevealText = finalText;
    turn.aiBody = renderStreamingMarkdown(finalText, false);
    if (opts.metricsText) turn.metrics = opts.metricsText;

    activeRevealCtrl = null;
    activeStreamMeta = null;
    state.streaming = false;
    state.streamingTurnId = null;

    setPetMood(opts.petMood || "idle", opts.petMs);
    if (opts.hapticMsg) emitHaptic(opts.hapticKind || "confirm", opts.hapticMsg);

    if (typeof document === "undefined") return;
    const inChatScene = state.scene === "chat" || state.scene === "pet";
    const proseEl = inChatScene ? document.querySelector(`[data-turn-prose="${turn.id}"]`) : null;

    if (!proseEl) {
      updateDynamicIsland();
      renderTopBar();
      if (opts.backgroundToast) showToast(opts.backgroundToast);
      return;
    }

    const sc = document.getElementById("mainScroller");
    const savedScrollTop = sc ? sc.scrollTop : null;
    const sel = typeof window !== "undefined" && window.getSelection ? window.getSelection() : null;
    const hasSel = state.selectionActive || Boolean(sel && String(sel.toString() || "").trim());

    patchStreamingProseDom(proseEl, finalText, false, { animateEdge: false, selection: sel });

    const turnSec = document.getElementById(`turn-${turn.id}`);
    if (turnSec) {
      const thinkToggle = turnSec.querySelector(".thinking-toggle");
      if (thinkToggle && !hasSel) thinkToggle.textContent = "✦ 已思考 1.8s · 48 字";
      const liveWin = turnSec.querySelector(".thinking-live-window");
      if (liveWin) {
        if (hasSel && liveWin.dataset) liveWin.dataset.deferredCollapse = "1";
        else liveWin.remove();
      }
      const metricsSpan = turnSec.querySelector(".reply-actions .font-mono");
      if (metricsSpan && turn.metrics) metricsSpan.textContent = turn.metrics;
    }

    const simBtn = document.getElementById("btnSimulateStream");
    if (simBtn) simBtn.textContent = "▶ 复杂流式";

    renderTopBar();
    renderBottomDock();
    updateDynamicIsland();

    if (sc && savedScrollTop !== null) {
      if (opts.scrollToBottom && state.chatFollowBottom && !hasSel && state.chromeMode !== "immersive") {
        ScrollChromeController.markProgrammaticScroll();
        if (sc.scrollTo) sc.scrollTo({ top: sc.scrollHeight, behavior: "instant" });
        else sc.scrollTop = sc.scrollHeight;
      } else {
        ScrollChromeController.markProgrammaticScroll();
        if (sc.scrollTo) sc.scrollTo({ top: savedScrollTop, behavior: "instant" });
        else sc.scrollTop = savedScrollTop;
      }
    }
  }

  function stopStreaming(reasonLabel = "手动停止流式输出") {
    pauseOrCancelStreamTimers();
    const ctrl = activeRevealCtrl;
    const turnId = state.streamingTurnId;
    if (ctrl) ctrl.stop();
    const turn = turnId ? state.chatTurns.find((x) => x.id === turnId) : null;
    const kept = (ctrl && ctrl.receivedText) ? ctrl.receivedText : (turn?.plainText || "（已手动停止生成）");
    if (turn) {
      settleActiveStreamInPlace(turn, kept, {
        petMood: "idle",
        hapticKind: "alert",
        hapticMsg: reasonLabel,
        scrollToBottom: false
      });
    } else {
      activeRevealCtrl = null;
      activeStreamMeta = null;
      state.streaming = false;
      state.streamingTurnId = null;
      setPetMood("idle");
      emitHaptic("alert", reasonLabel);
      if (typeof document !== "undefined") {
        renderTopBar();
        renderBottomDock();
        updateDynamicIsland();
      }
    }
  }

  function failActiveStream(errorMsg = "连接中断：已保留前序成功正文") {
    pauseOrCancelStreamTimers();
    const ctrl = activeRevealCtrl;
    const turnId = state.streamingTurnId;
    if (ctrl) ctrl.fail(errorMsg);
    const turn = turnId ? state.chatTurns.find((x) => x.id === turnId) : null;
    const kept = (ctrl && ctrl.receivedText) ? ctrl.receivedText : (turn?.plainText || "");
    const finalOut = kept || `（${errorMsg}）`;
    if (turn) {
      settleActiveStreamInPlace(turn, finalOut, {
        petMood: "error",
        petMs: 2600,
        hapticKind: "error",
        hapticMsg: errorMsg,
        scrollToBottom: false,
        metricsText: "已中断·已保字"
      });
    } else {
      activeRevealCtrl = null;
      activeStreamMeta = null;
      state.streaming = false;
      state.streamingTurnId = null;
      setPetMood("error", 2600);
    }
    if (typeof showToast === "function") showToast(errorMsg);
  }

  function runActiveRevealLoop() {
    if (!activeRevealCtrl || !activeStreamMeta) return;
    const { turn, fullMarkdown, metricsText } = activeStreamMeta;

    function frame() {
      if (!activeRevealCtrl || !state.streaming || state.streamingTurnId !== turn.id) return;
      const nowSec = performance.now() / 1000;
      const isHidden = typeof document !== "undefined" && Boolean(document.hidden);
      const step = activeRevealCtrl.tick(nowSec, {
        reduceMotion: state.reduceMotion,
        instantReveal: !state.streamingRevealOn,
        hidden: isHidden
      });
      const revealedStr = activeRevealCtrl.currentRevealedText;
      turn.renderedRevealText = revealedStr;

      if (state.scene === "chat" && !isHidden) {
        const proseEl = document.querySelector(`[data-turn-prose="${turn.id}"]`);
        if (proseEl && (step.deltaCount > 0 || step.isComplete)) {
          patchStreamingProseDom(proseEl, revealedStr, !step.isComplete, {
            animateEdge: state.streamingRevealOn && !state.reduceMotion,
            deltaCount: step.deltaCount,
            useBlur: step.useBlur
          });
        }
        const sc = document.getElementById("mainScroller");
        const hasSel = state.selectionActive || Boolean(window.getSelection && window.getSelection().toString().trim());
        const jumpPill = document.getElementById("btnJumpLatest");
        if (sc && turn.id === state.chatTurns[state.chatTurns.length - 1]?.id) {
          // NEVER force scroll down if user is reading history or selecting text, and NEVER wake hidden immersive chrome!
          if (state.chatFollowBottom && !hasSel && state.chromeMode !== "immersive") {
            ScrollChromeController.markProgrammaticScroll();
            sc.scrollTop = sc.scrollHeight;
            if (jumpPill) jumpPill.classList.remove("visible");
          } else if (state.chromeMode !== "immersive") {
            if (jumpPill) jumpPill.classList.add("visible");
          }
        }
      }

      if (step.isComplete) {
        pauseOrCancelStreamTimers();
        const finalText = activeRevealCtrl.receivedText || fullMarkdown;
        settleActiveStreamInPlace(turn, finalText, {
          metricsText,
          petMood: "attention",
          petMs: 2200,
          hapticKind: "confirm",
          hapticMsg: "流式定稿完成",
          scrollToBottom: true,
          backgroundToast: "后台流式回复已生成完毕 ✓"
        });
        return;
      }

      streamRaf = requestAnimationFrame(frame);
    }

    if (typeof requestAnimationFrame === "function") {
      streamRaf = requestAnimationFrame(frame);
    }
  }

  function startStreamIntoTurn(turn, fullMarkdown, metricsText) {
    pauseOrCancelStreamTimers();
    state.streaming = true;
    state.streamingTurnId = turn.id;
    state.activeTurn = turn.id;
    state.chatFollowBottom = true;
    restoreFullChrome("开始流式输出");
    turn.streaming = true;
    turn.thinking = true;
    turn.aiBody = "";
    turn.plainText = "";
    turn.renderedRevealText = "";
    setPetMood("working");

    const graphemes = splitGraphemes(fullMarkdown);
    const ctrl = new ClioRevealController();
    activeRevealCtrl = ctrl;
    activeStreamMeta = { turn, fullMarkdown, metricsText };
    ctrl.observeUpdate("", performance.now() / 1000);
    renderAll({ scrollToBottom: true });

    let emitted = 0;
    const chunks = STREAM_TRACES.jitter;
    let cIdx = 0;
    function pump() {
      if (!state.streaming || state.streamingTurnId !== turn.id) return;
      const spec = chunks[cIdx % chunks.length];
      cIdx++;
      streamTimer = setTimeout(() => {
        if (!state.streaming || state.streamingTurnId !== turn.id) return;
        emitted = Math.min(graphemes.length, emitted + spec.chars);
        const partial = graphemes.slice(0, emitted).join("");
        turn.plainText = partial;
        ctrl.observeUpdate(partial, performance.now() / 1000);
        if (emitted >= graphemes.length) {
          ctrl.finalize(fullMarkdown);
        } else {
          pump();
        }
      }, spec.dtMs);
    }

    pump();
    runActiveRevealLoop();
  }

  function toggleStreamDemo() {
    if (state.streaming) { stopStreaming(); return; }
    emitHaptic("light", "开始 Telegram 级流式墨韵渐显");
    const newId = Math.max(0, ...state.chatTurns.map((x) => x.id)) + 1;
    const demoTurn = { id: newId, user: "演示 Telegram 级渐进揭示 + 安全增量 Markdown：含未闭合代码围栏、表格、公式与自定义字体", metrics: "1.18s · 342 tok", aiBody: "", plainText: "", sources: null };
    state.chatTurns.push(demoTurn);
    startStreamIntoTurn(demoTurn, SECTION46_SAMPLE.fullMarkdown, "1.18s · 342 tok");
  }

  function redoTurnStream(turnId) {
    const turn = state.chatTurns.find((x) => x.id === turnId);
    if (!turn) return;
    if (state.streaming) stopStreaming("重拟打断");
    turn.code = "";
    startStreamIntoTurn(turn, `已换一种表述重新整理「${turn.user.slice(0, 14)}…」：采用 CLREQ 中文混排光学字距与 8+1 设置树收敛后，Clio 兼顾阅读静气与高效生产力。`, "0.86s · 148 tok");
  }

  function sendUserMessage(rawText) {
    const text = rawText.trim();
    if (!text) return;
    if (state.streaming) stopStreaming("打断并发送新消息");
    emitHaptic("light", "发送消息");
    const newId = Math.max(0, ...state.chatTurns.map((x) => x.id)) + 1;
    const quote = state.pendingQuote;
    state.pendingQuote = null;
    state.onboardSub = "home";
    const newTurn = { id: newId, user: text, quoted: quote, metrics: "1.05s · 182 tok", aiBody: "", plainText: "", sources: ["w3.org · CLREQ"] };
    state.chatTurns.push(newTurn);
    state.scene = "chat";
    state.activeGroup = "core";
    startStreamIntoTurn(newTurn, `收到你关于「${text.slice(0, 18)}${text.length > 18 ? "…" : ""}」的请求${quote ? `（承接引用：${quote.slice(0, 14)}…）` : ""}。当前处于 ${TOKENS.languages[state.lang].name} 与 ${state.activeModel.code}（思考：${state.activeModel.thinking}），所有交互与触觉语义已严格同步。`, "1.05s · 182 tok");
  }

  function runTerminalCommand(cmd) {
    const trimmed = cmd.trim();
    if (!trimmed) return;
    emitHaptic("light", `运行终端命令: ${trimmed}`);
    state.denLogs.push({ kind: "cmd", text: trimmed });
    state.denStatus = "running";
    renderAll();
    setTimeout(() => {
      let out = `已执行：${trimmed}（2:1 中西对齐输出正常 ✓）`;
      if (trimmed.startsWith("ls")) out = "设计系统2.0结论.md   iOS26-HIG-Materials.pdf   patch-0.36.diff";
      else if (trimmed.startsWith("uname")) out = "Linux clio-den 6.6-ish #1 SMP aarch64 GNU/Linux";
      else if (trimmed.startsWith("df")) out = "Filesystem  Size   Used  Avail  Use%\n/dev/root   4.0G   312M  3.7G    8%";
      state.denLogs.push({ kind: "out", text: out });
      state.denStatus = "awake";
      emitHaptic("confirm", "终端命令完成");
      renderAll();
    }, 360);
  }

  function renderBottomDock() {
    const dock = document.getElementById("bottomDockArea");
    if (!dock) return;
    const showPlan = state.scene === "tools" && state.viewState === "normal";
    const showComposer = ["chat", "tools", "pet", "approval", "ask"].includes(state.scene) && state.viewState === "normal";
    const showDenInput = state.scene === "roam_den" && state.roamSub === "den" && state.viewState === "normal";

    let html = "";
    if (showComposer && isPetVisibleNow()) {
      const petSide = Math.round(44 * state.petSizeFactor);
      const pxLeft = `calc(22px + (100% - ${petSide + 40}px) * ${state.petX})`;
      const bubbleLeft = `clamp(112px, ${pxLeft}, calc(100% - 112px))`;
      const petVisual = (state.petActiveId === "custom" && state.petCustomPhoto)
        ? `<img src="${state.petCustomPhoto}" alt="${escHtml(activePetDisplayName())}" style="width:${petSide}px;height:${petSide}px;object-fit:cover;border-radius:12px;display:block;border:1px solid var(--rule);" />`
        : `<canvas class="pet-canvas" id="petMainCanvas" data-pet-canvas="1" data-pet-id="${escHtml(state.petActiveId)}" width="48" height="48" style="width:${petSide}px;height:${petSide}px;"></canvas>`;
      const breatheCls = (state.petActiveId === "custom" && state.petCustomBreathe) ? "breathe-custom" : "";
      html += `
        <div class="pet-stage-band" id="petStageBand" style="height:${petSide}px;">
          ${state.petBubble ? `<div class="pet-bubble" id="petBubble" style="left:${bubbleLeft}; bottom:${petSide + 4}px;"><span class="pet-bubble-link" id="petBubbleLink">${escHtml(state.petBubble.text)} ›</span><button type="button" class="pet-bubble-close" id="petBubbleClose" aria-label="关闭">✕</button></div>` : ""}
          <div class="pet-actor ${breatheCls}" id="petActor" data-pet-side="${petSide}" style="left:${pxLeft}; width:${petSide}px; height:${petSide}px;" title="${escHtml(activePetDisplayName())}：只可水平拽，轻点或三连戳">
            ${petVisual}
          </div>
        </div>
      `;
    }

    if (showPlan) {
      html += `
        <div class="plan-card ${state.planOpen ? "open" : ""}" id="planCard">
          <button type="button" class="plan-header" id="btnTogglePlan">
            <span>☰</span>
            <span style="white-space:nowrap; overflow:hidden; text-overflow:ellipsis;">2/4 · 下一步：验证 InlineAsk 与 2:1 代码对齐</span>
            <div class="plan-progress-track"><div class="plan-progress-fill" style="width:50%;"></div></div>
            <span style="font-size:11px; opacity:0.6;">${state.planOpen ? "▾" : "▸"}</span>
          </button>
          <div class="plan-body">
            <div style="display:flex; flex-direction:column; gap:4px; font-size:12px;">
              <div style="color:var(--ink-tertiary); text-decoration:line-through;">✓ 校验 117 组对比度 ≥ 4.5:1</div>
              <div style="color:var(--ink-tertiary); text-decoration:line-through;">✓ 并发读取 PDF 索引与 WebDAV 头</div>
              <div style="color:var(--accent); font-weight:600;">◉ 等待 InlineAsk 提交范围并生成批准单</div>
              <div style="color:var(--ink-secondary);">○ 打包发布至 probe 分支真机验收</div>
            </div>
          </div>
        </div>
      `;
    }

    if (showComposer) {
      if (state.pendingAttachments.length) {
        html += `<div style="display:flex; gap:5px; flex-wrap:wrap; padding:0 4px;">${state.pendingAttachments.map((a, idx) => `<span class="filter-pill" style="font-size:10.5px; padding:2px 8px;">📎 ${escHtml(a)} <button type="button" data-rm-att="${idx}" style="border:0;background:transparent;color:var(--ink-tertiary);cursor:pointer;">✕</button></span>`).join("")}</div>`;
      }
      if (state.pendingQuote) {
        html += `<div class="quote-bar"><span style="overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">❝ ${escHtml(state.pendingQuote)}</span><button type="button" class="pet-bubble-close" id="btnClearQuote">✕</button></div>`;
      }
      if (state.voiceRecording) {
        html += `
          <div class="glass-pill composer-shell" style="border-color:var(--danger);">
            <span class="voice-bars"><span></span><span></span><span></span><span></span></span>
            <span style="font-size:13px; color:var(--danger); flex:1;">正在口述转写 · 物理震动已静音保护…</span>
            <button type="button" class="filter-pill active" style="background:var(--danger); border-color:var(--danger);" id="btnStopVoice">✓ 转为文字</button>
          </div>
        `;
      } else {
        const modeTag = state.sendMode === "queue" ? "排" : (state.sendMode === "interrupt" ? "断" : "");
        html += `
          <div class="glass-pill composer-shell">
            <button type="button" class="more-btn pressable" style="width:26px; min-height:26px; font-size:17px;" id="btnAttach" aria-label="附件">＋</button>
            <textarea rows="1" class="composer-input" id="composerInput" placeholder="${t("composerPlaceholder")}"></textarea>
            ${modeTag ? `<span class="filter-pill" style="font-size:10px; padding:1px 6px; border-color:var(--accent); color:var(--accent);">${modeTag}</span>` : ""}
            <button type="button" class="more-btn pressable" style="width:26px; min-height:26px; font-size:13px;" id="btnMicVoice" aria-label="语音输入">🎙</button>
            <button type="button" class="send-btn pressable ${state.streaming ? "stop-mode" : ""}" id="btnSendMsg" title="发送（长按/右键可选策略）">${state.streaming ? "■" : "↑"}</button>
          </div>
        `;
      }
    } else if (showDenInput) {
      html += `
        <div class="glass-pill composer-shell">
          <span class="font-mono" style="color:var(--accent); font-weight:700; padding:0 2px;">#</span>
          <input class="composer-input font-mono" id="denCmdInput" placeholder="输入命令（如 ls -la）回车运行" />
          <button type="button" class="send-btn pressable" id="btnRunDenCmd">↵</button>
        </div>
      `;
    }

    const showKeyboard = showComposer && state.chatKeyboardOpen && state.scene === "chat";
    dock.classList.toggle("can-hide", (state.scene === "chat" || state.scene === "pet") && state.chromeMode === "immersive" && !getChromeLockReason(state));

    if (showKeyboard) {
      html += `
        <div class="chat-sim-keyboard" id="chatSimKeyboard">
          <div class="chat-sim-keyrow">${"QWERTYUIOP".split("").map((k) => `<span class="chat-sim-key">${k}</span>`).join("")}</div>
          <div class="chat-sim-keyrow">${"ASDFGHJKL".split("").map((k) => `<span class="chat-sim-key">${k}</span>`).join("")}</div>
          <div class="chat-sim-keyrow">
            <span class="chat-sim-key" style="max-width:44px;">⇧</span>
            ${"ZXCVBNM".split("").map((k) => `<span class="chat-sim-key">${k}</span>`).join("")}
            <button type="button" class="chat-sim-key" id="btnDismissSimKb" style="max-width:56px; color:var(--accent); cursor:pointer;">完成</button>
          </div>
        </div>`;
    }

    dock.innerHTML = html;

    const disKb = document.getElementById("btnDismissSimKb");
    if (disKb) disKb.onclick = () => { state.chatKeyboardOpen = false; state.composerFocused = false; renderAll(); };

    dock.querySelectorAll("[data-rm-att]").forEach((b) => {
      b.onclick = () => { state.pendingAttachments.splice(Number(b.dataset.rmAtt), 1); renderBottomDock(); };
    });
    const btnPlan = document.getElementById("btnTogglePlan");
    if (btnPlan) btnPlan.onclick = () => { emitHaptic("silent", "折展计划清单"); state.planOpen = !state.planOpen; renderBottomDock(); };
    const btnClearQ = document.getElementById("btnClearQuote");
    if (btnClearQ) btnClearQ.onclick = () => { state.pendingQuote = null; renderBottomDock(); };
    const btnMic = document.getElementById("btnMicVoice");
    if (btnMic) btnMic.onclick = () => { state.voiceRecording = true; emitHaptic("selection", "进入录音听写（之后强制静默震动）"); renderAll(); };
    const btnStopV = document.getElementById("btnStopVoice");
    if (btnStopV) btnStopV.onclick = () => {
      state.voiceRecording = false;
      sendUserMessage("用语音补充一句：确认核对好香港 VPS 密钥后再发版。");
    };

    const inp = document.getElementById("composerInput");
    if (inp) {
      let cComposing = false;
      inp.addEventListener("focus", () => { state.composerFocused = true; restoreFullChrome("输入框聚焦"); });
      inp.addEventListener("blur", () => { state.composerFocused = false; });
      inp.addEventListener("compositionstart", () => { cComposing = true; });
      inp.addEventListener("compositionend", () => { cComposing = false; });
      inp.oninput = () => { inp.style.height = "auto"; inp.style.height = Math.min(76, inp.scrollHeight) + "px"; };
      inp.onkeydown = (e) => {
        if (cComposing || e.isComposing || e.keyCode === 229) return;
        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault();
          const v = inp.value;
          if (v.trim()) { inp.value = ""; sendUserMessage(v); } else toggleStreamDemo();
        }
      };
    }

    const btnSend = document.getElementById("btnSendMsg");
    if (btnSend) {
      let holdTimer = null;
      let triggeredHold = false;
      btnSend.onpointerdown = () => {
        triggeredHold = false;
        holdTimer = setTimeout(() => { triggeredHold = true; emitHaptic("selection", "发送策略面板"); state.sendModeMenuOpen = true; renderModalLayer(); }, 420);
      };
      btnSend.onpointerup = btnSend.onpointercancel = () => clearTimeout(holdTimer);
      btnSend.oncontextmenu = (e) => { e.preventDefault(); state.sendModeMenuOpen = true; renderModalLayer(); };
      btnSend.onclick = () => {
        if (triggeredHold) return;
        if (state.streaming) { stopStreaming(); return; }
        const curVal = inp ? inp.value : "";
        if (curVal.trim()) { inp.value = ""; sendUserMessage(curVal); } else toggleStreamDemo();
      };
    }

    const btnAttach = document.getElementById("btnAttach");
    if (btnAttach) btnAttach.onclick = () => { emitHaptic("silent", "打开附件选单"); state.attachMenuOpen = true; renderModalLayer(); };
    const btnDen = document.getElementById("btnRunDenCmd");
    const denInp = document.getElementById("denCmdInput");
    if (btnDen && denInp) {
      let denComposing = false;
      denInp.addEventListener("compositionstart", () => { denComposing = true; });
      denInp.addEventListener("compositionend", () => { denComposing = false; });
      const exec = () => { if (denInp.value.trim()) { runTerminalCommand(denInp.value); denInp.value = ""; } };
      btnDen.onclick = exec;
      denInp.onkeydown = (e) => { if (!denComposing && !e.isComposing && e.keyCode !== 229 && e.key === "Enter") exec(); };
    }
    bindPetInteractions();
  }

  function bindPetInteractions() {
    const actor = document.getElementById("petActor");
    const band = document.getElementById("petStageBand");
    const bubble = document.getElementById("petBubble");
    const bubbleLink = document.getElementById("petBubbleLink");
    const bubbleClose = document.getElementById("petBubbleClose");

    if (bubble && bubbleLink) bubbleLink.onclick = () => { state.petBubble = null; switchScene("memory"); };
    if (bubbleClose) bubbleClose.onclick = (e) => { e.stopPropagation(); state.petBubble = null; renderBottomDock(); };
    if (!actor || !band) return;

    let dragging = false, moved = false, startX = 0, startY = 0, originPct = state.petX;
    actor.onpointerdown = (e) => {
      e.preventDefault();
      actor.setPointerCapture(e.pointerId);
      dragging = true; moved = false;
      startX = e.clientX; startY = e.clientY; originPct = state.petX;
      actor.classList.add("dragging");
      emitHaptic("pet", "抓起小克（仅限水平移）");
    };
    actor.onpointermove = (e) => {
      if (!dragging) return;
      const dx = e.clientX - startX;
      const dy = startY - e.clientY;
      if (Math.abs(dx) > 4 || Math.abs(dy) > 4) moved = true;
      const petSide = Number(actor.dataset.petSide || 44);
      const travel = Math.max(100, band.clientWidth - (petSide + 40));
      state.petX = Math.min(1, Math.max(0, originPct + dx / travel));
      if (Math.abs(dx) > 2) state.petFlipped = dx > 0;
      const lift = state.reduceMotion ? 0 : Math.min(28, Math.max(6, dy));
      actor.style.left = `calc(22px + (100% - ${petSide + 40}px) * ${state.petX})`;
      actor.style.transform = `translateY(${-lift}px) scale(1.06)`;
      if (bubble) bubble.style.left = `clamp(112px, calc(22px + (100% - ${petSide + 40}px) * ${state.petX}), calc(100% - 112px))`;
    };
    actor.onpointerup = actor.onpointercancel = (e) => {
      if (!dragging) return;
      dragging = false;
      actor.classList.remove("dragging");
      actor.style.transform = "";
      if (moved) {
        emitHaptic("pet", "小克落回输入框上沿");
        if (!state.reduceMotion) { actor.classList.add("landing"); setTimeout(() => actor.classList.remove("landing"), 250); }
        return;
      }
      const now = performance.now();
      if (state.petState === "sleeping") { emitHaptic("pet", "唤醒小克"); setPetMood("waking", 1100); return; }
      state.petTaps = state.petTaps.filter((t0) => now - t0 < 1100);
      state.petTaps.push(now);
      emitHaptic("pet", state.petTaps.length >= 3 ? "连戳小克挠痒痒" : "轻戳小克");
      if (state.petTaps.length >= 3) setPetMood("tickle", 1100);
      else {
        const rect = actor.getBoundingClientRect();
        setPetMood((e.clientX - rect.left) < rect.width / 2 ? "react-left" : "react-right", 750);
      }
    };
  }

  // ==================== Modal Sheets & Popovers ====================
  function renderModalLayer() {
    const layer = document.getElementById("phoneModalLayer");
    if (!layer) return;
    layer.innerHTML = "";

    if (state.alwaysOnOpen) {
      const aod = document.createElement("div");
      aod.className = "alwayson-overlay";
      aod.innerHTML = `<div class="font-mono" style="font-size:52px; font-weight:700; color:#EFEAE0; margin-bottom:10px;">21:42</div><div style="display:flex; align-items:center; gap:8px; margin-bottom:18px;"><span class="status-dot busy"></span><span style="font-size:14px; color:#B9B1A2;">${state.activeModel.code} · ${state.streaming ? t("replying") : t("idle")}</span></div><div style="font-size:12px; color:#787266; margin-top:24px;">${t("alwaysOnHint")}</div>`;
      aod.onclick = () => { state.alwaysOnOpen = false; renderModalLayer(); };
      layer.appendChild(aod);
      return;
    }

    if (state.diExpanded) {
      const bd = document.createElement("div");
      bd.className = "popover-backdrop";
      bd.innerHTML = `<div class="di-expanded-card" onclick="event.stopPropagation()"><div style="display:flex; align-items:center; gap:10px; margin-bottom:10px;"><canvas id="diExpandedPetCanvas" data-pet-canvas="1" width="48" height="48" style="width:32px;height:32px;image-rendering:pixelated;"></canvas><div style="flex:1;"><div style="font-size:13.5px; font-weight:600;">${escHtml(state.assistant.name)} · 灵动岛实况</div><div style="font-size:11.5px; color:#A3ABB8;">${state.activeModel.code} · ${state.streaming ? "15Hz 输出中" : "正在待命"}</div></div><span class="status-dot ${state.streaming ? "busy" : ""}"></span></div><div style="display:flex; gap:7px;"><button type="button" class="filter-pill" id="btnDiOpenAod" style="background:#1F242D; color:#F4F5F7; border-color:#353D4B; font-size:11px;">${t("alwaysOnTitle")}</button><button type="button" class="filter-pill" id="btnDiGoApproval" style="background:#1F242D; color:#F4F5F7; border-color:#353D4B; font-size:11px;">查看${t("approvalSheet")}</button><button type="button" class="filter-pill" id="btnDiClose" style="margin-left:auto; background:#2B313C; color:#F4F5F7; border-color:transparent; font-size:11px;">收起</button></div></div>`;
      bd.onclick = () => { state.diExpanded = false; renderModalLayer(); };
      layer.appendChild(bd);
      bd.querySelector("#btnDiOpenAod").onclick = () => { state.diExpanded = false; state.alwaysOnOpen = true; renderModalLayer(); };
      bd.querySelector("#btnDiGoApproval").onclick = () => { state.diExpanded = false; switchScene("approval"); };
      bd.querySelector("#btnDiClose").onclick = () => { state.diExpanded = false; renderModalLayer(); };
    }

    if (state.sidebarOpen) {
      const sealCh = escHtml((state.assistant.sealChar || "克").slice(0, 1));
      const brandMarkHtml = (state.lang === "A" || state.lang === "AC")
        ? `<div style="display:flex; align-items:center; gap:8px;"><span class="wordmark-clio">Clio</span><span class="clio-seal-stamp" style="width:22px;height:22px;font-size:13px;border-radius:4px;transform:none;box-shadow:none;animation:none;">${sealCh}</span></div>`
        : (state.lang === "B"
          ? `<div style="display:flex; align-items:center; gap:8px;"><span class="wordmark-clio">Clio</span><span class="font-mono" style="font-size:10px; padding:2px 6px; border-radius:4px; background:var(--surface-subtle); color:var(--ok);">● v2.0</span></div>`
          : `<div style="display:flex; align-items:center; gap:8px;"><span class="wordmark-clio">Clio</span><span class="filter-pill" style="font-size:10px; padding:2px 8px; background:var(--accent-wash); color:var(--accent);">静谧伴读</span></div>`);

      const bd = document.createElement("div");
      bd.className = "sidebar-backdrop";
      bd.innerHTML = `
        <div class="sidebar-panel" onclick="event.stopPropagation()">
          <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:2px;">
            ${brandMarkHtml}
            <button type="button" class="filter-pill active" id="btnSideNewChat">✎ ${t("newChat")}</button>
          </div>
          <button type="button" class="settings-search" style="margin-bottom:4px; cursor:pointer; width:100%;" data-side-go="search">
            <span>🔍</span><span style="font-size:12.5px; color:var(--ink-tertiary);">搜索对话、记忆、文件 PDF…</span>
          </button>
          <div class="row-card" style="margin-bottom:4px;">
            <button type="button" class="row-item" style="min-height:42px;" data-side-go="onboarding_home">🏠 ${t("home")} ${hintBadge("首页")}</button>
            <button type="button" class="row-item" style="min-height:42px;" data-side-go="memory">❖ ${t("memory")} ${hintBadge("1-tap 长期记忆")}</button>
            <button type="button" class="row-item" style="min-height:42px;" data-side-go="files">📚 ${t("files")} ${hintBadge("文件与知识库")}</button>
          </div>
          <div class="section-title">工作台（收敛聚合）</div>
          <div style="display:grid; grid-template-columns:1fr 1fr; gap:6px; margin-bottom:6px;">
            <button type="button" class="filter-pill" style="text-align:center;" data-side-rd="den">⌘ 终端</button>
            <button type="button" class="filter-pill" style="text-align:center;" data-side-rd="roam">🌐 浏览器</button>
            <button type="button" class="filter-pill" style="text-align:center;" data-side-rd="ssh">🖥 SSH 远山</button>
            <button type="button" class="filter-pill" style="text-align:center;" data-side-go="ext">🔌 连接/技能</button>
          </div>
          <div class="section-title">${t("pinned")}与最近</div>
          <div class="row-card" style="margin-bottom:6px;">
            <button type="button" class="row-item" style="min-height:42px;" data-side-go="chat"><span class="status-dot"></span><span>小克 · 0.36 发布前体检</span></button>
            <button type="button" class="row-item" style="min-height:42px;" data-side-go="approval"><span class="status-dot warn"></span><span>远山 · 部署确认 (待签)</span></button>
          </div>
          <button type="button" class="row-card row-item" style="margin-top:auto;" data-side-go="settings">⚙ ${t("settings")} ${hintBadge("设置")} <span style="margin-left:auto; font-size:11.5px; color:var(--ink-tertiary);">2 位${t("assistant")}</span></button>
        </div>
      `;
      bd.onclick = () => { state.sidebarOpen = false; emitHaptic("detent", "侧栏阈値关闭吸附"); renderModalLayer(); };
      layer.appendChild(bd);
      bd.querySelectorAll("[data-side-go]").forEach((b) => { b.onclick = () => { emitHaptic("detent", `侧栏吸附跳至 ${b.dataset.sideGo}`); switchScene(b.dataset.sideGo); }; });
      bd.querySelectorAll("[data-side-rd]").forEach((b) => { b.onclick = () => { emitHaptic("detent", `打开工作台 ${b.dataset.sideRd}`); state.roamSub = b.dataset.sideRd; switchScene("roam_den"); }; });
      bd.querySelector("#btnSideNewChat").onclick = () => { state.onboardSub = "empty"; switchScene("onboarding_home"); };
    }

    if (state.modelMenuOpen) {
      const bd = document.createElement("div");
      bd.className = "popover-backdrop";
      bd.innerHTML = `<div class="floating-popover" style="top:92px; right:12px; width:268px;" onclick="event.stopPropagation()"><div style="padding:10px 13px 6px; font-size:11.5px; font-weight:600; color:var(--ink-secondary);">思考深度</div><div style="padding:0 12px 10px; display:flex; gap:6px; flex-wrap:wrap; border-bottom:0.5px solid var(--rule);">${["关闭", "低", "中", "高", "自动"].map((lvl) => `<button type="button" class="filter-pill ${state.activeModel.thinking === lvl ? "active" : ""}" data-qm-think="${lvl}">${lvl}</button>`).join("")}</div><div style="padding:8px 13px 4px; font-size:11.5px; font-weight:600; color:var(--ink-secondary);">就地切换模型（含完整 Model ID）</div>${MODEL_CATALOG.map((m) => `<button type="button" class="row-item" style="min-height:42px; padding:6px 13px;" data-qm-model="${m.code}"><span class="vendor-badge" style="width:18px;height:18px;font-size:9.5px;">${m.vendor[0]}</span><div style="flex:1; min-width:0;"><div style="font-size:12.5px; font-weight:600;">${escHtml(m.shortName || resolveShortModelName(m.code))}</div><div class="font-mono" style="font-size:10px; color:var(--ink-tertiary); overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">${escHtml(m.code)}</div></div><span style="font-size:11.5px; color:var(--accent);">${state.activeModel.code === m.code ? "✓" : ""}</span></button>`).join("")}<button type="button" class="row-item" style="min-height:42px; color:var(--accent); font-weight:600; font-size:13px;" id="btnOpenModelFull">模型角色设置 ›</button></div>`;
      bd.onclick = () => { state.modelMenuOpen = false; renderModalLayer(); };
      layer.appendChild(bd);
      bd.querySelectorAll("[data-qm-think]").forEach((b) => { b.onclick = () => { state.activeModel.thinking = b.dataset.qmThink; state.modelMenuOpen = false; emitHaptic("selection", `切思考档: ${b.dataset.qmThink}`); renderAll(); }; });
      bd.querySelectorAll("[data-qm-model]").forEach((b) => { b.onclick = () => { const f = MODEL_CATALOG.find((x) => x.code === b.dataset.qmModel); if (f) state.activeModel = { ...f }; state.modelMenuOpen = false; emitHaptic("selection", `切模型: ${b.dataset.qmModel}`); showToast(`已切为 ${b.dataset.qmModel}`); renderAll(); }; });
      bd.querySelector("#btnOpenModelFull").onclick = () => switchScene("models");
    }

    if (state.moreMenuOpen) {
      const bd = document.createElement("div");
      bd.className = "popover-backdrop";
      bd.innerHTML = `<div class="floating-popover" style="top:92px; right:10px; width:246px;" onclick="event.stopPropagation()"><div style="padding:10px 13px 6px; font-size:11.5px; font-weight:600; color:var(--ink-secondary); border-bottom:0.5px solid var(--rule);">${t("moreMenuTitle")}</div><button type="button" class="row-item" style="min-height:40px; font-size:13.5px;" id="mmToggleFaces">👤 正文显示双方头像 · ${state.showChatFaces ? "开" : "关"}</button><button type="button" class="row-item" style="min-height:40px; font-size:13.5px;" id="mmEditAssistant">🪶 自定义助手与我的头像</button><button type="button" class="row-item" style="min-height:40px; font-size:13.5px;" id="mmSearch">🔍 全局搜索（对话/记忆/PDF）</button><button type="button" class="row-item" style="min-height:40px; font-size:13.5px;" id="mmSources">◈ ${t("sourcesTitle")}</button><button type="button" class="row-item" style="min-height:40px; font-size:13.5px;" id="mmCompress">⊟ ${t("compressContext")}</button><button type="button" class="row-item" style="min-height:40px; font-size:13.5px;" id="mmAlwaysOn">◐ ${t("alwaysOnTitle")}</button><button type="button" class="row-item" style="min-height:40px; font-size:13.5px;" id="mmCare">📊 用量与加密备份</button><button type="button" class="row-item" style="min-height:40px; font-size:13.5px; color:var(--danger);" id="mmResetChat">↺ ${t("clearChat")}</button></div>`;
      bd.onclick = () => { state.moreMenuOpen = false; renderModalLayer(); };
      layer.appendChild(bd);
      bd.querySelector("#mmToggleFaces").onclick = () => {
        state.moreMenuOpen = false;
        state.showChatFaces = !state.showChatFaces;
        emitHaptic("selection", `切换正文双方头像 → ${state.showChatFaces ? "开" : "关"}`);
        showToast(state.showChatFaces ? "已开启正文双方头像" : "已隐藏正文双方头像");
        renderAll();
      };
      bd.querySelector("#mmEditAssistant").onclick = () => {
        state.moreMenuOpen = false;
        openIdentityEditor("assistant");
      };
      bd.querySelector("#mmSearch").onclick = () => switchScene("search");
      bd.querySelector("#mmSources").onclick = () => { state.moreMenuOpen = false; state.sourcesSheetOpen = true; renderModalLayer(); };
      bd.querySelector("#mmCompress").onclick = () => { emitHaptic("detent", "压缩前文上下文"); state.moreMenuOpen = false; state.compressedNotice = true; showToast(t("compressedToast")); renderAll(); };
      bd.querySelector("#mmAlwaysOn").onclick = () => { state.moreMenuOpen = false; state.alwaysOnOpen = true; renderModalLayer(); };
      bd.querySelector("#mmCare").onclick = () => switchScene("care");
      bd.querySelector("#mmResetChat").onclick = () => { emitHaptic("alert", "重置演示对话"); state.moreMenuOpen = false; state.chatTurns = INITIAL_TURNS.map((x) => ({ ...x })); state.compressedNotice = false; state.pendingQuote = null; showToast("已重置"); switchScene("chat"); };
    }

    if (state.attachMenuOpen) {
      const bd = document.createElement("div");
      bd.className = "popover-backdrop";
      bd.innerHTML = `<div class="floating-popover" style="bottom:68px; left:12px; width:246px;" onclick="event.stopPropagation()"><div style="padding:10px 13px 6px; font-size:11.5px; font-weight:600; color:var(--ink-secondary); border-bottom:0.5px solid var(--rule);">加入上下文附件</div><button type="button" class="row-item" style="min-height:42px;" data-add-att="iOS26-HIG-Materials.pdf">📑 从书案选 PDF 文档</button><button type="button" class="row-item" style="min-height:42px;" data-add-att="RealDevice-Screenshot.png">🖼 相册截图 / 相机</button><button type="button" class="row-item" style="min-height:42px;" data-add-att="clipboard-patch.diff">📋 长文本粘贴（自动转附件）</button></div>`;
      bd.onclick = () => { state.attachMenuOpen = false; renderModalLayer(); };
      layer.appendChild(bd);
      bd.querySelectorAll("[data-add-att]").forEach((b) => { b.onclick = () => { state.pendingAttachments.push(b.dataset.addAtt); state.attachMenuOpen = false; emitHaptic("light", "添加附件"); renderAll(); }; });
    }

    if (state.sendModeMenuOpen) {
      const bd = document.createElement("div");
      bd.className = "popover-backdrop";
      bd.innerHTML = `<div class="floating-popover" style="bottom:68px; right:12px; width:232px;" onclick="event.stopPropagation()"><div style="padding:10px 13px 6px; font-size:11.5px; font-weight:600; color:var(--ink-secondary); border-bottom:0.5px solid var(--rule);">发送时机策略</div>${[["queue", t("sendQueue")], ["interject", t("sendInterject")], ["interrupt", t("sendInterrupt")]].map(([k, lbl]) => `<button type="button" class="row-item" style="min-height:42px; font-size:13px;" data-send-mode="${k}"><span style="flex:1;">${lbl}</span><span style="color:var(--accent); font-weight:700;">${state.sendMode === k ? "✓" : ""}</span></button>`).join("")}</div>`;
      bd.onclick = () => { state.sendModeMenuOpen = false; renderModalLayer(); };
      layer.appendChild(bd);
      bd.querySelectorAll("[data-send-mode]").forEach((b) => { b.onclick = () => { state.sendMode = b.dataset.sendMode; state.sendModeMenuOpen = false; emitHaptic("selection", `切发送策略: ${state.sendMode}`); renderAll(); }; });
    }

    if (state.fullApprovalOpen) {
      renderFullApprovalOverlay(layer);
    }

    if (state.stopPickerKind) {
      renderStopPickerOverlay(layer);
    }

    if (state.previewFile) {
      renderFilePreviewOverlay(layer);
    }

    if (state.identityEditor) {
      renderIdentityEditorSheet(layer);
    }

    if (state.sourcesSheetOpen) {
      const sh = document.createElement("div");
      sh.className = "phone-sheet";
      sh.style.inset = "190px 0 0 0";
      sh.innerHTML = `<div class="sheet-bar"><strong style="font-size:15px;">${t("sourcesTitle")}</strong><button type="button" class="glass-pill pressable" id="btnCloseSources" style="min-height:30px; padding:3px 12px; font-size:12.5px; font-weight:600;">完成</button></div><div style="padding:13px 15px; overflow-y:auto; display:flex; flex-direction:column; gap:10px;"><div class="clio-card" style="padding:12px;"><div style="font-weight:600; font-size:13.5px;">W3C 中文排版需求 (CLREQ)</div><div style="font-size:12px; color:var(--ink-secondary); margin-top:4px;">§6.1.1 避头尾「先挤进后推出」；§6.3.3 中西混排 ≤ 1/4 em 光学间距。</div></div><div class="clio-card" style="padding:12px;"><div style="font-weight:600; font-size:13.5px;">Apple HIG · Materials</div><div style="font-size:12px; color:var(--ink-secondary); margin-top:4px;">官方红线：Don't use Liquid Glass in the content layer —— 仅限悬浮导航与控件层。</div></div></div>`;
      layer.appendChild(sh);
      sh.querySelector("#btnCloseSources").onclick = () => { state.sourcesSheetOpen = false; renderModalLayer(); };
    }
  }

  function approveFullSlip(viaLabel) {
    const methodText = viaLabel === "assistive" ? "辅助/点按等效批准" : "右滑解锁批准";
    emitHaptic("confirm", (state.lang === "A" || state.lang === "AC") ? `朱印盖章完成 (${methodText})` : (state.lang === "B" ? `棘轮锁止完成 (${methodText})` : `温和确认完成 (${methodText})`));
    state.fullApprovalVerdict = "allowed";
    state.inlineApprovalStatus = "once";
    renderModalLayer();
  }

  function renderFullApprovalOverlay(layer) {
    const ov = document.createElement("div");
    ov.className = "approval-overlay";
    const isAllowed = state.fullApprovalVerdict === "allowed";
    const isRejected = state.fullApprovalVerdict === "rejected";
    const sealCh = escHtml((state.assistant.sealChar || "克").slice(0, 1));
    const aName = escHtml(state.assistant.name || "小克");
    let stampOverlay = "";
    if (isAllowed) {
      if (state.lang === "A" || state.lang === "AC") stampOverlay = `<div style="position:absolute; right:16px; bottom:16px; text-align:center;"><div class="clio-seal-stamp">${sealCh}</div><div class="font-mono" style="font-size:10px; color:var(--seal); margin-top:4px;">11-25 21:42</div></div>`;
      else if (state.lang === "B") stampOverlay = `<div style="position:absolute; right:16px; bottom:16px;" class="ratchet-stamp">AUTHORIZED · 21:42:10</div>`;
      else stampOverlay = `<div style="position:absolute; right:16px; bottom:16px; padding:6px 12px; border-radius:999px; background:var(--accent-wash); color:var(--accent); font-size:12px; font-weight:600;">✓ 已温润确认执行</div>`;
    } else if (isRejected) {
      stampOverlay = `<div style="position:absolute; right:16px; bottom:16px; padding:5px 11px; border-radius:999px; border:1.5px solid var(--danger); color:var(--danger); font-size:12px; font-weight:700;">已${t("rejectBtn")}</div>`;
    }

    const perforationSvg = (state.lang === "A" || state.lang === "AC") ? `<svg class="slip-perforation" viewBox="0 0 320 10" preserveAspectRatio="none"><path d="M0,10 Q8,0 16,10 T32,10 T48,10 T64,10 T80,10 T96,10 T112,10 T128,10 T144,10 T160,10 T176,10 T192,10 T208,10 T224,10 T240,10 T256,10 T272,10 T288,10 T304,10 T320,10" fill="var(--surface)" stroke="var(--rule)" stroke-width="0.8"/></svg>` : "";
    const middleBodyHtml = state.lang === "B" ? `
      <div class="kv-table"><span class="kv-key">操作类型</span><span class="kv-val font-mono">ssh_run</span><span class="kv-key">目标环境</span><span class="kv-val">远山 · Prod-CN2</span><span class="kv-key">污染源</span><span class="kv-val" style="color:var(--warn);">本轮读过外网</span></div>
      <div class="clio-inner-block" style="padding:9px 11px; margin-bottom:10px;"><pre class="code-pre" style="padding:0; max-height:74px;">cp /tmp/parsed.conf /etc/nginx/conf.d/site.conf && nginx -t && systemctl reload nginx</pre></div>` : `
      <div style="display:flex; align-items:center; gap:10px; margin-bottom:12px;"><div class="avatar-wrap" style="width:36px;height:36px;overflow:hidden;">${renderAvatarMarkup("assistant", 34, "notification")}</div><div><div style="font-size:11px; color:var(--ink-secondary);">来自</div><div style="font-size:17px; font-weight:700;" class="font-mark">${aName} · 远山助手</div></div></div>
      <div class="taint-banner" style="margin-bottom:10px;"><span>⚠</span><span>${t("webWarn")}</span></div>
      <div class="clio-inner-block" style="padding:9px 11px; margin-bottom:12px;"><pre class="code-pre" style="padding:0; max-height:76px;">cp /tmp/parsed.conf /etc/nginx/conf.d/site.conf && nginx -t && systemctl reload nginx</pre></div>`;

    const ratchetTicksHtml = state.lang === "B" ? `<div class="ratchet-ticks">${Array.from({ length: 8 }).map((_, i) => `<span class="ratchet-tick" data-tick="${i}"></span>`).join("")}</div>` : "";
    const slideLabelText = (state.lang === "A" || state.lang === "AC") ? "右滑到底 · 盖朱印" : (state.lang === "B" ? "SLIDE TO LOCK · 棘轮解锁" : "向右轻推 · 确认执行");

    ov.innerHTML = `
      <div style="display:flex; justify-content:space-between; align-items:center;"><span class="filter-pill">还有 1 张</span><button type="button" class="glass-pill pressable" id="btnCloseFullApproval" style="min-height:32px; padding:3px 13px; font-weight:600;">完成</button></div>
      <div class="approval-slip ${state.fullApprovalVerdict ? "stamped" : ""}">${perforationSvg}<div style="display:flex; justify-content:space-between; font-size:11.5px; color:var(--ink-secondary); margin-bottom:10px;"><strong style="letter-spacing:1.2px;">${state.lang === "B" ? "AUTHORIZATION MANIFEST" : t("approvalSheet")}</strong><span class="font-mono">21:42</span></div>${middleBodyHtml}${stampOverlay}</div>
      <div style="text-align:center;">
        <div class="font-mark" style="font-size:18px; font-weight:700; margin-bottom:3px;">${isAllowed ? t("approved") : (isRejected ? t("rejected") : `${aName} 在等你${t("approvalSheet")}`)}</div>
        <div style="font-size:12.5px; color:var(--ink-secondary); margin-bottom:10px;">${isAllowed ? `${aName}已继续执行。` : (isRejected ? "已拦截未执行。" : slideLabelText)}</div>
        ${!state.fullApprovalVerdict ? `
          <div class="slide-track" id="approvalSlideTrack"><div class="slide-fill" id="approvalSlideFill" style="width:54px;"></div>${ratchetTicksHtml}<div class="slide-label" id="approvalSlideLabel">${slideLabelText}</div><div class="slide-knob" id="approvalSlideKnob" role="slider" aria-label="${slideLabelText}">›</div></div>
          <button type="button" class="a11y-approve-btn" id="btnAccessibleApprove" aria-label="已核对命令与外网风险，确认并落款批准">✓ 确认并落款批准（VoiceOver / 点按等效）</button>
          <button type="button" class="reply-action-btn" id="btnRejectFullSlip" style="margin:6px auto 0; font-size:13.5px; padding:6px 18px;">${t("rejectBtn")}</button>
        ` : `<button type="button" class="filter-pill active" id="btnReopenFullSlip" style="padding:7px 18px;">再试一次拖动 / 重置演示</button>`}
      </div>
    `;
    layer.appendChild(ov);
    const cleanup = bindSlideTrack(ov);
    ov.querySelector("#btnCloseFullApproval").onclick = () => { cleanup(); state.fullApprovalOpen = false; renderAll(); };
    const accBtn = ov.querySelector("#btnAccessibleApprove");
    if (accBtn) accBtn.onclick = () => { cleanup(); approveFullSlip("assistive"); };
    const rej = ov.querySelector("#btnRejectFullSlip");
    if (rej) rej.onclick = () => { cleanup(); emitHaptic("alert", "拒绝审批"); state.fullApprovalVerdict = "rejected"; renderModalLayer(); };
    const reo = ov.querySelector("#btnReopenFullSlip");
    if (reo) reo.onclick = () => { cleanup(); state.fullApprovalVerdict = null; state.inlineApprovalStatus = "pending"; renderModalLayer(); };
  }

  function renderStopPickerOverlay(layer) {
    const cfg = {
      size: { title: "阅读字号", defaultVal: 17, stops: TOKENS.readingSizes.map((s, i) => ({ val: s, name: ["小", "较小", "中", "大", "特大", "超大"][i], detail: `${s} 点` })), get: () => state.readingSize, set: (v) => { state.readingSize = v; } },
      lineHeight: { title: "正文行距", defaultVal: 1.65, stops: TOKENS.lineHeights.map((l) => ({ val: l.value, name: l.name, detail: l.detail })), get: () => state.lineHeight, set: (v) => { state.lineHeight = v; } },
      paragraphGap: { title: "段落间距", defaultVal: 13, stops: TOKENS.paragraphGaps.map((p) => ({ val: p.value, name: p.name, detail: p.detail })), get: () => state.paragraphGap, set: (v) => { state.paragraphGap = v; } },
      uiScale: { title: "界面缩放", defaultVal: 1.0, stops: TOKENS.uiScaleLevels.map((u) => ({ val: u.factor, name: u.title, detail: `${Math.round(u.factor * 100)}%` })), get: () => state.uiScale, set: (v) => { state.uiScale = v; } },
      petSize: { title: "伴读宠物大小", defaultVal: 1.0, stops: TOKENS.petSizes.map((s) => ({ val: s.factor, name: s.name, detail: s.detail })), get: () => state.petSizeFactor, set: (v) => { state.petSizeFactor = v; renderBottomDock(); } }
    }[state.stopPickerKind];
    const stepH = 32, count = cfg.stops.length, trackH = stepH * count;
    const curIdx = Math.max(0, cfg.stops.findIndex((s) => s.val === cfg.get()));
    const bd = document.createElement("div");
    bd.className = "stop-popover-backdrop";
    bd.innerHTML = `<div class="stop-popover-card" onclick="event.stopPropagation()"><div class="stop-labels-col">${cfg.stops.slice().reverse().map((s, rev) => { const realIdx = count - 1 - rev; return `<button type="button" class="stop-label-btn ${realIdx === curIdx ? "active" : ""}" data-stop-idx="${realIdx}"><span>${s.name}${s.val === cfg.defaultVal ? " ·" : ""}</span><span class="font-mono" style="font-size:12px; opacity:0.75;">${s.detail}</span></button>`; }).join("")}</div><div class="stop-capsule-track" id="stopCapsuleTrack" style="height:${trackH}px;"><div class="stop-capsule-fill" id="stopCapsuleFill" style="height:${Math.min(trackH, Math.max(28, stepH * (curIdx + 0.5) + 12))}px;"><div class="stop-capsule-handle"></div></div></div></div>`;
    bd.onclick = () => { state.stopPickerKind = null; renderAll(); };
    layer.appendChild(bd);

    const fillEl = bd.querySelector("#stopCapsuleFill");
    const labelBtns = bd.querySelectorAll("[data-stop-idx]");
    function pickStop(idx) {
      const clamped = Math.max(0, Math.min(count - 1, idx));
      const item = cfg.stops[clamped];
      if (cfg.get() === item.val) return;
      cfg.set(item.val);
      emitHaptic(item.val === cfg.defaultVal ? "detent" : "tick", `${cfg.title} → ${item.detail}`);
      applyThemeVariables();
      fillEl.style.height = `${Math.min(trackH, Math.max(28, stepH * (clamped + 0.5) + 12))}px`;
      labelBtns.forEach((b) => b.classList.toggle("active", Number(b.dataset.stopIdx) === clamped));
      const rv = document.getElementById(`settingVal-${state.stopPickerKind}`);
      if (rv) rv.textContent = `${item.detail} ⇵`;
    }
    labelBtns.forEach((btn) => { btn.onclick = () => pickStop(Number(btn.dataset.stopIdx)); });
    const track = bd.querySelector("#stopCapsuleTrack");
    let draggingStop = false;
    const handleStopDrag = (clientY) => { const rect = track.getBoundingClientRect(); pickStop(count - 1 - Math.floor((clientY - rect.top) / stepH)); };
    track.onpointerdown = (e) => { e.preventDefault(); draggingStop = true; track.setPointerCapture(e.pointerId); handleStopDrag(e.clientY); };
    track.onpointermove = (e) => { if (draggingStop) handleStopDrag(e.clientY); };
    track.onpointerup = track.onpointercancel = () => { draggingStop = false; };
  }

  function renderFilePreviewOverlay(layer) {
    const sh = document.createElement("div");
    sh.className = "phone-sheet";
    let body = "";
    if (state.previewFile === "html") {
      const isFps = state.htmlChartTab === "fps";
      body = `<div class="clio-card" style="padding:13px;"><div style="font-size:11.5px; color:var(--ok); font-weight:600; margin-bottom:8px;">⛨ 离线隔离互动预览（严格断网 CSP）</div><div style="display:flex; gap:6px; margin-bottom:10px;"><button type="button" class="filter-pill ${!isFps ? "active" : ""}" id="btnHtmlTabContrast">WCAG 对比度</button><button type="button" class="filter-pill ${isFps ? "active" : ""}" id="btnHtmlTabFps">120Hz 瓦片预算</button></div><svg viewBox="0 0 300 120" style="width:100%; height:auto;">${isFps ? `<rect x="14" y="64" width="44" height="44" rx="6" fill="var(--ok)" opacity="0.85"></rect><rect x="86" y="72" width="44" height="36" rx="6" fill="var(--ok)"></rect><rect x="158" y="42" width="44" height="66" rx="6" fill="var(--accent)"></rect><rect x="230" y="20" width="44" height="88" rx="6" fill="var(--danger)" opacity="0.65"></rect><text x="16" y="56" font-size="9.5" fill="var(--ink)">3.1ms</text><text x="88" y="64" font-size="9.5" fill="var(--ink)">2.4ms</text><text x="160" y="34" font-size="9.5" fill="var(--ink)">5.8ms</text><text x="232" y="14" font-size="9.5" fill="var(--danger)">8.33上限</text>` : `<rect x="14" y="54" width="44" height="54" rx="6" fill="var(--accent)" opacity="0.65"></rect><rect x="86" y="28" width="44" height="80" rx="6" fill="var(--accent)"></rect><rect x="158" y="34" width="44" height="74" rx="6" fill="var(--ok)"></rect><rect x="230" y="42" width="44" height="66" rx="6" fill="var(--seal)"></rect><text x="16" y="46" font-size="9.5" fill="var(--ink)">4.56:1</text><text x="88" y="21" font-size="9.5" fill="var(--ink)">15.3:1</text><text x="160" y="27" font-size="9.5" fill="var(--ink)">117过</text><text x="232" y="35" font-size="9.5" fill="var(--ink)">AA+</text>`}</svg></div>`;
    } else if (state.previewFile === "diff") {
      body = `<div class="clio-inner-block" style="padding:10px 12px; font-family:var(--font-mono); font-size:11.5px; line-height:1.55;"><div style="color:var(--ink-secondary);">--- a/App/Sources/Haptics.swift</div><div style="color:var(--ink-secondary); margin-bottom:6px;">+++ b/App/Sources/Haptics.swift</div><div style="background:color-mix(in srgb, var(--danger) 14%, transparent); color:var(--danger);">- struct PressStyle { var haptic = true }</div><div style="background:color-mix(in srgb, var(--ok) 14%, transparent); color:var(--ok);">+ struct PressStyle { var haptic = false } // Sec 15</div></div>`;
    } else {
      body = `<div class="font-reading">${state.previewFile === "pdf" ? `<h2 class="prose-h2">iOS26-HIG-Materials.pdf · FTS5</h2><p class="prose-p">与聊天正文及用户气泡共用同一个 FontOpticalProfile + SafeLineBox 排版度量（此处演示书案长文阅读一致性）。</p>` : renderStreamingMarkdown(SECTION46_SAMPLE.fullMarkdown, false)}</div>`;
    }
    sh.innerHTML = `<div class="sheet-bar"><strong style="font-size:15px;">文件预览</strong><button type="button" class="glass-pill pressable" id="btnClosePreview" style="min-height:30px; padding:3px 12px; font-size:12.5px; font-weight:600;">完成</button></div><div style="padding:14px 16px; overflow-y:auto; flex:1;">${body}</div>`;
    layer.appendChild(sh);
    sh.querySelector("#btnClosePreview").onclick = () => { state.previewFile = null; renderModalLayer(); };
    const bCon = sh.querySelector("#btnHtmlTabContrast"), bFps = sh.querySelector("#btnHtmlTabFps");
    if (bCon) bCon.onclick = () => { emitHaptic("selection", "切对比度图表"); state.htmlChartTab = "contrast"; renderModalLayer(); };
    if (bFps) bFps.onclick = () => { emitHaptic("selection", "切 120Hz 预算"); state.htmlChartTab = "fps"; renderModalLayer(); };
  }

  function bindSlideTrack(ov) {
    const track = ov.querySelector("#approvalSlideTrack");
    const knob = ov.querySelector("#approvalSlideKnob");
    const fill = ov.querySelector("#approvalSlideFill");
    const label = ov.querySelector("#approvalSlideLabel");
    const ticks = ov.querySelectorAll(".ratchet-tick");
    if (!track || !knob) return () => {};
    let dragging = false, activePointerId = null, startX = 0, progress = 0, lastTick = 0;

    function resetTrackVisuals() {
      knob.style.transition = "transform 340ms cubic-bezier(0.22, 1.35, 0.36, 1)";
      fill.style.transition = "width 340ms cubic-bezier(0.22, 1.35, 0.36, 1)";
      knob.style.transform = "translateX(0px) scale(1)";
      fill.style.width = "54px";
      label.style.opacity = "1";
      ticks.forEach((tk) => tk.classList.remove("lit"));
    }

    function safeCancel(reasonLabel) {
      if (!dragging) return;
      dragging = false;
      activePointerId = null;
      progress = 0;
      lastTick = 0;
      emitHaptic("tick", reasonLabel || "手势中断 · 安全回弹未批准");
      resetTrackVisuals();
    }

    const onWindowBlur = () => safeCancel("窗口失焦中断 · 安全回弹未批准");
    const onVisibilityChange = () => { if (document.hidden) safeCancel("切后台中断 · 安全回弹未批准"); };
    window.addEventListener("blur", onWindowBlur);
    document.addEventListener("visibilitychange", onVisibilityChange);

    function cleanup() {
      window.removeEventListener("blur", onWindowBlur);
      document.removeEventListener("visibilitychange", onVisibilityChange);
    }

    knob.onpointerdown = (e) => {
      e.preventDefault();
      try { knob.setPointerCapture(e.pointerId); } catch (_) {}
      dragging = true;
      activePointerId = e.pointerId;
      startX = e.clientX;
      progress = 0;
      knob.style.transition = "none";
      fill.style.transition = "none";
    };
    knob.onpointermove = (e) => {
      if (!dragging || e.pointerId !== activePointerId) return;
      const travel = Math.max(1, track.clientWidth - knob.clientWidth - 10);
      progress = Math.min(1, Math.max(0, (e.clientX - startX) / travel));
      knob.style.transform = `translateX(${travel * progress}px) scale(${1 + 0.05 * progress})`;
      fill.style.width = `${54 + travel * progress}px`;
      label.style.opacity = String(Math.max(0, 1 - progress * 1.6));
      ticks.forEach((tk, idx) => tk.classList.toggle("lit", progress >= (idx + 1) / (ticks.length + 1)));
      const bucket = Math.floor(progress * 8);
      if (bucket !== lastTick) { lastTick = bucket; emitHaptic("tick", `审批滑动 ${Math.round(progress * 100)}%`); }
    };
    // Strictly ONLY explicit pointerup on the active pointer above 84% may approve!
    knob.onpointerup = (e) => {
      if (!dragging || e.pointerId !== activePointerId) return;
      const finalProgress = progress;
      dragging = false;
      activePointerId = null;
      progress = 0;
      if (finalProgress > 0.84) {
        cleanup();
        approveFullSlip("slide");
      } else {
        emitHaptic("tick", "未达阈值松手回弹");
        resetTrackVisuals();
      }
    };
    // System interruption / pointercancel MUST NEVER approve even when progress > 0.84!
    knob.onpointercancel = () => {
      safeCancel("手势被系统取消 (pointercancel) · 安全回弹未批准");
    };
    return cleanup;
  }

  function openIdentityEditor(kind) {
    state.identityEditor = kind;
    state.identityDraft = kind === "assistant"
      ? { ...state.assistant }
      : { ...state.userProfile };
    emitHaptic("silent", `打开${kind === "assistant" ? "助手" : "我的"}身份编辑器`);
    renderModalLayer();
  }

  function renderIdentityEditorSheet(layer) {
    const isAst = state.identityEditor === "assistant";
    const d = state.identityDraft;
    const sh = document.createElement("div");
    sh.className = "phone-sheet";
    sh.style.inset = "54px 0 0 0";

    const previewMarkup = () => {
      if (isAst) {
        if (d.avatarMode === "photo" && d.avatarPhoto) return `<img class="chat-avatar-img" src="${d.avatarPhoto}" alt="" />`;
        if (d.avatarMode === "monogram") return `<span class="chat-avatar-mono" style="background:${d.avatarTint}; font-size:28px;">${escHtml((d.avatarMonogram || d.name || "克").slice(0, 1))}</span>`;
        const pid = d.followPet ? state.petActiveId : (d.avatarPetId || "xiaoke");
        if (pid === "custom" && state.petCustomPhoto) return `<img class="chat-avatar-img" src="${state.petCustomPhoto}" alt="" />`;
        return `<canvas data-pet-canvas="1" data-pet-id="${escHtml(pid)}" data-pet-still="1" width="48" height="48" style="width:50px;height:50px;image-rendering:pixelated;"></canvas>`;
      }
      if (d.avatarMode === "photo" && d.avatarPhoto) return `<img class="chat-avatar-img" src="${d.avatarPhoto}" alt="" />`;
      if (d.avatarMode === "pet") {
        const pid = d.avatarPetId || "roubao";
        if (pid === "custom" && state.petCustomPhoto) return `<img class="chat-avatar-img" src="${state.petCustomPhoto}" alt="" />`;
        return `<canvas data-pet-canvas="1" data-pet-id="${escHtml(pid)}" data-pet-still="1" width="48" height="48" style="width:50px;height:50px;image-rendering:pixelated;"></canvas>`;
      }
      return `<span class="chat-avatar-mono" style="background:${d.avatarTint}; font-size:28px;">${escHtml((d.avatarMonogram || d.name || "我").slice(0, 1))}</span>`;
    };

    const modeTabs = isAst
      ? [["followPet", "跟随立宠"], ["pet", "指定宠物"], ["monogram", "单字圆章"], ["photo", "相册/配图"]]
      : [["monogram", "单字圆章"], ["pet", "选一只宠物"], ["photo", "相册/配图"]];

    const petPickRow = `
      <div style="display:flex; gap:6px; flex-wrap:wrap; margin-top:6px;">
        ${TOKENS.petCatalog.map((p) => {
          const active = (d.avatarPetId || "xiaoke") === p.id;
          return `<button type="button" class="filter-pill ${active ? "active" : ""}" style="font-size:11.5px; display:inline-flex; align-items:center; gap:5px;" data-id-pet="${p.id}"><canvas data-pet-canvas="1" data-pet-id="${p.id}" data-pet-still="1" width="48" height="48" style="width:18px;height:18px;image-rendering:pixelated;"></canvas>${escHtml(activePetDisplayName(p.id))}</button>`;
        }).join("")}
      </div>
    `;

    const monogramBlock = `
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:6px;">
        <div style="display:flex; align-items:center; gap:8px;">
          <span style="font-size:12px; color:var(--ink-secondary); white-space:nowrap;">圆章单字</span>
          <input class="field-input" id="idMonogramInput" maxlength="2" style="width:76px; text-align:center; font-weight:700;" value="${escHtml(d.avatarMonogram || "")}" />
        </div>
        <div class="swatch-row">
          ${TOKENS.monogramTints.map((sw) => `<button type="button" class="swatch-dot ${d.avatarTint === sw.hex ? "active" : ""}" style="background:${sw.hex};" title="${sw.name}" data-id-tint="${sw.hex}"></button>`).join("")}
        </div>
      </div>
    `;

    const photoBlock = `
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:6px;">
        <div style="display:flex; gap:6px; flex-wrap:wrap;">
          ${TOKENS.presetPortraits.map((pr) => `<button type="button" class="filter-pill ${d.avatarPhoto === pr.uri ? "active" : ""}" style="font-size:11.5px; display:inline-flex; align-items:center; gap:5px;" data-id-preset="${pr.id}"><img src="${pr.uri}" style="width:18px;height:18px;border-radius:50%;" />${pr.name}</button>`).join("")}
          <button type="button" class="filter-pill active" id="btnUploadIdPhoto">📁 从本机上传图片</button>
        </div>
        <input type="file" id="idPhotoFileInput" accept="image/*" style="display:none;" />
      </div>
    `;

    let modeDetailHtml = "";
    if (d.avatarMode === "followPet") {
      modeDetailHtml = `<div style="font-size:12px; color:var(--ink-secondary); margin-top:4px;">已锁定跟随伴读宠（当前：<strong>${escHtml(activePetDisplayName())}</strong>）；若想改独立头像，点上方「指定宠物 / 单字圆章 / 相册」。</div>`;
    } else if (d.avatarMode === "pet") {
      modeDetailHtml = petPickRow;
    } else if (d.avatarMode === "monogram") {
      modeDetailHtml = monogramBlock;
    } else {
      modeDetailHtml = photoBlock;
    }

    sh.innerHTML = `
      <div class="sheet-bar">
        <button type="button" class="reply-action-btn" id="btnCancelIdEdit" style="font-size:13.5px; color:var(--ink-secondary);">取消</button>
        <strong style="font-size:15px;">${isAst ? "自定义助手名帖与头像" : "自定义我的称呼与头像"}</strong>
        <button type="button" class="glass-pill pressable" id="btnSaveIdEdit" style="min-height:30px; padding:3px 12px; font-size:12.5px; font-weight:700; color:var(--accent);">保存</button>
      </div>
      <div style="padding:14px 16px 24px; overflow-y:auto; flex:1; display:flex; flex-direction:column; gap:12px;">
        <div class="clio-card" style="padding:12px; display:flex; align-items:center; gap:12px;">
          <div class="chat-avatar-btn lg" id="idLivePreview">${previewMarkup()}</div>
          <div style="flex:1; min-width:0;">
            <div style="font-size:16px; font-weight:700;" class="font-mark" id="idPreviewName">${escHtml(d.name || (isAst ? "未命名助手" : "我"))}</div>
            <div style="font-size:11.5px; color:var(--ink-secondary); margin-top:2px;" id="idPreviewSub">${isAst ? escHtml(d.subtitle || "私人 AI 伴读助手") : "出现在聊天正文右气泡旁（开启双方头像时可见）"}</div>
          </div>
          ${isAst ? `<span class="clio-seal-stamp" id="idPreviewSeal" style="width:32px;height:32px;font-size:18px;border-radius:5px;animation:none;">${escHtml((d.sealChar || d.name || "克").slice(0, 1))}</span>` : ""}
        </div>

        <div class="clio-card" style="padding:12px; display:flex; flex-direction:column; gap:9px;">
          <div>
            <div style="font-size:12px; font-weight:600; color:var(--ink-secondary); margin-bottom:4px;">${isAst ? "助手名字" : "我的称呼"}</div>
            <input class="field-input" id="idNameInput" value="${escHtml(d.name)}" placeholder="${isAst ? "例如：小克 / 青砚 / 架构师" : "我的名字或昵称"}" />
          </div>
          ${isAst ? `
            <div>
              <div style="font-size:12px; font-weight:600; color:var(--ink-secondary); margin-bottom:4px;">一句话定位</div>
              <input class="field-input" id="idSubInput" value="${escHtml(d.subtitle)}" placeholder="例如：沉静克制 · 长文梳理伙伴" />
            </div>
            <div style="display:flex; align-items:center; gap:10px;">
              <div style="flex:1;">
                <div style="font-size:12px; font-weight:600; color:var(--ink-secondary); margin-bottom:4px;">专属朱印单字（侧栏 / 审批盖章落款）</div>
                <input class="field-input" id="idSealInput" maxlength="1" value="${escHtml(d.sealChar)}" placeholder="克" style="width:88px; text-align:center; font-weight:700;" />
              </div>
            </div>
          ` : ""}
        </div>

        <div class="clio-card" style="padding:12px;">
          <div style="font-size:12px; font-weight:600; color:var(--ink-secondary); margin-bottom:7px;">头像形式（正文 &amp; 顶栏 &amp; 审批同步生效）</div>
          <div style="display:flex; gap:6px; flex-wrap:wrap; margin-bottom:6px;">
            ${modeTabs.map(([k, lbl]) => `<button type="button" class="filter-pill ${d.avatarMode === k ? "active" : ""}" style="font-size:11.5px;" data-id-mode="${k}">${lbl}</button>`).join("")}
          </div>
          ${modeDetailHtml}
        </div>
      </div>
    `;
    layer.appendChild(sh);
    drawAllPetCanvases(performance.now());

    sh.querySelector("#btnCancelIdEdit").onclick = () => {
      state.identityEditor = null;
      state.identityDraft = null;
      renderModalLayer();
    };
    sh.querySelector("#btnSaveIdEdit").onclick = () => {
      const cleanName = (d.name || "").trim() || (isAst ? "小克" : "我");
      d.name = cleanName;
      if (isAst) {
        d.sealChar = (d.sealChar || cleanName).trim().slice(0, 1) || "克";
        d.followPet = d.avatarMode === "followPet";
        state.assistant = { ...d };
      } else {
        d.avatarMonogram = (d.avatarMonogram || cleanName).trim().slice(0, 1) || "我";
        state.userProfile = { ...d };
      }
      state.identityEditor = null;
      state.identityDraft = null;
      emitHaptic("confirm", `保存${isAst ? "助手" : "我的"}身份设定`);
      showToast(`已保存「${cleanName}」的定制头像与称呼 ✓`);
      renderAll();
    };

    const nameEl = sh.querySelector("#idNameInput");
    if (nameEl) nameEl.oninput = (e) => {
      d.name = e.target.value;
      const pn = sh.querySelector("#idPreviewName");
      if (pn) pn.textContent = d.name || (isAst ? "未命名助手" : "我");
    };
    const subEl = sh.querySelector("#idSubInput");
    if (subEl) subEl.oninput = (e) => {
      d.subtitle = e.target.value;
      const ps = sh.querySelector("#idPreviewSub");
      if (ps) ps.textContent = d.subtitle || "私人 AI 伴读助手";
    };
    const sealEl = sh.querySelector("#idSealInput");
    if (sealEl) sealEl.oninput = (e) => {
      d.sealChar = e.target.value.slice(0, 1);
      const pSeal = sh.querySelector("#idPreviewSeal");
      if (pSeal) pSeal.textContent = d.sealChar || d.name.slice(0, 1) || "克";
    };
    const monoEl = sh.querySelector("#idMonogramInput");
    if (monoEl) monoEl.oninput = (e) => {
      d.avatarMonogram = e.target.value.slice(0, 1);
      const pv = sh.querySelector("#idLivePreview");
      if (pv) pv.innerHTML = previewMarkup();
    };

    sh.querySelectorAll("[data-id-mode]").forEach((b) => {
      b.onclick = () => {
        d.avatarMode = b.dataset.idMode;
        if (isAst) d.followPet = d.avatarMode === "followPet";
        emitHaptic("selection", `切头像形式 → ${d.avatarMode}`);
        renderModalLayer();
      };
    });
    sh.querySelectorAll("[data-id-pet]").forEach((b) => {
      b.onclick = () => {
        d.avatarPetId = b.dataset.idPet;
        emitHaptic("selection", `选中宠物头像 → ${activePetDisplayName(d.avatarPetId)}`);
        renderModalLayer();
      };
    });
    sh.querySelectorAll("[data-id-tint]").forEach((b) => {
      b.onclick = () => {
        d.avatarTint = b.dataset.idTint;
        emitHaptic("selection", "切换圆章底色");
        renderModalLayer();
      };
    });
    sh.querySelectorAll("[data-id-preset]").forEach((b) => {
      b.onclick = () => {
        const found = TOKENS.presetPortraits.find((x) => x.id === b.dataset.idPreset);
        if (found) {
          d.avatarPhoto = found.uri;
          emitHaptic("selection", `选用图样: ${found.name}`);
          renderModalLayer();
        }
      };
    });
    const upBtn = sh.querySelector("#btnUploadIdPhoto");
    const upInp = sh.querySelector("#idPhotoFileInput");
    if (upBtn && upInp) {
      upBtn.onclick = () => upInp.click();
      upInp.onchange = (e) => {
        const file = e.target.files?.[0];
        if (!file) return;
        const r = new FileReader();
        r.onload = () => {
          d.avatarPhoto = r.result;
          emitHaptic("confirm", "导入头像照片");
          renderModalLayer();
        };
        r.readAsDataURL(file);
      };
    }
  }

  // ==================== Inspector & Bindings ====================
  function renderInspector() {
    const box = document.getElementById("nativeInspector");
    const info = INSPECTOR_MAP[state.scene] || INSPECTOR_MAP.chat;
    box.innerHTML = `
      <div><div style="color:#8F98AA; font-size:11px; margin-bottom:4px;">映射 Clio 真实 Swift 源码</div><div>${info.files.map((f) => `<span class="native-chip">${f}</span>`).join("")}</div></div>
      <div><div style="color:#8F98AA; font-size:11px; margin-bottom:4px;">对应原生 iOS 26 API</div><div>${info.apis.map((a) => `<span class="native-chip" style="color:#6EE7B7;">${a}</span>`).join("")}</div></div>
      <div style="grid-column: 1 / -1; color:#B6BFCE; border-top:1px solid #2A2E38; padding-top:7px;"><strong style="color:#E5E7EB;">工程注记：</strong>${info.notes}</div>
    `;
  }

  function syncStudioActiveButtons() {
    document.querySelectorAll("#langSwitch .seg-btn").forEach((b) => b.classList.toggle("active", b.dataset.lang === state.lang));
    const palWrap = document.getElementById("acPaletteSwitch");
    if (palWrap) {
      palWrap.style.display = state.lang === "AC" ? "flex" : "none";
      palWrap.querySelectorAll("[data-ac-palette]").forEach((b) => b.classList.toggle("active", b.dataset.acPalette === state.acPalette));
    }
    const faceBtn = document.getElementById("btnStudioFacesToggle");
    if (faceBtn) {
      faceBtn.classList.toggle("active", state.showChatFaces);
      faceBtn.textContent = `正文双方头像：${state.showChatFaces ? "开" : "关"}`;
    }
    document.querySelectorAll("#modeSwitch .seg-btn").forEach((b) => b.classList.toggle("active", b.dataset.mode === state.mode));
    document.querySelectorAll("#toneSwitch .seg-btn").forEach((b) => b.classList.toggle("active", b.dataset.tone === state.tone));
    document.querySelectorAll("#viewStateSwitch .seg-btn").forEach((b) => b.classList.toggle("active", b.dataset.viewState === state.viewState));
    document.querySelector('[data-toggle="ax"]').classList.toggle("active", state.ax);
    document.querySelector('[data-toggle="rm"]').classList.toggle("active", state.reduceMotion);
    document.querySelector('[data-toggle="rt"]').classList.toggle("active", state.reduceTransparency);
    document.querySelectorAll("#sceneGroupTabs .filter-pill").forEach((b) => b.classList.toggle("active", b.dataset.group === state.activeGroup));
    document.querySelectorAll("#sceneGrid .scene-btn").forEach((b) => b.classList.toggle("active", b.dataset.scene === state.scene));
  }

  function bindStudioControls() {
    document.getElementById("dynamicIsland").onclick = () => { emitHaptic("silent", "展开灵动岛实况"); state.modelMenuOpen = false; state.moreMenuOpen = false; state.diExpanded = !state.diExpanded; renderModalLayer(); };
    document.querySelectorAll("#langSwitch .seg-btn").forEach((b) => {
      b.onclick = () => { state.lang = b.dataset.lang; state.tone = TOKENS.languages[state.lang].defaultTone || "daily"; emitHaptic("detent", `切换设计语言 → ${TOKENS.languages[state.lang].name}`); renderAll(); };
    });
    document.querySelectorAll("#acPaletteSwitch [data-ac-palette]").forEach((b) => {
      b.onclick = () => {
        state.acPalette = b.dataset.acPalette;
        emitHaptic("selection", `切换 AC 色盘 → ${TOKENS.languages.AC.palettes[state.acPalette].name}`);
        renderAll();
      };
    });
    const studioFaceBtn = document.getElementById("btnStudioFacesToggle");
    if (studioFaceBtn) {
      studioFaceBtn.onclick = () => {
        state.showChatFaces = !state.showChatFaces;
        emitHaptic("selection", `正文双方头像 → ${state.showChatFaces ? "开" : "关"}`);
        renderAll();
      };
    }
    document.querySelectorAll("#modeSwitch .seg-btn").forEach((b) => {
      b.onclick = () => { state.mode = b.dataset.mode; emitHaptic("selection", `外观 → ${state.mode}`); renderAll(); };
    });
    document.querySelectorAll("#toneSwitch .seg-btn").forEach((b) => {
      b.onclick = () => { state.tone = b.dataset.tone; emitHaptic("selection", `称谓 → ${state.tone}`); renderAll(); };
    });
    document.querySelectorAll("#viewStateSwitch .seg-btn").forEach((b) => {
      b.onclick = () => {
        state.viewState = b.dataset.viewState;
        emitHaptic(state.viewState === "error" ? "alert" : (state.viewState === "outcome" ? "confirm" : "silent"), `全局状态 → ${state.viewState}`);
        renderAll({ resetScroll: true });
      };
    });
    document.querySelectorAll("#a11ySwitch .seg-btn").forEach((b) => {
      b.onclick = () => {
        const k = b.dataset.toggle;
        if (k === "ax") state.ax = !state.ax;
        if (k === "rm") state.reduceMotion = !state.reduceMotion;
        if (k === "rt") state.reduceTransparency = !state.reduceTransparency;
        emitHaptic("selection", `无障碍开关 ${k}`);
        renderAll();
      };
    });
    document.querySelectorAll("#sceneGroupTabs .filter-pill").forEach((b) => {
      b.onclick = () => {
        const grp = b.dataset.group;
        state.activeGroup = grp;
        const firstScene = SCENE_GROUPS[grp]?.[0]?.id;
        emitHaptic("silent", `切换展示分组: ${grp}`);
        if (firstScene) switchScene(firstScene);
      };
    });
  }

  const exportedEngineApi = {
    parseStreamingMarkdownBlocks,
    renderInlineMd,
    renderStreamingMarkdown,
    splitGraphemes,
    TelegramTextRevealControllerRef,
    ClioRevealController,
    ScrollChromeController,
    computeSafeLineBox,
    resolveToolAggregateStatus,
    resolveShortModelName,
    resolveReadingTypography,
    patchStreamingProseDom,
    flushDeferredProseBlocks,
    detectFontEnvironment,
    getChromeLockReason,
    bindSlideTrack,
    attachImeSafeInput,
    startStreamIntoTurn,
    stopStreaming,
    failActiveStream,
    STREAM_TRACES,
    SECTION46_SAMPLE,
    getState: () => state,
    setState: (patch) => Object.assign(state, patch),
    renderAll
  };
  if (typeof window !== "undefined") window.CLIO_STREAM_ENGINE = exportedEngineApi;
  if (typeof globalThis !== "undefined") globalThis.CLIO_STREAM_ENGINE = exportedEngineApi;

  // Boot (skipped automatically when loaded inside headless Node unit test sandbox)
  if (!globalThis.__CLIO_TEST_MODE__) {
    if (typeof document !== "undefined") {
      document.addEventListener("selectionchange", () => {
        const sel = typeof window !== "undefined" && window.getSelection ? window.getSelection() : null;
        const picked = sel ? String(sel.toString() || "").trim() : "";
        if (!picked && state.selectionActive) {
          state.selectionActive = false;
        }
        flushDeferredProseBlocks(document, sel);
      });
      document.addEventListener("visibilitychange", () => {
        if (!document.hidden && state.streaming && activeRevealCtrl) {
          runActiveRevealLoop();
        }
      });
      if (document.fonts) {
        const refreshFontStrip = () => {
          detectFontEnvironment();
          const strip = document.getElementById("fontStatusStrip");
          if (strip) strip.outerHTML = renderFontStatusStripHtml();
        };
        if (typeof document.fonts.load === "function") {
          Promise.allSettled([
            document.fonts.load("400 17px ClioKaiWeb", "克"),
            document.fonts.load("500 17px ClioKaiWeb", "克"),
            document.fonts.load("400 14px MapleMonoWeb", "0"),
            document.fonts.load("600 14px MapleMonoWeb", "0"),
            document.fonts.load("400 14px ClioMonoCNWeb", "文"),
            document.fonts.load("400 20px ClioSealWeb", "克")
          ]).then(refreshFontStrip).catch(() => {});
        }
        if (typeof document.fonts.addEventListener === "function") {
          document.fonts.addEventListener("loadingdone", refreshFontStrip);
        }
        if (document.fonts.ready) {
          document.fonts.ready.then(refreshFontStrip).catch(() => {});
        }
      }
    }
    bindStudioControls();
    renderAll();
    startPetLoop();
    requestAnimationFrame(renderHapticCanvas);
  }
})();

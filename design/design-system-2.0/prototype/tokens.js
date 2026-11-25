// Runtime Design System 2.0 Tokens & Authentic Bilingual Copy/Data for Clio Prototype v5.
// Synced with specs/tokens.v2.json, W3C CLREQ rules, Section 14 4-tier Motion, Section 15 Haptics, and Tone JSON.

window.CLIO_TOKENS_V2 = {
  uiScaleLevels: [
    { key: "compact", title: "紧凑", factor: 0.88 },
    { key: "small", title: "偏小", factor: 0.94 },
    { key: "standard", title: "标准", factor: 1.0 },
    { key: "large", title: "偏大", factor: 1.08 }
  ],
  readingSizes: [15, 16, 17, 19, 21, 24],
  lineHeights: [
    { value: 1.35, name: "紧凑", detail: "1.35 倍" },
    { value: 1.5, name: "适中", detail: "1.5 倍" },
    { value: 1.65, name: "舒展", detail: "1.65 倍" },
    { value: 1.8, name: "宽松", detail: "1.8 倍" }
  ],
  readingPresets: [
    { id: "editorial", name: "书卷", desc: "默认 · 衬线+苹方 17pt / 1.65×", readingFace: "editorial", readingSize: 17, lineHeight: 1.65, paragraphGap: 13 },
    { id: "standard",  name: "标准", desc: "清爽无衬线 · 17pt / 1.65×",    readingFace: "sans",      readingSize: 17, lineHeight: 1.65, paragraphGap: 13 },
    { id: "compact",   name: "紧凑", desc: "技术高密 · 15pt / 1.50×",      readingFace: "sans",      readingSize: 15, lineHeight: 1.50, paragraphGap: 10 },
    { id: "relaxed",   name: "舒阅", desc: "文楷舒展 · 19pt / 1.80×",      readingFace: "wenkai",    readingSize: 19, lineHeight: 1.80, paragraphGap: 16 }
  ],
  fontOpticalProfiles: {
    editorial: {
      label: "书卷默认（New York 英数 + 苹方中文）",
      fontCss: '"New York", -apple-system, BlinkMacSystemFont, "PingFang SC", "Noto Sans CJK SC", "Microsoft YaHei", sans-serif',
      opticalScale: 1.0,
      trackingEm: "0em",
      lhOffset: 0,
      boldWeight: 600,
      requiresAppleSystem: true,
      note: "Clio AC 默认搭配：中文极清耐读，数字与英文呈出版衬线气质；非 Apple 平台已标记回退，待 iOS 真机核验。"
    },
    sans: {
      label: "苹方 / 无衬线（PingFang SC + SF Pro）",
      fontCss: '-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Noto Sans CJK SC", "Microsoft YaHei", sans-serif',
      opticalScale: 1.0,
      trackingEm: "-0.004em",
      lhOffset: 0,
      boldWeight: 600,
      requiresAppleSystem: true,
      note: "极清现代黑体，长段技术对比与代码混排最快扫读。"
    },
    serif: {
      label: "全宋体（STSongti-SC + New York）",
      fontCss: '"New York", "Songti SC", "STSong", "Noto Serif CJK SC", Georgia, serif',
      opticalScale: 1.03,
      trackingEm: "0.002em",
      lhOffset: 0,
      boldWeight: 600,
      requiresAppleSystem: true,
      note: "传统出版宋体风格，内部 +3% 字面光学微补；与 SafeLineBox 共用基准行高不额外抬高。"
    },
    wenkai: {
      label: "Clio Kai（霞鹜文楷 Medium）",
      fontCss: '"ClioKaiWeb", "ClioKai-Medium", sans-serif',
      opticalScale: 1.045,
      trackingEm: "0.002em",
      lhOffset: 0,
      boldWeight: 500,
      bundledFontFamily: "ClioKaiWeb",
      boldStrokeWidth: -2.2,
      tableBoldStrokeWidth: -1.8,
      note: "原型直载仓库 App/Fonts/ClioKai-Medium.ttf（实测 xH=468、hhea 1.184×）：内部 +4.5% 字面补偿 + 0.002em 微距，并禁用系统楷体伪装。"
    }
  },
  streamingReveal: {
    velocityTau: 0.12,
    gapEwmaAlpha: 0.4,
    initialGap: 0.5,
    stallFloor: 0.10,
    finalizeTime: 0.28,
    frameDtCap: 0.05,
    initialInputRate: 40,
    edgeDurationMs: 160,
    blurRadiusPx: 1.4,
    translateYPx: 1.5,
    scale: 1.0,
    burstBlurCutoffCharsPerSec: 80
  },
  fontCombos: [
    { id: "A", title: "A · 无衬线 + 无衬线", face: "sans", hStyle: "sans", desc: "标题与正文全用系统无衬线；最冷静理性，略少书卷温度。" },
    { id: "B", title: "B · 衬线标题 + 无衬线正文", face: "sans", hStyle: "serif", desc: "标题借衬线确立刊物锚点，正文全苹方高效扫读。" },
    { id: "C", title: "C · 全宋体衬线体系", face: "serif", hStyle: "serif", desc: "整篇出版书籍质感，但小屏多标题和代码同框时偏繁复。" },
    { id: "D", title: "D · 霞鹜文楷 + 校准标题", face: "wenkai", hStyle: "wenkai", desc: "手写人文温润，光学校准 +4.5% 后不缩水；适合深度慢读。" },
    { id: "E", title: "E · AC 定稿（书卷默认）", face: "editorial", hStyle: "serif", desc: "New York 英数 + 苹方正文 + 克制 Semibold 阶梯，朱印文楷留给题词落款。" }
  ],
  paragraphGaps: [
    { value: 10, name: "紧凑", detail: "10 点" },
    { value: 13, name: "标准", detail: "13 点" },
    { value: 16, name: "舒展", detail: "16 点" },
    { value: 20, name: "宽松", detail: "20 点" }
  ],
  readingWidths: [
    { value: 560, name: "集中", detail: "560 pt" },
    { value: 640, name: "平衡", detail: "640 pt" },
    { value: 700, name: "宽阔", detail: "700 pt" }
  ],
  languages: {
    AC: {
      id: "AC",
      name: "素笺·栖息",
      subtitle: "Editorial Companion · A 骨 C 韵定稿",
      defaultTone: "literary",
      desc: "A 骨（Clio 字标、朱印与滑动盖印、出版阅读版式）+ C 韵（双头牌松绿、静态状态光氛、温和中文工具叙事）+ B 序。",
      radii: { outerCard: 26, innerBlock: 14, sheet: 34, badgeRatio: 0.26 },
      approvalStyle: "stamp",
      toolRailWidth: 2.5,
      ambientGlow: true,
      motionTiers: {
        instant:    { ms: 100, response: 0.18, damping: 0.88, overshoot: "1.2%", cubic: "cubic-bezier(0.22, 1.04, 0.36, 1)" },
        quick:      { ms: 190, response: 0.26, damping: 0.85, overshoot: "2.0%", cubic: "cubic-bezier(0.22, 1.08, 0.34, 1)" },
        standard:   { ms: 310, response: 0.36, damping: 0.84, overshoot: "2.5%", cubic: "cubic-bezier(0.22, 1.12, 0.34, 1)" },
        expressive: { ms: 480, response: 0.48, damping: 0.72, overshoot: "6.0%", cubic: "cubic-bezier(0.20, 1.24, 0.32, 1)" }
      },
      haptics: {
        profile: "温润纸墨（普通钮静默）",
        sharpness: 0.40,
        sharpnessBias: 0.40,
        tapIntensity: 0.40,
        tickIntensity: 0.48,
        detentIntensity: 0.68,
        confirmDesc: "三段朱印 thud() + 普通按钮不震"
      },
      colors: {
        light: {
          bg: "#F8F5EE", surface: "#FFFDF8", surfaceElevated: "#FFFFFF", surfaceSubtle: "#EFEAE0",
          ink: "#1F1E1B", inkSecondary: "#57534A", inkTertiary: "#696459", rule: "#E2DACB",
          accent: "#35587B", onAccent: "#FFFDF8", accentWash: "#E2EAF2",
          seal: "#B5382A", sealFill: "#B5382A", onSeal: "#FBF3EA",
          ok: "#286644", warn: "#945608", danger: "#B4322A",
          myBubble: "#EAE2D3", codeBg: "#F1ECE1", stopWash: "#F5E2DF"
        },
        dark: {
          bg: "#191815", surface: "#23211D", surfaceElevated: "#2C2924", surfaceSubtle: "#2C2924",
          ink: "#EFEAE0", inkSecondary: "#B9B1A2", inkTertiary: "#989082", rule: "#3A362F",
          accent: "#8CB4DB", onAccent: "#14181E", accentWash: "#253443",
          seal: "#E87568", sealFill: "#B84134", onSeal: "#FBF3EA",
          ok: "#6EC08E", warn: "#E4A952", danger: "#EC7E75",
          myBubble: "#312D26", codeBg: "#1F1D19", stopWash: "#3D2624"
        },
        oled: {
          bg: "#000000", surface: "#12110F", surfaceElevated: "#1C1A17", surfaceSubtle: "#1C1A17",
          ink: "#EFEAE0", inkSecondary: "#B9B1A2", inkTertiary: "#989082", rule: "#2B2823",
          accent: "#8CB4DB", onAccent: "#14181E", accentWash: "#1E2B38",
          seal: "#E87568", sealFill: "#B84134", onSeal: "#FBF3EA",
          ok: "#6EC08E", warn: "#E4A952", danger: "#EC7E75",
          myBubble: "#24211C", codeBg: "#141310", stopWash: "#331D1B"
        }
      },
      palettes: {
        paper_dai: {
          name: "素笺黛蓝",
          light: {
            bg: "#F8F5EE", surface: "#FFFDF8", surfaceElevated: "#FFFFFF", surfaceSubtle: "#EFEAE0",
            ink: "#1F1E1B", inkSecondary: "#57534A", inkTertiary: "#696459", rule: "#E2DACB",
            accent: "#35587B", onAccent: "#FFFDF8", accentWash: "#E2EAF2",
            seal: "#B5382A", sealFill: "#B5382A", onSeal: "#FBF3EA",
            ok: "#286644", warn: "#945608", danger: "#B4322A",
            myBubble: "#EAE2D3", codeBg: "#F1ECE1", stopWash: "#F5E2DF"
          },
          dark: {
            bg: "#191815", surface: "#23211D", surfaceElevated: "#2C2924", surfaceSubtle: "#2C2924",
            ink: "#EFEAE0", inkSecondary: "#B9B1A2", inkTertiary: "#989082", rule: "#3A362F",
            accent: "#8CB4DB", onAccent: "#14181E", accentWash: "#253443",
            seal: "#E87568", sealFill: "#B84134", onSeal: "#FBF3EA",
            ok: "#6EC08E", warn: "#E4A952", danger: "#EC7E75",
            myBubble: "#312D26", codeBg: "#1F1D19", stopWash: "#3D2624"
          },
          oled: {
            bg: "#000000", surface: "#12110F", surfaceElevated: "#1C1A17", surfaceSubtle: "#1C1A17",
            ink: "#EFEAE0", inkSecondary: "#B9B1A2", inkTertiary: "#989082", rule: "#2B2823",
            accent: "#8CB4DB", onAccent: "#14181E", accentWash: "#1E2B38",
            seal: "#E87568", sealFill: "#B84134", onSeal: "#FBF3EA",
            ok: "#6EC08E", warn: "#E4A952", danger: "#EC7E75",
            myBubble: "#24211C", codeBg: "#141310", stopWash: "#331D1B"
          }
        },
        oat_pine: {
          name: "栖息松绿",
          light: {
            bg: "#F5F3EE", surface: "#FCFAF6", surfaceElevated: "#FFFFFF", surfaceSubtle: "#EAE5DB",
            ink: "#1E2420", inkSecondary: "#4D5750", inkTertiary: "#5E6961", rule: "#DFDAD0",
            accent: "#276454", onAccent: "#FCFAF6", accentWash: "#DFECE7",
            seal: "#9A492B", sealFill: "#9A492B", onSeal: "#FCFAF6",
            ok: "#26684A", warn: "#965214", danger: "#B53B34",
            myBubble: "#E3EAE5", codeBg: "#ECE8DF", stopWash: "#F5E3DF"
          },
          dark: {
            bg: "#151816", surface: "#1E221F", surfaceElevated: "#272C28", surfaceSubtle: "#272C28",
            ink: "#ECF0EC", inkSecondary: "#A9B4AD", inkTertiary: "#8B9890", rule: "#333A35",
            accent: "#70BFAA", onAccent: "#0E1A16", accentWash: "#203630",
            seal: "#E59170", sealFill: "#A85233", onSeal: "#FCFAF6",
            ok: "#6AC296", warn: "#E4A65D", danger: "#EE7D75",
            myBubble: "#24312C", codeBg: "#1A1E1B", stopWash: "#3B2422"
          },
          oled: {
            bg: "#000000", surface: "#111412", surfaceElevated: "#1A1F1C", surfaceSubtle: "#1A1F1C",
            ink: "#ECF0EC", inkSecondary: "#A9B4AD", inkTertiary: "#8B9890", rule: "#262C28",
            accent: "#70BFAA", onAccent: "#0E1A16", accentWash: "#182924",
            seal: "#E59170", sealFill: "#A85233", onSeal: "#FCFAF6",
            ok: "#6AC296", warn: "#E4A65D", danger: "#EE7D75",
            myBubble: "#1B2622", codeBg: "#131714", stopWash: "#311C1A"
          }
        }
      }
    },
    A: {
      id: "A",
      name: "素笺 2.0",
      subtitle: "Editorial Ink · 现代书卷",
      defaultTone: "literary",
      desc: "保留书卷辨识度与朱印「克」，校高 WCAG 对比度、双轨字号并用 CLREQ 规范重排长文。",
      radii: { outerCard: 26, innerBlock: 14, sheet: 34, badgeRatio: 0.26 },
      approvalStyle: "stamp",
      toolRailWidth: 2,
      ambientGlow: false,
      motionTiers: {
        instant:    { ms: 100, response: 0.18, damping: 0.88, overshoot: "1.2%", cubic: "cubic-bezier(0.22, 1.04, 0.36, 1)" },
        quick:      { ms: 190, response: 0.26, damping: 0.85, overshoot: "2.0%", cubic: "cubic-bezier(0.22, 1.08, 0.34, 1)" },
        standard:   { ms: 310, response: 0.36, damping: 0.84, overshoot: "2.5%", cubic: "cubic-bezier(0.22, 1.12, 0.34, 1)" },
        expressive: { ms: 480, response: 0.48, damping: 0.72, overshoot: "6.0%", cubic: "cubic-bezier(0.20, 1.24, 0.32, 1)" }
      },
      haptics: {
        profile: "竹笔纸墨（普通钮静默）",
        sharpness: 0.45,
        sharpnessBias: 0.45,
        tapIntensity: 0.40,
        tickIntensity: 0.50,
        detentIntensity: 0.70,
        confirmDesc: "三段朱印 thud() + 普通按钮不震"
      },
      colors: {
        light: {
          bg: "#F8F5EE", surface: "#FFFDF8", surfaceElevated: "#FFFFFF", surfaceSubtle: "#EFEAE0",
          ink: "#1F1E1B", inkSecondary: "#57534A", inkTertiary: "#696459", rule: "#E2DACB",
          accent: "#35587B", onAccent: "#FFFDF8", accentWash: "#E2EAF2",
          seal: "#B5382A", sealFill: "#B5382A", onSeal: "#FBF3EA",
          ok: "#286644", warn: "#945608", danger: "#B4322A",
          myBubble: "#EAE2D3", codeBg: "#F1ECE1", stopWash: "#F5E2DF"
        },
        dark: {
          bg: "#191815", surface: "#23211D", surfaceElevated: "#2C2924", surfaceSubtle: "#2C2924",
          ink: "#EFEAE0", inkSecondary: "#B9B1A2", inkTertiary: "#989082", rule: "#3A362F",
          accent: "#8CB4DB", onAccent: "#14181E", accentWash: "#253443",
          seal: "#E87568", sealFill: "#B84134", onSeal: "#FBF3EA",
          ok: "#6EC08E", warn: "#E4A952", danger: "#EC7E75",
          myBubble: "#312D26", codeBg: "#1F1D19", stopWash: "#3D2624"
        },
        oled: {
          bg: "#000000", surface: "#12110F", surfaceElevated: "#1C1A17", surfaceSubtle: "#1C1A17",
          ink: "#EFEAE0", inkSecondary: "#B9B1A2", inkTertiary: "#989082", rule: "#2B2823",
          accent: "#8CB4DB", onAccent: "#14181E", accentWash: "#1E2B38",
          seal: "#E87568", sealFill: "#B84134", onSeal: "#FBF3EA",
          ok: "#6EC08E", warn: "#E4A952", danger: "#EC7E75",
          myBubble: "#24211C", codeBg: "#141310", stopWash: "#331D1B"
        }
      }
    },
    B: {
      id: "B",
      name: "清器",
      subtitle: "Native Precision · 原生精密",
      defaultTone: "daily",
      desc: "去文人化精密数字仪器：全无衬线、等宽数值、2.5pt 语义左轨、极速低过冲可打断与棘轮触觉。",
      radii: { outerCard: 18, innerBlock: 10, sheet: 28, badgeRatio: 0.24 },
      approvalStyle: "ratchet",
      toolRailWidth: 2.5,
      ambientGlow: false,
      motionTiers: {
        instant:    { ms: 90,  response: 0.14, damping: 0.94, overshoot: "0.3%", cubic: "cubic-bezier(0.20, 1.00, 0.32, 1)" },
        quick:      { ms: 160, response: 0.21, damping: 0.90, overshoot: "0.8%", cubic: "cubic-bezier(0.20, 1.02, 0.32, 1)" },
        standard:   { ms: 260, response: 0.27, damping: 0.89, overshoot: "1.0%", cubic: "cubic-bezier(0.18, 1.04, 0.30, 1)" },
        expressive: { ms: 420, response: 0.40, damping: 0.82, overshoot: "3.0%", cubic: "cubic-bezier(0.20, 1.10, 0.30, 1)" }
      },
      haptics: {
        profile: "精密机械棘轮（普通钮静默）",
        sharpness: 0.85,
        sharpnessBias: 0.85,
        tapIntensity: 0.50,
        tickIntensity: 0.62,
        detentIntensity: 0.85,
        confirmDesc: "12.5% 步进高锐度棘轮锁"
      },
      colors: {
        light: {
          bg: "#F3F4F6", surface: "#FFFFFF", surfaceElevated: "#FFFFFF", surfaceSubtle: "#E8ECF2",
          ink: "#111318", inkSecondary: "#49505E", inkTertiary: "#5D6575", rule: "#DCE0E6",
          accent: "#1B56CF", onAccent: "#FFFFFF", accentWash: "#E5EEFC",
          seal: "#1B56CF", sealFill: "#1B56CF", onSeal: "#FFFFFF",
          ok: "#147043", warn: "#9A4D06", danger: "#C42828",
          myBubble: "#E6ECF6", codeBg: "#ECEFF5", stopWash: "#F9E2E2"
        },
        dark: {
          bg: "#101216", surface: "#181B21", surfaceElevated: "#21252E", surfaceSubtle: "#21252E",
          ink: "#F1F3F7", inkSecondary: "#ACB3C2", inkTertiary: "#8C95A6", rule: "#2D323E",
          accent: "#75A8FF", onAccent: "#0B1220", accentWash: "#1E2D47",
          seal: "#75A8FF", sealFill: "#1B56CF", onSeal: "#FFFFFF",
          ok: "#56C48B", warn: "#E5A14B", danger: "#F07575",
          myBubble: "#222938", codeBg: "#15181E", stopWash: "#381E20"
        },
        oled: {
          bg: "#000000", surface: "#101216", surfaceElevated: "#1A1E26", surfaceSubtle: "#1A1E26",
          ink: "#F1F3F7", inkSecondary: "#ACB3C2", inkTertiary: "#8C95A6", rule: "#262B35",
          accent: "#75A8FF", onAccent: "#0B1220", accentWash: "#17243A",
          seal: "#75A8FF", sealFill: "#1B56CF", onSeal: "#FFFFFF",
          ok: "#56C48B", warn: "#E5A14B", danger: "#F07575",
          myBubble: "#1A2130", codeBg: "#11141A", stopWash: "#30181A"
        }
      }
    },
    C: {
      id: "C",
      name: "栖息",
      subtitle: "Quiet Companion · 静谧旅伴",
      defaultTone: "daily",
      desc: "温润低焦虑有机陪伴场：柔和任务光氛、自然中文工具叙事、静绿与陶土暖调。",
      radii: { outerCard: 28, innerBlock: 14, sheet: 36, badgeRatio: 0.28 },
      approvalStyle: "bloom",
      toolRailWidth: 3,
      ambientGlow: true,
      motionTiers: {
        instant:    { ms: 110, response: 0.20, damping: 0.84, overshoot: "1.8%", cubic: "cubic-bezier(0.24, 1.08, 0.36, 1)" },
        quick:      { ms: 210, response: 0.29, damping: 0.80, overshoot: "3.0%", cubic: "cubic-bezier(0.22, 1.14, 0.32, 1)" },
        standard:   { ms: 340, response: 0.42, damping: 0.79, overshoot: "3.5%", cubic: "cubic-bezier(0.22, 1.16, 0.32, 1)" },
        expressive: { ms: 540, response: 0.54, damping: 0.70, overshoot: "6.5%", cubic: "cubic-bezier(0.20, 1.26, 0.28, 1)" }
      },
      haptics: {
        profile: "有机棉纸呼吸波（普通钮静默）",
        sharpness: 0.25,
        sharpnessBias: 0.25,
        tapIntensity: 0.38,
        tickIntensity: 0.44,
        detentIntensity: 0.62,
        confirmDesc: "柔和低频连续波 + 温和释放点"
      },
      colors: {
        light: {
          bg: "#F5F3EE", surface: "#FCFAF6", surfaceElevated: "#FFFFFF", surfaceSubtle: "#EAE5DB",
          ink: "#1E2420", inkSecondary: "#4D5750", inkTertiary: "#5E6961", rule: "#DFDAD0",
          accent: "#276454", onAccent: "#FCFAF6", accentWash: "#DFECE7",
          seal: "#9A492B", sealFill: "#9A492B", onSeal: "#FCFAF6",
          ok: "#26684A", warn: "#965214", danger: "#B53B34",
          myBubble: "#E3EAE5", codeBg: "#ECE8DF", stopWash: "#F5E3DF"
        },
        dark: {
          bg: "#151816", surface: "#1E221F", surfaceElevated: "#272C28", surfaceSubtle: "#272C28",
          ink: "#ECF0EC", inkSecondary: "#A9B4AD", inkTertiary: "#8B9890", rule: "#333A35",
          accent: "#70BFAA", onAccent: "#0E1A16", accentWash: "#203630",
          seal: "#E59170", sealFill: "#A85233", onSeal: "#FCFAF6",
          ok: "#6AC296", warn: "#E4A65D", danger: "#EE7D75",
          myBubble: "#24312C", codeBg: "#1A1E1B", stopWash: "#3B2422"
        },
        oled: {
          bg: "#000000", surface: "#111412", surfaceElevated: "#1A1F1C", surfaceSubtle: "#1A1F1C",
          ink: "#ECF0EC", inkSecondary: "#A9B4AD", inkTertiary: "#8B9890", rule: "#262C28",
          accent: "#70BFAA", onAccent: "#0E1A16", accentWash: "#182924",
          seal: "#E59170", sealFill: "#A85233", onSeal: "#FCFAF6",
          ok: "#6AC296", warn: "#E4A65D", danger: "#EE7D75",
          myBubble: "#1B2622", codeBg: "#131714", stopWash: "#311C1A"
        }
      }
    }
  },
  petCatalog: [
    { id: "xiaoke",  name: "小克", badge: "已实装", kind: "sprite", tagline: "默认书桌伴读精灵 · 原画 11 态" },
    { id: "roubao",  name: "肉包", badge: "已实装", kind: "sprite", tagline: "兜帽暖萌小团子 · 原画 14 态" },
    { id: "xuanmao", name: "玄猫", badge: "2.0 新增", kind: "proc",   tagline: "伏案慢眨眼的乌墨书桌猫（预览）" },
    { id: "songque", name: "松雀", badge: "2.0 新增", kind: "proc",   tagline: "呼应栖息松绿的林间小雀（预览）" },
    { id: "zhihe",   name: "纸鹤", badge: "2.0 新增", kind: "proc",   tagline: "呼应素笺纸墨的折纸仙鹤（预览）" }
  ],
  petSizes: [
    { factor: 0.75, name: "娇小", detail: "75%" },
    { factor: 1.0,  name: "标准", detail: "100%" },
    { factor: 1.25, name: "舒展", detail: "125%" },
    { factor: 1.5,  name: "偏大", detail: "150%" }
  ],
  monogramTints: [
    { id: "dai",    name: "黛蓝", hex: "#35587B" },
    { id: "pine",   name: "松绿", hex: "#276454" },
    { id: "seal",   name: "朱印", hex: "#B5382A" },
    { id: "ochre",  name: "秋缃", hex: "#8A4F08" },
    { id: "violet", name: "紫藤", hex: "#594978" },
    { id: "ink",    name: "浓墨", hex: "#2A2824" }
  ],
  presetPortraits: [
    {
      id: "plum",
      name: "墨梅图",
      uri: "data:image/svg+xml;utf8,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' fill='%23F4EFE4'/%3E%3Cpath d='M8 52 C22 40 34 30 50 18' stroke='%233A3229' stroke-width='2.6' fill='none' stroke-linecap='round'/%3E%3Cpath d='M28 35 C30 25 36 18 42 12' stroke='%233A3229' stroke-width='1.8' fill='none' stroke-linecap='round'/%3E%3Ccircle cx='49' cy='18' r='5' fill='%23B5382A' opacity='0.88'/%3E%3Ccircle cx='39' cy='14' r='4.2' fill='%23C94B3C' opacity='0.85'/%3E%3Ccircle cx='33' cy='25' r='3.6' fill='%23B5382A' opacity='0.8'/%3E%3Ccircle cx='21' cy='39' r='4' fill='%23C94B3C' opacity='0.78'/%3E%3C/svg%3E"
    },
    {
      id: "pine",
      name: "青松石",
      uri: "data:image/svg+xml;utf8,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' fill='%23E3ECE7'/%3E%3Ccircle cx='46' cy='18' r='8' fill='%239A492B' opacity='0.85'/%3E%3Cpath d='M4 54 L24 26 L38 42 L48 31 L62 54 Z' fill='%23276454' opacity='0.9'/%3E%3Cpath d='M16 54 L34 34 L50 54 Z' fill='%231E4D40'/%3E%3C/svg%3E"
    },
    {
      id: "orbit",
      name: "月夜案",
      uri: "data:image/svg+xml;utf8,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' fill='%231F2937'/%3E%3Ccircle cx='32' cy='32' r='19' fill='none' stroke='%238CB4DB' stroke-width='1.5' stroke-dasharray='4 3'/%3E%3Ccircle cx='32' cy='32' r='10' fill='%23F6F1E7'/%3E%3Ccircle cx='45' cy='19' r='3' fill='%23E87568'/%3E%3C/svg%3E"
    }
  ],
  tones: {
    daily: {
      home: "首页", files: "文件与知识库", terminal: "终端", memory: "记忆", settings: "设置",
      assistant: "助手", pet: "宠物", chat: "对话", newChat: "新对话",
      thinking: "思考", replying: "回复", idle: "空闲", waiting: "等我确认",
      steps: "步骤", source: "出处",
      approvalSheet: "批准单", signer: "批准人", slideToApprove: "右滑到底批准",
      approved: "已批准", rejected: "已拒绝", rejectBtn: "拒绝", approveOnce: "准这一次",
      trustChat: "本对话放行", trustWeb: "已知风险，本对话放行",
      webWarn: "这一轮读过网页内容，请逐字核对命令后确认",
      pinned: "置顶", conversations: "对话", pastConversations: "更早对话",
      memoryPinned: "常驻", memorySurface: "表面", memoryDeep: "深层", memoryArchived: "封存",
      composerPlaceholder: "输入指令，或按住说话…",
      themeTitle: "主题与配色", sizeTitle: "字号、间距与密度",
      grantsTitle: "权限与外网安全", modelsTitle: "模型与服务角色",
      copy: "复制", redo: "重来", quote: "引用", copied: "✓ 已复制",
      quoteLabel: "引用追问", clearChat: "重置演示对话", newLeaf: "新建一段对话",
      findInChat: "在对话里找", outlineTitle: "问答目录", compressContext: "压缩前文",
      compressedToast: "已压缩前文，节省约 38% 上下文",
      alwaysOnTitle: "常亮黑屏", alwaysOnHint: "每 15 秒微移防烧屏 · 轻点返回",
      sendQueue: "排队发送（等当前轮结束）", sendInterject: "插话附言", sendInterrupt: "立即打断并重写",
      selectDemo: "跨段选字", sourcesTitle: "出处与摘要核验",
      greetingC: "夜色还早，慢慢理清今天的事",
      moreMenuTitle: "对话操作",
      hintSuffix: ""
    },
    literary: {
      home: "窗前", files: "书案", terminal: "斗室", memory: "拾遗", settings: "调弦",
      assistant: "旅伴", pet: "伴读", chat: "絮语", newChat: "另起一叶",
      thinking: "沉吟", replying: "落笔", idle: "闲坐", waiting: "候印",
      steps: "行迹", source: "出处",
      approvalSheet: "便笺", signer: "落款", slideToApprove: "右滑到底落款",
      approved: "已落款", rejected: "已退回", rejectBtn: "退回", approveOnce: "准这一次",
      trustChat: "本对话放行", trustWeb: "已知风险，本对话放行",
      webWarn: "这一轮读过网页内容，需你亲笔核验落款",
      pinned: "镇纸", conversations: "絮语", pastConversations: "收起的一叶",
      memoryPinned: "常记", memorySurface: "近期", memoryDeep: "旧事", memoryArchived: "入藏",
      composerPlaceholder: "写下一段话，或轻按听写…",
      themeTitle: "设色", sizeTitle: "字号、疏密与版式",
      grantsTitle: "应许与落款", modelsTitle: "模型与笔砚配属",
      copy: "抄录", redo: "重拟", quote: "引句", copied: "✓ 已抄录",
      quoteLabel: "引句追问", clearChat: "复原演示絮语", newLeaf: "另起一叶",
      findInChat: "卷中寻句", outlineTitle: "问答目录", compressContext: "收卷缩文",
      compressedToast: "已收卷缩文，释放约 38% 文脉空间",
      alwaysOnTitle: "静夜常亮", alwaysOnHint: "每 15 秒微移防烧屏 · 轻点任意处返回",
      sendQueue: "排队候序", sendInterject: "顺势插言", sendInterrupt: "即刻收笔重拟",
      selectDemo: "划词演示", sourcesTitle: "出处与摘要核验",
      greetingC: "窗外夜静，一起慢慢梳理手边事",
      moreMenuTitle: "卷边拾零",
      hintSuffix: "旁注已开"
    }
  },
  scrollAwareChrome: {
    enterDeltaPx: 44,
    exitDeltaPx: 56,
    nearBottomPx: 80,
    restoreBottomPx: 48,
    fastVelocityPxPerSec: 280,
    transitionMs: 220
  },
  shortModelAliases: {
    "deepseek-r1": "DeepSeek R1",
    "claude-sonnet-4": "Sonnet 4",
    "gpt-4o-mini": "GPT-4o mini",
    "imagen-3": "Imagen 3",
    "anthropic/claude-sonnet-4-20250514": "Sonnet 4",
    "deepseek/deepseek-reasoner": "DeepSeek R1"
  },
  toolStatuses7: [
    { key: "pending", icon: "○", label: "等待执行", tone: "neutral" },
    { key: "running", icon: "◐", label: "正在执行", tone: "accent" },
    { key: "succeeded", icon: "✓", label: "全部成功", tone: "ok" },
    { key: "partial", icon: "△", label: "部分成功", tone: "warn" },
    { key: "failed", icon: "✕", label: "全部失败", tone: "danger" },
    { key: "cancelled", icon: "■", label: "用户取消", tone: "muted" },
    { key: "waiting_approval", icon: "⛨", label: "等待审批", tone: "seal" }
  ]
};

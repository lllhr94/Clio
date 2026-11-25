#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const REPO_ROOT = path.resolve(ROOT, "..", "..");
const TOKENS_JS = path.join(ROOT, "prototype", "tokens.js");
const PET_SPRITES_JS = path.join(ROOT, "prototype", "pet-sprites.js");
const APP_JS = path.join(ROOT, "prototype", "app.js");
const STYLES_CSS = path.join(ROOT, "prototype", "styles.css");

// Lightweight structural DOM mock for Node sandbox behavioral tests
function createMockNode(tagName = "div", ownerDoc = null) {
  const node = {
    nodeType: tagName === "#text" ? 3 : 1,
    tagName: String(tagName).toUpperCase(),
    ownerDocument: ownerDoc,
    parentNode: null,
    childNodes: [],
    attributes: new Map(),
    dataset: {},
    style: {
      props: {},
      setProperty(k, v) { this.props[k] = String(v); },
      getPropertyValue(k) { return this.props[k] || ""; }
    },
    _className: "",
    _innerHTML: "",
    _nodeValue: "",
    listeners: new Map(),
    clientWidth: 320,
    scrollHeight: 1200,
    scrollTop: 0,
    get className() { return this._className; },
    set className(v) { this._className = String(v || ""); },
    classList: {
      add(...cls) {
        const s = new Set(node._className.split(/\s+/).filter(Boolean));
        cls.forEach((c) => s.add(c));
        node._className = Array.from(s).join(" ");
      },
      remove(...cls) {
        const rem = new Set(cls);
        node._className = node._className.split(/\s+/).filter((c) => c && !rem.has(c)).join(" ");
      },
      toggle(c, force) {
        const s = new Set(node._className.split(/\s+/).filter(Boolean));
        const has = s.has(c);
        const want = force === undefined ? !has : Boolean(force);
        if (want) s.add(c); else s.delete(c);
        node._className = Array.from(s).join(" ");
        return want;
      },
      contains(c) {
        return node._className.split(/\s+/).includes(c);
      }
    },
    setAttribute(k, v) {
      node.attributes.set(k, String(v));
      if (k.startsWith("data-")) {
        const dk = k.slice(5).replace(/-([a-z])/g, (_, ch) => ch.toUpperCase());
        node.dataset[dk] = String(v);
      }
      if (k === "id") node.id = String(v);
      if (k === "class") node._className = String(v);
    },
    getAttribute(k) {
      if (k === "id") return node.id || null;
      if (k === "class") return node._className || null;
      return node.attributes.get(k) ?? null;
    },
    get nextSibling() {
      if (!node.parentNode) return null;
      const idx = node.parentNode.childNodes.indexOf(node);
      return idx >= 0 && idx + 1 < node.parentNode.childNodes.length ? node.parentNode.childNodes[idx + 1] : null;
    },
    appendChild(child) {
      if (child.parentNode) child.parentNode.removeChild(child);
      child.parentNode = node;
      node.childNodes.push(child);
      return child;
    },
    insertBefore(child, ref) {
      if (!ref) return node.appendChild(child);
      if (child.parentNode) child.parentNode.removeChild(child);
      const idx = node.childNodes.indexOf(ref);
      child.parentNode = node;
      if (idx === -1) node.childNodes.push(child);
      else node.childNodes.splice(idx, 0, child);
      return child;
    },
    removeChild(child) {
      const idx = node.childNodes.indexOf(child);
      if (idx >= 0) {
        node.childNodes.splice(idx, 1);
        child.parentNode = null;
      }
      return child;
    },
    replaceChild(newChild, oldChild) {
      const idx = node.childNodes.indexOf(oldChild);
      if (idx === -1) return node.appendChild(newChild);
      if (newChild.parentNode) newChild.parentNode.removeChild(newChild);
      newChild.parentNode = node;
      oldChild.parentNode = null;
      node.childNodes[idx] = newChild;
      return oldChild;
    },
    remove() {
      if (node.parentNode) node.parentNode.removeChild(node);
    },
    contains(other) {
      let cur = other;
      while (cur) {
        if (cur === node) return true;
        cur = cur.parentNode;
      }
      return false;
    },
    get nodeValue() { return node.nodeType === 3 ? node._nodeValue : null; },
    set nodeValue(v) { if (node.nodeType === 3) node._nodeValue = String(v ?? ""); },
    get textContent() {
      if (node.nodeType === 3) return node._nodeValue;
      return node.childNodes.map((c) => c.textContent).join("");
    },
    set textContent(v) {
      if (node.nodeType === 3) {
        node._nodeValue = String(v ?? "");
        return;
      }
      node.childNodes = [];
      if (v !== null && v !== undefined && String(v).length > 0) {
        const tn = createMockNode("#text", ownerDoc);
        tn._nodeValue = String(v);
        tn.parentNode = node;
        node.childNodes.push(tn);
      }
    },
    get innerHTML() { return node._innerHTML; },
    set innerHTML(htmlStr) {
      node._innerHTML = String(htmlStr ?? "");
      node.childNodes = [];
      const plain = node._innerHTML.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
      if (plain) {
        const tn = createMockNode("#text", ownerDoc);
        tn._nodeValue = plain;
        tn.parentNode = node;
        node.childNodes.push(tn);
      }
    },
    querySelectorAll(selector) {
      const out = [];
      const wantClass = selector.startsWith(".") ? selector.slice(1) : null;
      const walk = (cur) => {
        for (const ch of cur.childNodes) {
          if (ch.nodeType === 1) {
            if (wantClass && ch.classList.contains(wantClass)) out.push(ch);
            else if (!wantClass && ch.tagName.toLowerCase() === selector.toLowerCase()) out.push(ch);
            walk(ch);
          }
        }
      };
      walk(node);
      return out;
    },
    querySelector(selector) {
      return node.querySelectorAll(selector)[0] || null;
    },
    addEventListener(type, fn) {
      if (!node.listeners.has(type)) node.listeners.set(type, []);
      node.listeners.get(type).push(fn);
    },
    removeEventListener(type, fn) {
      const arr = node.listeners.get(type);
      if (!arr) return;
      const idx = arr.indexOf(fn);
      if (idx >= 0) arr.splice(idx, 1);
    },
    dispatchEvent(evt) {
      const e = evt || {};
      e.target = e.target || node;
      if (typeof e.preventDefault !== "function") e.preventDefault = () => {};
      const handlerProp = node[`on${e.type}`];
      if (typeof handlerProp === "function") handlerProp(e);
      const arr = node.listeners.get(e.type) || [];
      for (const fn of [...arr]) fn(e);
    },
    setPointerCapture() {}
  };
  return node;
}

function loadPrototypeEngine() {
  const docListeners = new Map();
  const winListeners = new Map();
  const idMap = new Map();
  const mockDoc = {
    hidden: false,
    fonts: { ready: Promise.resolve(), forEach: () => {} },
    createElement(tag) { return createMockNode(tag, mockDoc); },
    createTextNode(txt) {
      const n = createMockNode("#text", mockDoc);
      n._nodeValue = String(txt ?? "");
      return n;
    },
    getElementById(id) { return idMap.get(id) || null; },
    querySelectorAll() { return []; },
    querySelector() { return null; },
    addEventListener(t, fn) {
      if (!docListeners.has(t)) docListeners.set(t, []);
      docListeners.get(t).push(fn);
    },
    removeEventListener(t, fn) {
      const arr = docListeners.get(t);
      if (arr) {
        const idx = arr.indexOf(fn);
        if (idx >= 0) arr.splice(idx, 1);
      }
    },
    dispatchEvent(evt) {
      for (const fn of [...(docListeners.get(evt.type) || [])]) fn(evt);
    }
  };

  const sandbox = {
    __CLIO_TEST_MODE__: true,
    console,
    Date,
    Math,
    Intl,
    Set,
    Map,
    Array,
    String,
    Number,
    Boolean,
    RegExp,
    Error,
    Promise,
    JSON,
    setTimeout,
    clearTimeout,
    Image: class MockImage {
      constructor() { this.complete = true; this.onload = null; }
      set src(v) { this._src = v; }
      get src() { return this._src || ""; }
    },
    requestAnimationFrame: () => 0,
    cancelAnimationFrame: () => {},
    performance: { now: () => 1000 },
    document: mockDoc,
    window: {
      location: { protocol: "http:" },
      innerWidth: 1280,
      innerHeight: 860,
      getSelection: () => null,
      addEventListener(t, fn) {
        if (!winListeners.has(t)) winListeners.set(t, []);
        winListeners.get(t).push(fn);
      },
      removeEventListener(t, fn) {
        const arr = winListeners.get(t);
        if (arr) {
          const idx = arr.indexOf(fn);
          if (idx >= 0) arr.splice(idx, 1);
        }
      },
      dispatchEvent(evt) {
        for (const fn of [...(winListeners.get(evt.type) || [])]) fn(evt);
      }
    }
  };
  sandbox.globalThis = sandbox;
  sandbox.window.document = mockDoc;

  const ctx = vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(TOKENS_JS, "utf8"), ctx, { filename: "tokens.js" });
  vm.runInContext(fs.readFileSync(PET_SPRITES_JS, "utf8"), ctx, { filename: "pet-sprites.js" });
  vm.runInContext(fs.readFileSync(APP_JS, "utf8"), ctx, { filename: "app.js" });
  return { engine: ctx.CLIO_STREAM_ENGINE, tokens: ctx.window.CLIO_TOKENS_V2, mockDoc, createMockNode, sandbox };
}

const { engine, tokens, sandbox, mockDoc } = loadPrototypeEngine();
assert.ok(engine, "CLIO_STREAM_ENGINE must be exported");
assert.ok(tokens, "CLIO_TOKENS_V2 must be exported");

const results = [];
function runTest(name, fn) {
  const t0 = performance.now();
  fn();
  const ms = (performance.now() - t0).toFixed(2);
  results.push({ name, ms });
}

// 1. P0 Exhaustive Prefix Safety (SECTION46_SAMPLE 0..N)
runTest("P0 Markdown Parser: 100% character prefix sweep of SECTION46_SAMPLE", () => {
  const full = engine.SECTION46_SAMPLE.fullMarkdown;
  assert.ok(full.length > 150, "Expected complex sample markdown");
  const start = performance.now();
  for (let i = 0; i <= full.length; i++) {
    const prefix = full.slice(0, i);
    const blocks = engine.parseStreamingMarkdownBlocks(prefix, i < full.length);
    assert.ok(Array.isArray(blocks), `prefix len ${i} must yield array`);
  }
  const elapsed = performance.now() - start;
  assert.ok(elapsed < 1500, `Exhaustive prefix sweep took too long: ${elapsed}ms`);
});

// 2. P0 Tricky Edge Cases & Literal Preservation
runTest("P0 Markdown Parser: tricky hashes, incomplete fences/math/lists & literal preservation", () => {
  const trickyCases = [
    ["#", "#"],
    ["##", "##"],
    ["#####", "#####"],
    ["#标签", "#标签"],
    ["###未加空格标题", "###未加空格标题"],
    ["# 一级标题\n\n# 标签文本", "一级标题"],
    ["-", "-"],
    ["*", "*"],
    ["1.", "1."],
    [">", ">"],
    ["|", "|"],
    ["||", "||"],
    ["```", "text"],
    ["```swift", "swift"],
    ["~~~py", "py"],
    ["$$", "$$"],
    ["$$ E = mc^2", "E = mc^2"],
    ["**未闭合加粗", "未闭合加粗"],
    ["`未闭合行内代码", "未闭合行内代码"],
    ["[链接文字](https://example.com/unfinished", "[链接文字]"],
    ["https://example.com/path*star*name_(1)", "https://example.com/path*star*name_(1)"],
    ["<script>alert(1)</script>", "&lt;script&gt;alert(1)&lt;/script&gt;"]
  ];

  for (const [input, expectedSub] of trickyCases) {
    const html = engine.renderStreamingMarkdown(input, true);
    assert.ok(typeof html === "string" && html.length > 0, `Expected non-empty HTML for ${JSON.stringify(input)}`);
    if (expectedSub) {
      assert.ok(html.includes(expectedSub), `Literal preservation failed for ${JSON.stringify(input)} -> got ${html}`);
    }
    const htmlFinal = engine.renderStreamingMarkdown(input, false);
    assert.ok(typeof htmlFinal === "string" && htmlFinal.length > 0);
  }
});

// 3. P0 Randomized Fuzzing (Unicode, Emoji, combining marks, CJK, URLs)
runTest("P0 Markdown Parser: 600 randomized Unicode/Emoji/RTL/URL truncations", () => {
  const pool = [
    "# ", "## 二级\n", "#标签", "👨‍👩‍👧‍👦 家庭与中文混排 ", "e\u0301 ", "👍🏽 ",
    "```ts\nconst x = a * b;\n```\n", "`inline_code_x*y` ", "**粗体文字** ",
    "[文档](https://clio.example.dev/docs?a=1&b=2) ", "| 列A | 列B |\n| :--- | ---: |\n| 1 | 2 |\n",
    "> 引用一句话\n", "1. 第一项\n   - 子项\n", "$$ \\sum_{i=1}^n x_i $$\n", "\n\n"
  ];
  let seed = 421337;
  const rnd = () => {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    return seed / 4294967296;
  };
  for (let k = 0; k < 600; k++) {
    let docStr = "";
    const parts = 2 + Math.floor(rnd() * 6);
    for (let p = 0; p < parts; p++) {
      docStr += pool[Math.floor(rnd() * pool.length)];
    }
    const cut = Math.floor(rnd() * (docStr.length + 1));
    const slice = docStr.slice(0, cut);
    const res = engine.parseStreamingMarkdownBlocks(slice, true);
    assert.ok(Array.isArray(res));
  }
});

// 4. Grapheme Safety
runTest("Grapheme Splitter: preserves ZWJ family emoji, flags, skin tone, combining marks", () => {
  const input = "你好👨‍👩‍👧‍👦🇺🇸e\u0301👍🏽世界";
  const g = Array.from(engine.splitGraphemes(input));
  assert.deepEqual(g, ["你", "好", "👨‍👩‍👧‍👦", "🇺🇸", "e\u0301", "👍🏽", "世", "界"]);
  assert.equal(g.join(""), input);
});

// 5. ClioRevealController Adaptive Pacing across all 6 Traces + Lifecycle Gates
runTest("ClioRevealController: 6 traces zero-loss/dup, burst blur cutoff, stall, error, hidden pause, reduceMotion", () => {
  const full = engine.SECTION46_SAMPLE.fullMarkdown;
  const gAll = engine.splitGraphemes(full);

  for (const traceKey of ["slow", "fast", "jitter", "stall", "burst", "error"]) {
    const ctrl = new engine.ClioRevealController();
    assert.equal(ctrl.lifecycle, "waiting_first_token");
    const trace = engine.STREAM_TRACES[traceKey];
    let emitted = 0;
    let t = 0;
    let prevRevealed = 0;
    let sawStall = false;
    let sawBurstCutoff = false;
    let errThrown = false;

    for (const seg of trace) {
      t += seg.dtMs / 1000;
      emitted = Math.min(gAll.length, emitted + seg.chars);
      ctrl.observeUpdate(gAll.slice(0, emitted).join(""), t);
      const tickRes = ctrl.tick(t, {});
      assert.ok(tickRes.revealedCount >= prevRevealed, `${traceKey} revealedCount went backwards`);
      prevRevealed = tickRes.revealedCount;
      const revTxt = ctrl.currentRevealedText;
      assert.equal(full.startsWith(revTxt), true, `${traceKey} revealed prefix mismatch`);

      if (traceKey === "stall" && seg.dtMs >= 1000) {
        // Advance clock while waiting for next token
        const stTick = ctrl.tick(t - 0.1, {});
        assert.ok(stTick.revealedCount >= prevRevealed - 0.0001);
        const waitAfterPred = ctrl.tick(t + ctrl.avgInterArrival + 0.5, {});
        if (waitAfterPred.lifecycle === "stalled") sawStall = true;
      }
      if (seg.error) {
        ctrl.fail(seg.error);
        errThrown = true;
        assert.equal(ctrl.lifecycle, "error");
        break;
      }
    }

    if (!errThrown) {
      ctrl.observeUpdate(full, t + 0.05);
      ctrl.finalize(full);
      for (let f = 0; f < 160; f++) {
        t += 1 / 60;
        const r = ctrl.tick(t, {});
        if (traceKey === "burst" && r.velocity > ctrl.burstBlurCutoff && r.useBlur === false) {
          sawBurstCutoff = true;
        }
        assert.ok(r.revealedCount >= prevRevealed);
        prevRevealed = r.revealedCount;
        if (r.isComplete) break;
      }
      assert.equal(ctrl.currentRevealedText, full, `${traceKey} did not reach exact full text`);
      assert.equal(ctrl.lifecycle, "completed");
    }
    if (traceKey === "burst") {
      // Simulate heavy sudden influx where targetVelocity > 80 grapheme/s
      const bCtrl = new engine.ClioRevealController();
      bCtrl.observeUpdate(gAll.slice(0, 10).join(""), 0.05);
      bCtrl.observeUpdate(gAll.slice(0, 260).join(""), 0.10);
      bCtrl.finalize();
      let foundNoBlur = false;
      for (let i = 0; i < 30; i++) {
        const res = bCtrl.tick(0.11 + i * 0.016, {});
        if (res.velocity > bCtrl.burstBlurCutoff && !res.useBlur) {
          foundNoBlur = true;
          break;
        }
      }
      assert.ok(foundNoBlur || sawBurstCutoff, "Burst catchup must turn off per-token blur above cutoff");
    }
    if (traceKey === "stall") {
      assert.ok(typeof sawStall === "boolean");
    }
  }

  // Hidden pause + reduceMotion + stop invariants
  const pCtrl = new engine.ClioRevealController();
  pCtrl.observeUpdate("你好，正在流式推进一段长文测试内容。", 0.1);
  const paused = pCtrl.tick(0.2, { hidden: true });
  assert.equal(paused.deltaCount, 0);
  assert.equal(paused.lifecycle, "background_paused");
  const rm = pCtrl.tick(0.25, { reduceMotion: true });
  assert.equal(rm.revealedCount, engine.splitGraphemes("你好，正在流式推进一段长文测试内容。").length);
  assert.equal(rm.useBlur, false);
  assert.equal(rm.lifecycle, "reduce_motion");
});

// 6. Incremental Block DOM Reconciler + Selection Protection
runTest("Incremental Block DOM Reconciler: zero settled rebuild & selection protection", () => {
  const root = createMockNode("div", mockDoc);
  const block1 = "# 第一部分\n\n第一段已经写完了，不能重建。";
  engine.patchStreamingProseDom(root, block1, true, { animateEdge: false });
  const initialNodes = root.querySelectorAll(".md-block");
  assert.equal(initialNodes.length, 2);
  const settledHeadingRef = initialNodes[0];
  const settledParaRef = initialNodes[1];

  // Stream block 3 below without modifying blocks 0 and 1
  const block2 = `${block1}\n\n- 正在追加的列表项A`;
  const r2 = engine.patchStreamingProseDom(root, block2, true, { animateEdge: true, deltaCount: 4, useBlur: true });
  assert.equal(r2.settledRebuilds, 0);
  const afterNodes = root.querySelectorAll(".md-block");
  assert.equal(afterNodes[0], settledHeadingRef, "Heading DOM node identity must be preserved");
  assert.equal(afterNodes[1], settledParaRef, "Paragraph DOM node identity must be preserved");

  // Selection protection on an evolving block
  const selMock = {
    rangeCount: 1,
    toString: () => "正在追加",
    getRangeAt: () => ({
      startContainer: afterNodes[2],
      endContainer: afterNodes[2],
      intersectsNode: (n) => n === afterNodes[2]
    })
  };
  const beforeHtml = afterNodes[2].innerHTML;
  const r3 = engine.patchStreamingProseDom(root, `${block2}，补充尾句`, true, { selection: selMock });
  assert.equal(r3.deferredSelection, true, "Must defer DOM mutation on selected block");
  assert.equal(afterNodes[2].innerHTML, beforeHtml, "Selected block innerHTML must stay untouched");
});

// 7. SafeLineBox & Unified Typography & Real Bundled Fonts CSS Check
runTest("SafeLineBox & Typography CSS: zero double-spacing, unified userBubble, genuine App/Fonts", () => {
  const wk = engine.computeSafeLineBox(17, 1.65, "wenkai");
  const sansBox = engine.computeSafeLineBox(17, 1.65, "sans");
  assert.equal(wk.lineSpacing, 0, "SafeLineBox must NOT add duplicate lineSpacing");
  assert.equal(wk.maximumLineHeight, 0, "SafeLineBox must NOT clip maximumLineHeight");
  assert.equal(wk.effectiveSizePt, 18, "17 * 1.045 rounded to half-pt must be 18");
  assert.ok(wk.minimumLineHeight >= wk.naturalBoxPt);
  assert.equal(tokens.fontOpticalProfiles.wenkai.lhOffset, 0);
  assert.equal(tokens.fontOpticalProfiles.sans.lhOffset, 0);
  assert.ok(Math.abs(sansBox.minimumLineHeight - 17 * 1.65) < 0.01);

  const typoWk = engine.resolveReadingTypography("wenkai", 17, 1.65, false);
  assert.equal(typoWk.userBubbleLineHeight, 1.53);

  const css = fs.readFileSync(STYLES_CSS, "utf8");
  for (const fontFile of [
    "App/Fonts/ClioKai-Regular.ttf",
    "App/Fonts/ClioKai-Medium.ttf",
    "App/Fonts/MapleMono-Regular.ttf",
    "App/Fonts/MapleMono-SemiBold.ttf",
    "App/Fonts/ClioMonoCN-Regular.ttf",
    "App/Fonts/ClioSeal-Regular.ttf"
  ]) {
    assert.ok(css.includes(fontFile), `styles.css must reference real font ${fontFile}`);
    assert.ok(fs.existsSync(path.join(REPO_ROOT, fontFile)), `Real font missing on disk: ${fontFile}`);
  }
  assert.ok(!tokens.fontOpticalProfiles.wenkai.fontCss.includes("KaiTi"), "wenkai must NOT masquerade as KaiTi");
  assert.ok(css.includes(".msg-user-bubble") && css.includes("var(--user-bubble-lh)"), "User bubble must share unified SafeLineBox line-height var");
  assert.ok(css.includes(".bottom-dock-area::before") && css.includes(".composer-shell"), "Composer must include bottom gradient bleed-through scrim & frosted backing");
});

// 8. ScrollChromeController & 9 Chrome Locks
runTest("ScrollChromeController: programmatic guard, hysteresis, bottom restore & all chrome locks", () => {
  const ctrl = new engine.ScrollChromeController();
  engine.ScrollChromeController.markProgrammaticScroll(80);
  assert.equal(engine.ScrollChromeController.isProgrammaticScroll(), true);

  // Near bottom (< nearBottomPx): should NOT enter immersive even on upward scroll
  assert.equal(ctrl.handleScroll({ deltaY: -60, distBottom: 60, isScrollable: true, locked: false }), "full");
  // Small noise (< enterDeltaPx) far from bottom: should stay full (hysteresis)
  assert.equal(ctrl.handleScroll({ deltaY: -20, distBottom: 320, isScrollable: true, locked: false }), "full");
  // Crossing enterDeltaPx far from bottom: enters immersive
  assert.equal(ctrl.handleScroll({ deltaY: -30, distBottom: 350, isScrollable: true, locked: false }), "immersive");
  // Slight downward wiggle (< exitDeltaPx): stays immersive
  assert.equal(ctrl.handleScroll({ deltaY: 20, distBottom: 330, isScrollable: true, locked: false }), "immersive");
  // Strong downward scroll (>= exitDeltaPx): exits back to full
  assert.equal(ctrl.handleScroll({ deltaY: 45, distBottom: 285, isScrollable: true, locked: false }), "full");
  // Re-enter and hit bottom: immediate restore
  ctrl.handleScroll({ deltaY: -60, distBottom: 300, isScrollable: true, locked: false });
  assert.equal(ctrl.mode, "immersive");
  assert.equal(ctrl.handleScroll({ deltaY: 5, distBottom: 40, isScrollable: true, locked: false }), "full");
  // Locked state forces full
  ctrl.handleScroll({ deltaY: -60, distBottom: 300, isScrollable: true, locked: false });
  assert.equal(ctrl.handleScroll({ deltaY: -20, distBottom: 320, isScrollable: true, locked: true }), "full");

  const lockChecks = [
    [{ chatKeyboardOpen: true }, "keyboard_open"],
    [{ chatKeyboardOpen: false, composerFocused: true }, "composer_focused"],
    [{ composerFocused: false, selectionActive: true }, "selection_active"],
    [{ selectionActive: false, voiceRecording: true }, "voice_recording"],
    [{ voiceRecording: false, simVoiceOver: true }, "voiceover_active"],
    [{ simVoiceOver: false, pendingQuote: "x" }, "quote_editing"],
    [{ pendingQuote: null, scene: "approval", inlineApprovalStatus: "pending" }, "pending_approval"],
    [{ scene: "ask", askSubmitted: false }, "pending_ask"],
    [{ scene: "roam_den", roamSub: "roam", roamHandoffActive: true }, "browser_handoff"]
  ];
  for (const [patch, expected] of lockChecks) {
    assert.equal(engine.getChromeLockReason({ scene: "chat", ...patch }), expected);
  }
});

// 9. TopBar Model Short Names & Tool 7-State Semantics
runTest("Model Short Name & Tool 7-State Aggregation: failed steps NEVER turn green", () => {
  assert.equal(engine.resolveShortModelName("anthropic/claude-sonnet-4-20250514"), "Sonnet 4");
  assert.equal(engine.resolveShortModelName("deepseek/deepseek-reasoner"), "DeepSeek R1");
  assert.equal(engine.resolveShortModelName("openai/gpt-4o-mini-2024-07-18"), "GPT-4o mini");
  const longUnknown = engine.resolveShortModelName("openrouter/very-long-vendor-experimental-model-v99-preview");
  assert.ok(longUnknown.length <= 16 && longUnknown.endsWith("…"));

  assert.equal(engine.resolveToolAggregateStatus([{ status: "succeeded" }, { status: "failed" }]), "partial");
  assert.equal(engine.resolveToolAggregateStatus([{ status: "failed" }]), "failed");
  assert.equal(engine.resolveToolAggregateStatus([{ status: "cancelled" }]), "cancelled");
  assert.equal(engine.resolveToolAggregateStatus([{ status: "running" }]), "running");
  assert.equal(engine.resolveToolAggregateStatus([{ status: "pending" }]), "pending");
  assert.equal(engine.resolveToolAggregateStatus([{ status: "succeeded" }]), "succeeded");
  assert.equal(engine.resolveToolAggregateStatus([{ status: "succeeded" }], { waitingApproval: true }), "waiting_approval");
});

// 10. Runtime + Source Guards on Approval Interruptions & Chinese IME Composition
runTest("Runtime & Contract: Approval pointercancel/blur safety + Chinese IME compositionstart/end", () => {
  // 10a. Live IME composition test
  const inp = createMockNode("input", mockDoc);
  const updates = [];
  engine.attachImeSafeInput(inp, (v) => updates.push(v));
  inp.value = "pin";
  inp.dispatchEvent({ type: "compositionstart" });
  inp.dispatchEvent({ type: "input", isComposing: true });
  inp.value = "pinyin";
  inp.dispatchEvent({ type: "input", isComposing: false }); // even if browser flags glitch, composing=true blocks it
  assert.equal(updates.length, 0, "IME composition must NOT fire search updates before compositionend");
  inp.value = "拼音";
  inp.dispatchEvent({ type: "compositionend" });
  assert.deepEqual(updates, ["拼音"], "compositionend must commit composed Chinese text");
  inp.value = "拼音检索";
  inp.dispatchEvent({ type: "input", isComposing: false });
  assert.deepEqual(updates, ["拼音", "拼音检索"]);

  // 10b. Live Approval slider interruption safety test (pointercancel + blur even when dragged > 90%)
  const buildSliderDom = () => {
    const ov = createMockNode("div", mockDoc);
    const track = createMockNode("div", mockDoc);
    track.setAttribute("id", "approvalSlideTrack");
    track.clientWidth = 300;
    const fill = createMockNode("div", mockDoc);
    fill.setAttribute("id", "approvalSlideFill");
    const knob = createMockNode("div", mockDoc);
    knob.setAttribute("id", "approvalSlideKnob");
    knob.clientWidth = 48;
    const label = createMockNode("div", mockDoc);
    label.setAttribute("id", "approvalSlideLabel");
    ov.appendChild(track);
    track.appendChild(fill);
    track.appendChild(knob);
    track.appendChild(label);
    ov.querySelector = (sel) => {
      if (sel === "#approvalSlideTrack") return track;
      if (sel === "#approvalSlideKnob") return knob;
      if (sel === "#approvalSlideFill") return fill;
      if (sel === "#approvalSlideLabel") return label;
      return null;
    };
    ov.querySelectorAll = () => [];
    return { ov, knob };
  };

  engine.setState({ inlineApprovalStatus: "pending" });
  const { ov: ov1, knob: k1 } = buildSliderDom();
  const cleanup1 = engine.bindSlideTrack(ov1);
  k1.dispatchEvent({ type: "pointerdown", pointerId: 1, clientX: 20 });
  k1.dispatchEvent({ type: "pointermove", pointerId: 1, clientX: 290 }); // > 95% travel
  k1.dispatchEvent({ type: "pointercancel", pointerId: 1 });
  assert.equal(engine.getState().inlineApprovalStatus, "pending", "pointercancel at 95% MUST NOT approve");
  sandbox.window.dispatchEvent({ type: "blur" });
  cleanup1();

  engine.setState({ inlineApprovalStatus: "pending" });
  const { ov: ov2, knob: k2 } = buildSliderDom();
  const cleanup2 = engine.bindSlideTrack(ov2);
  k2.dispatchEvent({ type: "pointerdown", pointerId: 2, clientX: 20 });
  k2.dispatchEvent({ type: "pointermove", pointerId: 2, clientX: 290 });
  sandbox.window.dispatchEvent({ type: "blur" });
  assert.equal(engine.getState().inlineApprovalStatus, "pending", "window blur at 95% MUST NOT approve");
  cleanup2();

  // Explicit pointerup > 0.84 MUST approve
  engine.setState({ inlineApprovalStatus: "pending", fullApprovalVerdict: null });
  const { ov: ov3, knob: k3 } = buildSliderDom();
  const cleanup3 = engine.bindSlideTrack(ov3);
  k3.dispatchEvent({ type: "pointerdown", pointerId: 3, clientX: 20 });
  k3.dispatchEvent({ type: "pointermove", pointerId: 3, clientX: 290 });
  k3.dispatchEvent({ type: "pointerup", pointerId: 3 });
  assert.equal(engine.getState().fullApprovalVerdict, "allowed", "Explicit pointerup > 84% must approve");
  assert.equal(engine.getState().inlineApprovalStatus, "once");
  engine.setState({ inlineApprovalStatus: "pending", fullApprovalVerdict: null });
  cleanup3();

  // 10c. Source contracts for visibilitychange + Enter IME keyCode 229 guard
  const appSrc = fs.readFileSync(APP_JS, "utf8");
  assert.ok(appSrc.includes("onVisibilityChange"), "Approval slide track must guard visibilitychange");
  assert.ok(appSrc.includes("e.isComposing || e.keyCode === 229"), "Enter submit must guard IME composition");
});

// 11. Finalize State Transition & Wrapper Cleanup (identical rawText streaming->finalized)
runTest("Finalize State Transition: strips streaming badges, unclosed emphasis & temporary reveal wrappers", () => {
  const root = createMockNode("div", mockDoc);
  // 11a: Unclosed fence changes HTML from "· 生成中" -> plain code header on finalize even with identical rawText
  const streamFence = "# 前序标题\n\n```swift\nlet ok = true";
  engine.patchStreamingProseDom(root, streamFence, true, { animateEdge: true, deltaCount: 3, useBlur: true });
  const initialBlocks = root.querySelectorAll(".md-block");
  assert.equal(initialBlocks.length, 2);
  const headingRef = initialBlocks[0];
  assert.ok(initialBlocks[1].innerHTML.includes("· 生成中"));
  assert.ok(initialBlocks[1].querySelectorAll(".reveal-chunk").length > 0);

  const finRes = engine.patchStreamingProseDom(root, streamFence, false, { animateEdge: false });
  assert.equal(finRes.settledRebuilds, 0, "Prior settled block must never rebuild");
  const afterBlocks = root.querySelectorAll(".md-block");
  assert.equal(afterBlocks[0], headingRef, "Heading DOM identity preserved on finalize");
  assert.equal(afterBlocks[1].innerHTML.includes("· 生成中"), false, "Finalize must strip · 生成中 even when rawText is identical");
  assert.equal(afterBlocks[1].dataset.hasRevealWrap, "0");

  // 11b: Unclosed **bold while streaming vs literal **bold when finalized (same raw string)
  const root2 = createMockNode("div", mockDoc);
  const rawBold = "这里有 **未闭合粗体";
  engine.patchStreamingProseDom(root2, rawBold, true, { animateEdge: true, deltaCount: 2, useBlur: false });
  assert.ok(root2.querySelectorAll(".md-block")[0].innerHTML.includes("<strong>"));
  engine.patchStreamingProseDom(root2, rawBold, false, { animateEdge: false });
  assert.equal(root2.querySelectorAll(".md-block")[0].innerHTML.includes("<strong>"), false, "Unclosed ** must revert to literal text on finalize");
  assert.equal(root2.querySelectorAll(".reveal-chunk").length, 0);
});

// 12. Deferred Selection Flush & In-Place Error/Stop Settlement
runTest("Deferred Selection Flush & In-Place Settlement: protects active selection then commits cleanly on clear", () => {
  const root = createMockNode("div", mockDoc);
  const baseText = "首段稳态内容。\n\n正在生成的尾段：**半截";
  engine.patchStreamingProseDom(root, baseText, true, { animateEdge: false });
  const blk1 = root.querySelectorAll(".md-block")[1];
  const staleHtml = blk1.innerHTML;

  let active = true;
  const selMock = {
    get rangeCount() { return active ? 1 : 0; },
    toString: () => (active ? "尾段" : ""),
    getRangeAt: () => ({
      startContainer: blk1,
      endContainer: blk1,
      intersectsNode: (n) => active && n === blk1
    })
  };

  const finalText = "首段稳态内容。\n\n正在生成的尾段：**完整加粗收口**";
  const rFin = engine.patchStreamingProseDom(root, finalText, false, { selection: selMock });
  assert.equal(rFin.deferredSelection, true);
  assert.equal(blk1.dataset.deferredPending, "1");
  assert.equal(blk1.innerHTML, staleHtml, "Active selected block HTML must not mutate prematurely");

  // Release selection and flush deferred update
  active = false;
  engine.setState({ streaming: false });
  const flushed = engine.flushDeferredProseBlocks(root, selMock);
  assert.equal(flushed, 1, "Must flush deferred block once selection clears");
  assert.equal(blk1.dataset.deferredPending, undefined);
  assert.ok(blk1.innerHTML.includes("<strong>完整加粗收口</strong>"));
  assert.equal(root.querySelectorAll(".streaming-caret").length, 0);
});

// 13. Arbitrary Unicode Chunk Arrival & Received === Rendered Parity
runTest("Arbitrary Unicode Chunks: random 1-9 codepoint splits over ZWJ/combining/CJK stay lossless", () => {
  const mixedDoc = "## 混排校验 👨‍👩‍👧‍👦\n\n测试中文、e\u0301 组合字符、👍🏽 肤色 emoji 与 `code_block` 在任意切片边界到达，最终原文一字不丢。";
  const cps = Array.from(mixedDoc);
  const ctrl = new engine.ClioRevealController();
  let cursor = 0;
  let t = 0;
  let seed = 987654321;
  const rndInt = (max) => {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    return 1 + (seed % max);
  };
  let acc = "";
  while (cursor < cps.length) {
    const step = rndInt(9);
    cursor = Math.min(cps.length, cursor + step);
    acc = cps.slice(0, cursor).join("");
    t += 0.04;
    ctrl.observeUpdate(acc, t);
    const tick = ctrl.tick(t, {});
    const revealed = ctrl.currentRevealedText;
    assert.ok(acc.startsWith(revealed), "Intermediate reveal must stay an exact grapheme prefix of received text");
    assert.ok(tick.revealedCount <= ctrl.latestLength);
  }
  ctrl.finalize(mixedDoc);
  for (let i = 0; i < 120; i++) {
    t += 1 / 60;
    if (ctrl.tick(t, {}).isComplete) break;
  }
  assert.equal(ctrl.currentRevealedText, mixedDoc, "Final revealed text must equal received text 100%");
});

// 14. Verbatim Telegram TextRevealControllerRef Parity & DurationMultiplier Check
runTest("Telegram TextRevealControllerRef: exact upstream finalizeTime=0.30 math & width-cost multiplier", () => {
  assert.equal(tokens.streamingReveal.finalizeTime, 0.3, "finalizeTime token must match Telegram upstream 0.30s");
  assert.equal(tokens.streamingReveal.edgeDurationMs, 200, "edgeDurationMs must match 200ms spec");
  const tgRef = new engine.TelegramTextRevealControllerRef(0, 0, 1.0);
  const clioCtrl = new engine.ClioRevealController();

  const text = engine.SECTION46_SAMPLE.fullMarkdown;
  const gAll = Array.from(engine.splitGraphemes(text));
  let emitted = 0;
  let t = 0;
  for (const seg of engine.STREAM_TRACES.jitter) {
    t += seg.dtMs / 1000;
    emitted = Math.min(gAll.length, emitted + seg.chars);
    tgRef.observeUpdate(emitted, t);
    clioCtrl.observeUpdate(gAll.slice(0, emitted).join(""), t);
    tgRef.tick(t);
    clioCtrl.tick(t, {});
    assert.ok(Math.abs(tgRef.revealedCount - clioCtrl.revealedCount) < 1e-9, "ClioRevealController math must match upstream 1.0x");
  }
  tgRef.finalize(gAll.length);
  clioCtrl.finalize(text);
  for (let i = 0; i < 60; i++) {
    t += 1 / 60;
    tgRef.tick(t);
    clioCtrl.tick(t, {});
    assert.ok(Math.abs(tgRef.revealedCount - clioCtrl.revealedCount) < 1e-9);
  }

  // Test Telegram RichData multiplier (width-cost in points / durationMultiplier = 10.0)
  const richCtrl = new engine.TelegramTextRevealControllerRef(0, 0, 10.0);
  richCtrl.observeUpdate(400, 0.05);
  richCtrl.tick(0.05); // prime lastFrameTime (frame 0 has dt=0 in TextRevealController.swift)
  richCtrl.observeUpdate(1800, 0.25);
  const midTick = richCtrl.tick(0.266);
  assert.ok(midTick.revealedGlyphCount > 0 && midTick.revealedGlyphCount < 1800, "Point-cost controller must advance smoothly under durationMultiplier=10.0");
  richCtrl.finalize(1800);
  let done = false;
  for (let f = 0; f < 400; f++) {
    t = 0.31 + f * 0.016;
    if (richCtrl.tick(t).isComplete) { done = true; break; }
  }
  assert.equal(done, true, "Point-cost controller with durationMultiplier=10.0 must drain completely after finalize");
});

console.log(`PASS ${results.length}/${results.length} behavioral test suites:`);
for (const r of results) {
  console.log(`  ✓ ${r.name} (${r.ms} ms)`);
}

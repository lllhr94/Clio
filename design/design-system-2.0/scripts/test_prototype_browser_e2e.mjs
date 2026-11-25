#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const REPO_ROOT = path.resolve(ROOT, "..", "..");

function findChromeExecutable() {
  const candidates = process.platform === "win32"
    ? [
        "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
        "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
        "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe"
      ]
    : process.platform === "darwin"
      ? ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]
      : ["/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser"];
  return candidates.find((p) => fs.existsSync(p)) || null;
}

const MIME_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".mjs": "application/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".ttf": "font/ttf",
  ".png": "image/png",
  ".svg": "image/svg+xml"
};

function startStaticServer(rootDir) {
  const server = http.createServer((req, res) => {
    const reqPath = decodeURIComponent((req.url || "/").split("?")[0]);
    const safeRel = path.normalize(reqPath).replace(/^(\.\.[/\\])+/, "").replace(/^[/\\]+/, "");
    const absPath = path.resolve(rootDir, safeRel);
    if (!absPath.startsWith(rootDir) || !fs.existsSync(absPath) || fs.statSync(absPath).isDirectory()) {
      res.writeHead(404);
      res.end("Not found");
      return;
    }
    const ext = path.extname(absPath).toLowerCase();
    res.writeHead(200, { "Content-Type": MIME_TYPES[ext] || "application/octet-stream" });
    fs.createReadStream(absPath).pipe(res);
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      resolve({ server, port: addr.port });
    });
  });
}

class CdpSession {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.id = 0;
    this.pending = new Map();
    this.events = [];
  }
  async connect() {
    await new Promise((res, rej) => {
      this.ws.addEventListener("open", res, { once: true });
      this.ws.addEventListener("error", rej, { once: true });
    });
    this.ws.addEventListener("message", (msg) => {
      const data = JSON.parse(msg.data);
      if (data.id && this.pending.has(data.id)) {
        const { res, rej } = this.pending.get(data.id);
        this.pending.delete(data.id);
        if (data.error) rej(new Error(JSON.stringify(data.error)));
        else res(data.result);
      } else if (data.method) {
        this.events.push({ method: data.method, params: data.params });
      }
    });
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((res, rej) => {
      this.pending.set(id, { res, rej });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  async evalJs(expression) {
    const res = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true
    });
    if (res.exceptionDetails) {
      throw new Error("Browser JS exception: " + (res.exceptionDetails.exception?.description || res.exceptionDetails.text));
    }
    return res.result?.value;
  }
  close() {
    try { this.ws.close(); } catch {}
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitUntil(client, jsPredicate, timeoutMs = 8000, label = "condition") {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await client.evalJs(jsPredicate)) return;
    await sleep(60);
  }
  throw new Error(`Timed out after ${timeoutMs}ms waiting for ${label}`);
}

const chromeExe = findChromeExecutable();
assert.ok(chromeExe, "Chrome/Edge executable not found on this machine for real browser E2E");

const { server, port } = await startStaticServer(REPO_ROOT);
const tmpProfile = fs.mkdtempSync(path.join(os.tmpdir(), "clio-ds2-e2e-"));
const chrome = spawn(
  chromeExe,
  [
    "--headless=new",
    "--disable-gpu",
    "--no-first-run",
    "--no-default-browser-check",
    "--window-size=1280,960",
    "--remote-debugging-port=0",
    `--user-data-dir=${tmpProfile}`,
    "about:blank"
  ],
  { stdio: ["ignore", "ignore", "pipe"], windowsHide: true }
);

let client = null;
try {
  const wsBrowserUrl = await new Promise((resolve, reject) => {
    let stderr = "";
    const timer = setTimeout(() => reject(new Error("Chrome DevTools startup timeout: " + stderr)), 10000);
    chrome.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
      const m = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (m) {
        clearTimeout(timer);
        resolve(m[1]);
      }
    });
  });

  const httpBase = wsBrowserUrl.replace(/^ws:/, "http:").replace(/\/devtools\/browser\/.*$/, "");
  const pageTarget = (await (await fetch(`${httpBase}/json/list`)).json()).find((t) => t.type === "page");
  assert.ok(pageTarget?.webSocketDebuggerUrl, "Missing CDP page target");

  client = new CdpSession(pageTarget.webSocketDebuggerUrl);
  await client.connect();
  await client.send("Page.enable");
  await client.send("Runtime.enable");
  await client.send("Log.enable");
  await client.send("Network.enable");

  const targetUrl = `http://127.0.0.1:${port}/design/design-system-2.0/prototype/index.html`;
  await client.send("Page.navigate", { url: targetUrl });
  await waitUntil(client, `Boolean(window.CLIO_STREAM_ENGINE && document.getElementById("btnSimulateStream"))`, 8000, "prototype boot");
  await client.evalJs(`document.fonts.ready.then(() => true)`);
  await sleep(250);

  // Check 1: All 6 App/Fonts TTFs loaded cleanly + zero HTTP >= 400
  const fontsStatus = await client.evalJs(`
    Array.from(document.fonts).map(f => ({ family: f.family.replace(/["']/g, ""), weight: f.weight, status: f.status }))
  `);
  for (const [fam, w] of [["ClioKaiWeb", "400"], ["ClioKaiWeb", "500"], ["MapleMonoWeb", "400"], ["MapleMonoWeb", "600"], ["ClioMonoCNWeb", "400"], ["ClioSealWeb", "400"]]) {
    assert.ok(fontsStatus.some((f) => f.family === fam && f.weight === w && f.status === "loaded"), `Expected font ${fam}:${w} loaded`);
  }

  // E2E-1: Real Selection inside settled block survives natural Stream Completion without wiping DOM or scrollTop
  await client.evalJs(`document.getElementById("btnSimulateStream").click()`);
  await waitUntil(client, `(() => {
    const turnId = window.CLIO_STREAM_ENGINE.getState().streamingTurnId;
    const prose = document.querySelector('[data-turn-prose="' + turnId + '"]');
    return Boolean(prose && prose.querySelectorAll('.md-block').length >= 2 && (prose.innerText || '').length > 40);
  })()`, 8000, "stream >= 2 blocks");

  const selSetup1 = await client.evalJs(`(() => {
    const sc = document.getElementById("mainScroller");
    const turnId = window.CLIO_STREAM_ENGINE.getState().streamingTurnId;
    const prose = document.querySelector('[data-turn-prose="' + turnId + '"]');
    const firstBlock = prose.querySelectorAll('.md-block')[0];
    const walk = document.createTreeWalker(firstBlock, NodeFilter.SHOW_TEXT);
    const tn = walk.nextNode();
    const len = tn ? tn.nodeValue.length : 0;
    const r = document.createRange();
    r.setStart(tn, 0);
    r.setEnd(tn, Math.min(len, 6));
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
    sc.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    window.__e2eTurnId = turnId;
    window.__e2eSelBlock = firstBlock;
    window.__e2eSavedText = sel.toString();
    window.__e2eSavedScroll = sc.scrollTop;
    return { text: window.__e2eSavedText, hasToolbar: Boolean(document.querySelector(".selection-toolbar")) };
  })()`);
  assert.ok(selSetup1.text.length >= 2, "E2E-1 must hold non-empty browser selection");
  assert.equal(selSetup1.hasToolbar, true, "E2E-1 must display floating selection toolbar");

  await waitUntil(client, `!window.CLIO_STREAM_ENGINE.getState().streaming`, 12000, "E2E-1 stream completion");
  const afterComplete = await client.evalJs(`(() => {
    const sc = document.getElementById("mainScroller");
    const prose = document.querySelector('[data-turn-prose="' + window.__e2eTurnId + '"]');
    return {
      selText: window.getSelection().toString(),
      savedText: window.__e2eSavedText,
      nodeConnected: window.__e2eSelBlock.isConnected,
      hasToolbar: Boolean(document.querySelector(".selection-toolbar")),
      scrollDelta: Math.abs(sc.scrollTop - window.__e2eSavedScroll),
      caretCount: prose.querySelectorAll(".streaming-caret").length,
      renderedLen: (prose.innerText || "").length
    };
  })()`);
  assert.equal(afterComplete.selText, afterComplete.savedText, "E2E-1: Browser selection destroyed during finalize!");
  assert.equal(afterComplete.nodeConnected, true, "E2E-1: Selected DOM node was replaced on finalize!");
  assert.equal(afterComplete.hasToolbar, true, "E2E-1: Selection toolbar lost on finalize!");
  assert.ok(afterComplete.scrollDelta < 2, `E2E-1: scrollTop shifted by ${afterComplete.scrollDelta}`);
  assert.equal(afterComplete.caretCount, 0, "E2E-1: Stale streaming caret left after finalize");
  assert.ok(afterComplete.renderedLen > 120, "E2E-1: Finalized content incomplete");

  // E2E-2: Clear selection & verify Stop Streaming preserves selection and received text
  await client.evalJs(`
    window.getSelection().removeAllRanges();
    document.getElementById("selClose")?.click();
    document.getElementById("btnSimulateStream").click();
  `);
  await waitUntil(client, `(() => {
    const turnId = window.CLIO_STREAM_ENGINE.getState().streamingTurnId;
    const prose = document.querySelector('[data-turn-prose="' + turnId + '"]');
    return Boolean(prose && prose.querySelectorAll('.md-block').length >= 1 && (prose.innerText || '').length > 18);
  })()`, 8000, "E2E-2 stream start");

  await client.evalJs(`(() => {
    const turnId = window.CLIO_STREAM_ENGINE.getState().streamingTurnId;
    const prose = document.querySelector('[data-turn-prose="' + turnId + '"]');
    const blk = prose.querySelectorAll('.md-block')[0];
    const tn = document.createTreeWalker(blk, NodeFilter.SHOW_TEXT).nextNode();
    const r = document.createRange();
    r.setStart(tn, 0);
    r.setEnd(tn, Math.min(tn.nodeValue.length, 5));
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
    document.getElementById("mainScroller").dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    window.__e2eStopTurnId = turnId;
    window.__e2eStopBlock = blk;
    window.__e2eStopText = sel.toString();
    document.getElementById("btnSimulateStream").click();
  })()`);
  await sleep(120);
  const afterStop = await client.evalJs(`(() => {
    const prose = document.querySelector('[data-turn-prose="' + window.__e2eStopTurnId + '"]');
    return {
      streaming: window.CLIO_STREAM_ENGINE.getState().streaming,
      selText: window.getSelection().toString(),
      expectedText: window.__e2eStopText,
      connected: window.__e2eStopBlock.isConnected,
      caretCount: prose.querySelectorAll(".streaming-caret").length,
      proseText: prose.innerText || ""
    };
  })()`);
  assert.equal(afterStop.streaming, false, "E2E-2: Stop failed");
  assert.equal(afterStop.selText, afterStop.expectedText, "E2E-2: Selection destroyed on user Stop!");
  assert.equal(afterStop.connected, true, "E2E-2: Block replaced on user Stop!");
  assert.equal(afterStop.caretCount, 0);
  assert.ok(afterStop.proseText.length >= 18);

  // E2E-3: Select INSIDE active last evolving block -> stream finishes -> deferredPending === "1" -> clear selection flushes final HTML
  await client.evalJs(`
    window.getSelection().removeAllRanges();
    document.getElementById("selClose")?.click();
    window.__e2eDeferTurn = { id: 901, user: "deferred test", metrics: "0.4s", aiBody: "", plainText: "" };
    window.CLIO_STREAM_ENGINE.getState().chatTurns.push(window.__e2eDeferTurn);
    window.CLIO_STREAM_ENGINE.startStreamIntoTurn(
      window.__e2eDeferTurn,
      "# 标题\\n\\n**正在加粗的尾巴内容_追加字符_全部完成**",
      "0.4s"
    );
  `);
  await waitUntil(client, `(() => {
    const prose = document.querySelector('[data-turn-prose="901"]');
    const blocks = prose ? prose.querySelectorAll('.md-block') : [];
    return blocks.length >= 2 && (blocks[1].innerText || '').length >= 4;
  })()`, 6000, "E2E-3 block 1 evolving");

  const deferPick = await client.evalJs(`(() => {
    const prose = document.querySelector('[data-turn-prose="901"]');
    const blk = prose.querySelectorAll('.md-block')[1];
    const tn = document.createTreeWalker(blk, NodeFilter.SHOW_TEXT).nextNode();
    const r = document.createRange();
    r.setStart(tn, 0);
    r.setEnd(tn, Math.min(tn.nodeValue.length, 3));
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
    document.getElementById("mainScroller").dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    window.__e2eDeferBlk = blk;
    return sel.toString();
  })()`);
  assert.ok(deferPick.length >= 2, "E2E-3 active block selection created");

  await waitUntil(client, `!window.CLIO_STREAM_ENGINE.getState().streaming`, 8000, "E2E-3 complete");
  const whileDeferred = await client.evalJs(`({
    deferredFlag: window.__e2eDeferBlk.dataset.deferredPending,
    selText: window.getSelection().toString(),
    innerText: window.__e2eDeferBlk.innerText
  })`);
  assert.equal(whileDeferred.deferredFlag, "1", "E2E-3: Selected evolving block must defer mutation until selection clears");
  assert.equal(whileDeferred.selText, deferPick);

  await client.evalJs(`
    window.getSelection().removeAllRanges();
    document.dispatchEvent(new Event("selectionchange"));
    document.getElementById("selClose")?.click();
  `);
  await sleep(100);
  const afterFlush = await client.evalJs(`(() => {
    const prose = document.querySelector('[data-turn-prose="901"]');
    const blk = prose.querySelectorAll('.md-block')[1];
    return {
      deferredCount: prose.querySelectorAll('[data-deferred-pending="1"]').length,
      wrapCount: prose.querySelectorAll('.reveal-chunk').length,
      caretCount: prose.querySelectorAll('.streaming-caret').length,
      text: blk.innerText,
      hasStrong: Boolean(blk.querySelector('strong'))
    };
  })()`);
  assert.equal(afterFlush.deferredCount, 0, "E2E-3: Deferred block must flush immediately after selection clears");
  assert.equal(afterFlush.wrapCount, 0, "E2E-3: Temporary reveal wrappers must be unwrapped on settle");
  assert.equal(afterFlush.caretCount, 0);
  assert.equal(afterFlush.hasStrong, true);
  assert.ok(afterFlush.text.includes("全部完成"), `Expected flushed full text, got ${afterFlush.text}`);

  // E2E-4: Error failure preserves partial text and selection
  await client.evalJs(`
    window.__e2eErrTurn = { id: 902, user: "err test", metrics: "0.2s", aiBody: "", plainText: "" };
    window.CLIO_STREAM_ENGINE.getState().chatTurns.push(window.__e2eErrTurn);
    window.CLIO_STREAM_ENGINE.startStreamIntoTurn(window.__e2eErrTurn, "已成功接收的前序稳态段落。", "0.2s");
  `);
  await waitUntil(client, `(() => {
    const prose = document.querySelector('[data-turn-prose="902"]');
    return Boolean(prose && (prose.innerText || "").length >= 4);
  })()`, 5000, "E2E-4 receive prefix");
  await client.evalJs(`window.CLIO_STREAM_ENGINE.failActiveStream("模拟连接中断")`);
  const errState = await client.evalJs(`({
    streaming: window.CLIO_STREAM_ENGINE.getState().streaming,
    text: document.querySelector('[data-turn-prose="902"]')?.innerText || ""
  })`);
  assert.equal(errState.streaming, false);
  assert.ok(errState.text.includes("已成功"), `Error recovery must retain received prefix, got ${errState.text}`);

  // E2E-5: Scroll-Aware Chrome during streaming shows #btnImmersiveStop & simulated keyboard forces chrome=full
  await client.evalJs(`document.getElementById("btnSimulateStream").click()`);
  await sleep(160);
  await client.evalJs(`
    const sc = document.getElementById("mainScroller");
    sc.scrollTo({ top: sc.scrollHeight - sc.clientHeight, behavior: "instant" });
  `);
  await sleep(220);
  const scCenter = await client.evalJs(`(() => {
    const r = document.getElementById("mainScroller").getBoundingClientRect();
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
  })()`);
  for (let i = 0; i < 8; i++) {
    await client.send("Input.dispatchMouseEvent", { type: "mouseWheel", x: scCenter.x, y: scCenter.y, deltaX: 0, deltaY: -120 });
    await sleep(60);
  }
  await sleep(260);
  const immStream = await client.evalJs(`({
    chrome: document.getElementById("iphoneScreen").dataset.chrome,
    stopDisplay: getComputedStyle(document.getElementById("btnImmersiveStop")).display
  })`);
  assert.equal(immStream.chrome, "immersive", "E2E-5: Scroll up far from bottom must enter immersive chrome");
  assert.notEqual(immStream.stopDisplay, "none", "E2E-5: Immersive streaming must keep Stop button accessible");

  await client.evalJs(`document.getElementById("btnImmersiveStop").click()`);
  await sleep(100);
  assert.equal(await client.evalJs(`window.CLIO_STREAM_ENGINE.getState().streaming`), false, "E2E-5: Immersive stop button must stop generation");

  await client.evalJs(`document.getElementById("btnToggleSimKeyboard").click()`);
  await sleep(120);
  assert.equal(await client.evalJs(`document.getElementById("iphoneScreen").dataset.chrome`), "full", "Keyboard lock must restore chrome=full");

  const exceptions = client.events.filter((e) => e.method === "Runtime.exceptionThrown");
  const badHttp = client.events.filter((e) => e.method === "Network.responseReceived" && e.params?.response?.status >= 400);
  const errLogs = client.events.filter((e) => e.method === "Log.entryAdded" && e.params?.entry?.level === "error");
  assert.equal(exceptions.length, 0, `Unexpected browser JS exceptions: ${JSON.stringify(exceptions)}`);
  assert.equal(badHttp.length, 0, `Unexpected HTTP >= 400 responses: ${JSON.stringify(badHttp.map(x => x.params.response.url))}`);
  assert.equal(errLogs.length, 0, `Unexpected browser error console logs: ${JSON.stringify(errLogs)}`);

  console.log("PASS 6/6 real-Chrome E2E tests (6 fonts loaded, selection preserved on finalize/stop/defer-flush, error prefix kept, Scroll-Aware Chrome + immersive Stop, 0 exceptions, 0 HTTP errors).");
} finally {
  if (client) client.close();
  try { chrome.kill(); } catch {}
  try { server.close(); } catch {}
  try { fs.rmSync(tmpProfile, { recursive: true, force: true }); } catch {}
}

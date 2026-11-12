// ハブを行き来するクリップ再生。端のコマは基準絵と一致するので、
// クリップの切り替えに遅れが出ても canvas に残る最後の絵がそのまま次の最初の絵になる。
const tauri = window.__TAURI__;
let QA = new Set();
const log = (m) => (tauri ? tauri.core.invoke("log", { msg: String(m) }) : console.log(m));
window.addEventListener("error", (e) => log("error " + e.message));
window.addEventListener("unhandledrejection", (e) => log("reject " + e.reason));

const canvas = document.getElementById("c");
const gl = canvas.getContext("webgl", { alpha: true, premultipliedAlpha: true, preserveDrawingBuffer: true, antialias: false });
const prog = gl.createProgram();
for (const [t, s] of [
  [gl.VERTEX_SHADER, "attribute vec2 p;varying vec2 v;void main(){v=vec2(p.x*.5+.5,.5-p.y*.5);gl_Position=vec4(p,0.,1.);}"],
  [gl.FRAGMENT_SHADER, "precision mediump float;varying vec2 v;uniform sampler2D t;void main(){vec3 c=texture2D(t,vec2(v.x*.5,v.y)).rgb;float a=texture2D(t,vec2(v.x*.5+.5,v.y)).r;gl_FragColor=vec4(c,a);}"],
]) { const o = gl.createShader(t); gl.shaderSource(o, s); gl.compileShader(o); gl.attachShader(prog, o); }
gl.linkProgram(prog); gl.useProgram(prog);
gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
gl.enableVertexAttribArray(0); gl.bindAttribLocation(prog, 0, "p"); gl.linkProgram(prog); gl.useProgram(prog);
gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
gl.bindTexture(gl.TEXTURE_2D, gl.createTexture());
for (const [k, v] of [[gl.TEXTURE_MIN_FILTER, gl.LINEAR], [gl.TEXTURE_MAG_FILTER, gl.LINEAR], [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]]) gl.texParameteri(gl.TEXTURE_2D, k, v);

function draw(v) {
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, v);
  gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
}

const NAMES = [...new Set([...Object.keys(Brain.GRAPH)])];
let blobs = {};
let meta = {};
const video = document.createElement("video");
video.muted = true; video.playsInline = true; video.preload = "auto";
// パックは全部同じ形式。id が null なら同梱のデフォルト、それ以外は利用者の手元のパック
async function readPack(id, names) {
  const read = id
    ? (name) => tauri.core.invoke("pack_file", { id, name })
    : async (name) => (await fetch(`packs/default/clips/${name}`)).arrayBuffer();
  const json = JSON.parse(new TextDecoder().decode(await read("clips.json")));
  const urls = {};
  await Promise.all(names.map(async (n) => {
    urls[n] = URL.createObjectURL(new Blob([await read(`${n}.mp4`)], { type: "video/mp4" }));
  }));
  return { json, urls };
}
async function loadPack(names) {
  const id = tauri ? await tauri.core.invoke("character") : null;
  try {
    const pack = await readPack(id, names);
    meta = pack.json; blobs = pack.urls;
    log("pack " + (id ?? "default"));
  } catch (e) { // 壊れたパックでも起動できるようにする
    log(`pack ${id} failed: ${e}`);
    const pack = await readPack(null, names);
    meta = pack.json; blobs = pack.urls;
  }
}
function open(n) {
  return new Promise((ok, ng) => {
    video.oncanplay = ok; video.onerror = () => ng(new Error("video " + n));
    video.src = blobs[n]; video.load();
  });
}
function release() { // デコーダとコマのバッファを返す。canvas には最後の絵が残る
  video.oncanplay = video.onerror = video.onended = null;
  video.removeAttribute("src"); video.load();
}

async function play(n) {
  const v = video, keep = new Set(meta[n].draw);
  try { await open(n); } catch (e) { log("open failed " + e); release(); return; }
  await new Promise((done) => {
    let live = true, req = 0; // 残った予約は WebKit の画面更新を毎フレーム起こし続けるので必ず取り消す
    const finish = (why) => {
      if (!live) return;
      live = false; clearTimeout(guard); v.cancelVideoFrameCallback(req);
      if (why) log(`${why} ${n}`); else draw(v); // 最後のコマ＝ハブの絵を必ず残す
      done();
    };
    // スリープ復帰などで ended が来なくても行動を止めない
    const guard = setTimeout(() => finish("timeout"), (v.duration + 2) * 1000);
    // 生成動画は 2〜3 コマ打ちなので、絵が変わるコマだけ描いて画面更新を減らす
    const tick = (_, md) => {
      if (!live) return;
      if (keep.has(Math.round(md.mediaTime * 24))) draw(v);
      req = v.requestVideoFrameCallback(tick);
    };
    v.onended = () => finish();
    req = v.requestVideoFrameCallback(tick);
    v.play().catch((e) => {
      if (e.name !== "NotAllowedError") return finish("play failed " + e);
      // 低電力モードの WebKit はミュート動画の自動再生も拒む。シークは許されるので、描くコマへ順に飛んで描く
      live = false; clearTimeout(guard); v.cancelVideoFrameCallback(req);
      if (!seekMode) { seekMode = true; log("autoplay blocked, seeking instead"); }
      step(n).then(done);
    });
  });
  release();
}
let seekMode = false;
async function step(n) {
  const v = video, { frames, draw: keep } = meta[n];
  const marks = [...new Set([...keep, frames - 1])].sort((a, b) => a - b); // 最後のコマ＝ハブの絵を必ず残す
  const start = performance.now();
  for (let i = 0; i < marks.length; i++) {
    const due = start + (marks[i] / 24) * 1000;
    if (i < marks.length - 1 && performance.now() > start + (marks[i + 1] / 24) * 1000) continue; // 遅れたら飛ばす
    const late = due - performance.now();
    if (late > 0) await new Promise((r) => setTimeout(r, late));
    const ok = await new Promise((r) => {
      const t = setTimeout(() => r(false), 2000);
      v.onseeked = () => { clearTimeout(t); r(true); };
      v.currentTime = (marks[i] + 0.5) / 24;
    });
    v.onseeked = null;
    if (!ok) { log(`seek timeout ${n}`); return; }
    draw(v);
  }
}

// ── 行動 ─────────────────────────
const brain = new Brain.Brain();
const now = () => performance.now() / 1000;
let wake = () => {}, timer = 0;
const wait = (s) => new Promise((r) => { wake = r; timer = setTimeout(r, s * 1000); });
const rnd = (a, b) => a + Math.random() * (b - a);

async function hold() {
  const [lo, hi] = Brain.HOLD[brain.hub];
  const until = now() + rnd(lo, hi);
  const blink = Brain.BLINK[brain.hub];
  while (now() < until && !brain.pending) {
    const left = until - now();
    const step = blink ? rnd(2.2, 5.5) : left;
    await wait(Math.min(step, left));
    if (blink && now() < until && !brain.pending && !unseen()) await play(blink);
  }
}
async function life() {
  await play("blink");
  if (QA.has("noclips")) return;
  for (;;) {
    if (unseen()) { await wait(1); continue; } // 見えない間は動画を再生しない
    if (QA.has("panelq") && brain.hub === "Q" && !panelOpen) openPanel(); // 実機でパネルを通す計測用
    await hold();
    if (unseen()) continue; // 待っている間に見えなくなった
    const n = brain.next(now());
    if (!n) continue;
    log("play " + n);
    await play(n);
    brain.done(n, now());
    showBubble();
  }
}
function interrupt() {
  if (brain.hub !== "I") { clearTimeout(timer); wake(); } // ひらめきの決めポーズは短く見せ切る
}
function react() {
  log("clicked at hub " + brain.hub);
  if (panelOpen) tauri?.core.invoke("hide_panel");
  else { brain.click(); openPanel(); }
  interrupt();
}

// ── 待機と応答 ───────────────────
// 待機中はクリックを下のウィンドウへ通し、カーソルが重なると薄くなる。応答はホットキーで始まる。
const ENGAGE_SECONDS = 10, UNDIM_SECONDS = 0.3, SAY_SECONDS = 8;
let engaged = false, hotkeyWorks = true, touched = 0, sayTimer = 0;
// ホットキーがなければ、触れないと何もできなくなる。大きな吹き出しの間は前面の窓がキーを持ち、
// 背後のキャラクターへのクリックは WebKit が横取りするので受けない。閉じるのは ×、Esc、ホットキー
const clickable = () => (engaged && !covered()) || !hotkeyWorks;

function say(text, seconds = SAY_SECONDS) {
  clearTimeout(sayTimer);
  reply = text;
  showBubble();
  if (text) sayTimer = setTimeout(() => say(""), seconds * 1000);
}
function engage() { engaged = true; touched = now(); dim(false); }
function disengage() { engaged = false; say(""); }
function summon() {
  log("hotkey at hub " + brain.hub);
  if (covered()) { engaged = false; return void tauri.core.invoke(panelOpen ? "hide_panel" : "hide_settings"); }
  engage();
  brain.click();
  openPanel();
  interrupt();
}
function applyHotkey({ keys, active }) {
  hotkeyWorks = active;
  if (!active) say("ホットキーを使えませんでした。右クリックの設定から変更できます");
  return keys;
}

// ── familiar の状態 ─────────────────
const POLL_SECONDS = 2, HEADLINE = 30;
const STALE_SCAN = 15 * 60; // 見回りが落ちて scanning が残っても考え続けないようにする
let live = { scanning: false, pending: 0, held: 0, scanSeq: null, lastAdded: 0, lastError: null };
let panelOpen = false, settingsOpen = false, lastBubble = null, lastNotch = null, reply = "", notchMode = false;
let incoming = ""; // 入れ替えを待っている新しい版
const covered = () => panelOpen || settingsOpen; // 大きな吹き出しのどちらかが開いている
// 全画面アプリの Space には macOS がこの窓を出さず、WebKit はそれをページの非表示として伝える
const unseen = () => notchMode || document.hidden;

function bubbleText() {
  if (notchMode) return "";
  if (covered()) return ""; // 大きな吹き出しが開いている間は、そちらが代わりになる
  if (reply) return reply;
  if (live.lastError) return "見回りがうまくいきませんでした";
  const title = live.headline && live.headline.length > HEADLINE ? `${live.headline.slice(0, HEADLINE)}…` : live.headline;
  const fresh = !title ? `気になることが ${live.pending} 件あります`
    : live.pending > 1 ? `${title}\nほか ${live.pending - 1} 件` : title;
  if (live.pending > 0 && live.held > 0) return `${fresh}。\n後回しの件も ${live.held} 件残っています`;
  if (live.pending > 0) return fresh;
  if (live.held > 0) return `後回しの件が ${live.held} 件残っています`;
  // 再起動は手が離れてからなので、戻ってきた人にも見えるよう入れ替えまで出しておく
  return incoming ? updateNotice(incoming) : "";
}
const updateNotice = (version) => `新しいバージョン ${version} が届きました。\n手が空いたときに入れ替えます`;
// 空のオブジェクトならノッチの窓を隠す
function notchState() {
  const state = {};
  if (brain.scanning) state.scanning = true;
  if (live.lastError) state.error = true;
  if (live.pending > 0) state.count = live.pending;
  else if (live.held > 0) { state.count = live.held; state.held = true; }
  if (engaged) state.engaged = true;
  return state;
}
function showNotch() {
  const state = notchMode ? notchState() : {}, text = JSON.stringify(state);
  if (text === lastNotch) return;
  lastNotch = text;
  tauri?.core.invoke("notch", { state });
}
function showBubble() {
  showNotch();
  const text = bubbleText();
  if (text === lastBubble) return;
  lastBubble = text;
  if (tauri) tauri.core.invoke("bubble", { text });
}

function applyLive(next) {
  const started = next.scanStarted ? Date.parse(next.scanStarted) : 0;
  const scanning = !!next.scanning && Date.now() - started < STALE_SCAN * 1000;
  const finished = live.scanSeq !== null && next.scanSeq !== live.scanSeq;
  const changed = scanning !== brain.scanning || next.pending !== live.pending || finished;
  if (finished && next.lastAdded > 0) brain.discover();
  live = { ...next, held: next.held ?? 0 };
  brain.sync({ scanning, waiting: next.pending, panel: panelOpen });
  showBubble();
  if (changed) { log(`live scanning=${scanning} pending=${next.pending} added=${finished ? next.lastAdded : "-"}`); interrupt(); }
}
function openPanel() {
  panelOpen = true;
  brain.sync({ scanning: brain.scanning, waiting: live.pending, panel: true });
  showBubble();
  tauri?.core.invoke("show_panel");
}
function startLive() {
  if (!tauri) return;
  const awaySeconds = QA.has("fastaway") ? 5 : Brain.AWAY; // 実機で離席を通す計測用
  const read = async () => {
    try { applyLive(JSON.parse(await tauri.core.invoke("live"))); } catch (e) { log("live " + e); }
    const away = await tauri.core.invoke("idle_seconds") >= awaySeconds;
    if (brain.setAway(away) && brain.hub === "B") { brain.click(); interrupt(); } // 戻ったらすぐ振り向く
    else if (away && brain.hub === "F") interrupt();
  };
  read();
  setInterval(read, POLL_SECONDS * 1000);
  tauri.event.listen("panel-closed", () => {
    panelOpen = false;
    brain.sync({ scanning: brain.scanning, waiting: live.pending, panel: false });
    // 保留が残っていても右クリックできるよう、× や Esc で閉じたあとも応答を続ける
    touched = now();
    showBubble();
    interrupt();
  });
}
function applyDisplay({ mode }) {
  notchMode = mode === "notch";
  if (notchMode) dim(false);
  showBubble();
  interrupt();
}
function startSettings() {
  if (!tauri) return;
  tauri.event.listen("display-changed", ({ payload }) => applyDisplay(payload));
  tauri.event.listen("notch-click", react);
  tauri.event.listen("settings-open", () => { settingsOpen = true; showBubble(); });
  tauri.event.listen("talk", react);
  tauri.event.listen("settings-closed", () => { settingsOpen = false; touched = now(); showBubble(); });
  if (QA.has("settings")) tauri.core.invoke("show_settings"); // 実機で設定を開く計測用
  if (QA.has("talk")) openPanel(); // 実機で会話を開く計測用
  // 初回は声をかける
  tauri.core.invoke("familiar", { args: ["thread", "--limit", "1"] })
    .then((state) => { if (JSON.parse(state).onboarding) openPanel(); })
    .catch((e) => log("thread " + e));
}
async function startHotkey() {
  if (!tauri) return;
  tauri.event.listen("hotkey", summon);
  tauri.event.listen("hotkey-changed", ({ payload }) => applyHotkey(payload));
  const keys = applyHotkey(await tauri.core.invoke("hotkey"));
  if (hotkeyWorks && await tauri.core.invoke("first_run")) say(`${hotkeyLabel(keys)} で呼んでください`, 15);
}

// ── 入力: 描かれた画素の上だけ受ける ─────────
const px = new Uint8Array(4);
function opaque(x, y) {
  const s = canvas.width / innerWidth;
  gl.readPixels(Math.round(x * s), Math.round(canvas.height - y * s), 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
  return px[3] > 40;
}
let downAt = 0;
canvas.addEventListener("mousedown", (e) => {
  log("mousedown " + e.button);
  if (e.button === 0) { downAt = e.timeStamp; if (tauri) setTimeout(() => { if (downAt) tauri.window.getCurrentWindow().startDragging(); }, 160); }
});
canvas.addEventListener("mouseup", (e) => { if (e.timeStamp - downAt < 160) { downAt = 0; react(); } downAt = 0; });
addEventListener("contextmenu", (e) => { e.preventDefault(); if (tauri) tauri.core.invoke("context_menu"); });
function startBreathing() {
  // 毎フレーム動かすと WindowServer が 1 コアの 2 割強を使う。量が小さいので 8fps で足りる
  setInterval(() => {
    if (unseen()) return;
    const k = 0.5 - 0.5 * Math.cos((2 * Math.PI * performance.now()) / 4200);
    canvas.style.transform = `scale(${1 + 0.002 * k},${1 + 0.006 * k})`;
  }, 125);
}

let dimmed = false;
function dim(on) {
  if (on === dimmed) return;
  dimmed = on;
  canvas.classList.toggle("dim", on);
  tauri.event.emit("dim", on);
}
function startPolling() {
  if (!tauri) return;
  const w = tauri.window.getCurrentWindow();
  let accepting = false, onBubble = false, hovered = 0;
  tauri.event.listen("bubble-hover", ({ payload }) => { onBubble = payload; });
  setInterval(async () => {
    if (unseen()) {
      if (engaged && !covered() && now() - touched > ENGAGE_SECONDS) disengage();
      return;
    }
    // 窓から見たカーソルの位置（ポイント）。倍率の違う画面にいても合う
    const [x, y] = await tauri.core.invoke("cursor");
    const inside = x >= 0 && y >= 0 && x < innerWidth && y < innerHeight && opaque(x, y);
    const wanted = clickable() && inside;
    if (wanted !== accepting) { accepting = wanted; w.setIgnoreCursorEvents(!accepting); }
    if (inside) touched = now();
    if (engaged && !covered() && now() - touched > ENGAGE_SECONDS) disengage();
    if (inside || onBubble) hovered = now();
    // 輪郭の上で点滅しないよう、離れてから少し待って戻す
    dim(!engaged && hotkeyWorks && now() - hovered < UNDIM_SECONDS);
  }, 200);
}

(async () => {
  if (tauri) QA = new Set((await tauri.core.invoke("qa_flags")).split(",").filter(Boolean));
  log("boot " + NAMES.length + " qa=" + [...QA]);
  if (tauri) notchMode = (await tauri.core.invoke("display")).mode === "notch";
  document.addEventListener("visibilitychange", () => log("hidden " + document.hidden));
  if (!QA.has("nobreath")) startBreathing();
  if (QA.has("hide")) canvas.style.display = "none";
  if (!QA.has("nopoll")) startPolling();
  await loadPack(QA.has("noload") ? ["blink"] : NAMES);
  log("loaded");
  startLive();
  startHotkey();
  startSettings();
  life();
  // 新しい版は入れ替える前に知らせ、再起動したあとにもう一度だけ知らせる
  tauri?.event.listen("update-ready", ({ payload }) => { incoming = payload; say(updateNotice(payload), 20); });
  tauri?.event.listen("say", ({ payload }) => say(payload)); // メニューから確かめたアップデートの結果など
  const updated = tauri && await tauri.core.invoke("just_updated");
  if (updated) say(`バージョン ${updated} になりました`);
})();

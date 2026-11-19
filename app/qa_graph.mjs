// 状態遷移の検査。引数でパックのディレクトリを渡すと、そのパックも検査する。クリックを任意の時点（クリップ再生中を含む）で入れて長時間シミュレーションする。
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import "./web/brain.js";
const { Brain, GRAPH, PHONE, HOLD, BLINK, ACT, stretchSlot } = globalThis.Brain;
const pack = process.argv[2] ?? new URL("./web/packs/default", import.meta.url).pathname;
const meta = JSON.parse(fs.readFileSync(`${pack}/clips/clips.json`));
execFileSync("node", ["--check", new URL("./web/main.js", import.meta.url).pathname]); // 構文エラーはログも出ず無言で止まる
const fail = (m) => { console.error("NG", m); process.exitCode = 1; };
const has = (c) => meta[c] && fs.existsSync(`${pack}/clips/${c}.mp4`);
for (const c of Object.keys(GRAPH)) if (!PHONE.includes(c) && !has(c)) fail("素材なし " + c);
// スマホのクリップは揃っているか、まったくないか。一部だけなら使わないので知らせる
const phone = PHONE.every(has);
if (!phone && PHONE.some(has)) fail("スマホのクリップが一部だけ " + PHONE.filter((c) => !has(c)));
for (const c of Object.keys(meta)) if (!GRAPH[c]) fail("遷移に未登録 " + c);
const hubs = [...new Set(Object.values(GRAPH).flat())];
for (const h of hubs) {
  if (!HOLD[h]) fail("HOLD なし " + h);
  const seen = new Set([h]); let go = true;
  while (go) { go = false; for (const [a, b] of Object.values(GRAPH)) if (seen.has(a) && !seen.has(b)) { seen.add(b); go = true; } }
  if (!seen.has("F")) fail(`${h} から F へ戻れない`);
}
for (const [k, c] of Object.entries(BLINK)) if (GRAPH[c][0] !== k || GRAPH[c][1] !== k) fail("まばたきが別ハブ " + c);
const MAX_REACH = 12; // 秒。再生中のクリップ 3 秒、ハブの通過 1 本、うなずき、スマホを出す 3 秒と、1 秒刻みの誤差
const EPOCH = new Date(2026, 0, 1).getTime();
function lcg(s) { return () => (s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32; }
// familiar の状態を乱数で変えながら、合図の約束が守られるかを見る。
let total = 0;
const reached = new Set();
const SIGNAL = ["think_in", "think_a", "think_b", "think_out", "idea", "idea_out", "idea_ask", "ask_in", "ask_wait", "ask_ok", "ask_out", "blink_t", "blink_q", ...PHONE];
// パックがスマホのクリップを持つ場合と持たない場合の両方を通す
for (const withPhone of phone ? [true, false] : [false]) for (const clickRate of [0, 0.05, 0.3, 2]) for (let seed = 1; seed <= 5; seed++) {
  const r = lcg(seed), b = new Brain(r), count = {};
  b.phone = withPhone;
  let t = 0, scanning = false, waiting = 0, panel = false, scanEnd = 0, nextScan = 600, stuck = 0, away = false, nextAway = 1200;
  let busy = false, busyEnd = 0, busyAt = null, asking = 0, prev = null, lost = 0;
  const clock = () => new Date(EPOCH + t * 1000), slots = new Set();
  const step = (d) => {
    for (let i = 0; i < d; i++) if (r() < clickRate) { if (waiting > 0) panel = true; else b.click(); }
    if (!scanning && t >= nextScan) { scanning = true; scanEnd = t + 20 + r() * 60; }
    if (scanning && t >= scanEnd) {
      scanning = false; nextScan = t + 1800;
      if (r() < 0.3) { waiting += 1 + Math.floor(r() * 3); b.discover(); }
    }
    if (panel && r() < 0.05) { waiting = Math.max(0, waiting - 1); if (waiting === 0 || r() < 0.3) panel = false; }
    // 会話で話しかけたり採用したりすると、しばらく作業が続く。終わると質問が返ることがある
    if (!busy && panel && r() < 0.02 * d) { busy = true; busyAt = t; busyEnd = t + 5 + r() * 90; if (asking > 0) asking--; }
    if (busy && t >= busyEnd) {
      busy = false; busyAt = null;
      if (r() < 0.4) { asking++; waiting = Math.max(waiting, asking); }
    }
    asking = Math.min(asking, waiting);
    b.sync({ scanning, waiting, panel, asking });
    b.setBusy(busy);
    if (t >= nextAway) { away = !away; nextAway = t + (away ? 300 + r() * 3000 : 600 + r() * 3000); }
    b.setAway(away);
  };
  let worst = 0;
  for (let i = 0; i < 100000; i++) {
    const [lo, hi] = HOLD[b.hub];
    // 合図（cue）が立てば待ち時間を切り上げる。main.js の hold() と同じ
    for (let h = b.cue ? 0 : lo + r() * (hi - lo); h > 0 && !b.cue;) { const d = Math.min(1, h); t += d; h -= d; step(d); }
    const hubBefore = b.hub, n = b.next(t, clock());
    if (!n) continue;
    if (GRAPH[n][0] !== hubBefore) fail(`不正な遷移 ${n} at ${hubBefore}`);
    if (n === "turn_away" && (!away || waiting > 0 || scanning)) fail("離席していないのに背を向けた");
    if (n === "idle_b" && !away) fail("戻っているのに背中のまま");
    if (n === "stretch") {
      const slot = stretchSlot(clock());
      if (slot === null) fail("25 分と 55 分以外で伸びをした " + clock());
      if (slots.has(slot)) fail("同じ回に 2 度伸びをした");
      slots.add(slot);
    }
    if (n === "idea" && scanning) fail("見回り中に閃いた");
    if (n === "ask_ok" && waiting > 0 && !(withPhone && busy)) fail("提案が残っているのにうなずいた");
    if (n === "ask_in" && waiting === 0) fail("提案がないのに耳を傾けた");
    if (!withPhone && PHONE.includes(n)) fail("スマホのクリップがないパックで使った " + n);
    if (n === "nod" && !busy) fail("頼まれていないのにうなずいた");
    if (n === "phone_in" && !busy && asking === 0) fail("理由なくスマホを出した");
    if (n === "phone_in" && busy && !["nod", "ask_ok", "idea_out"].includes(prev)) fail("うなずかずにスマホを出した " + prev);
    if (n === "phone_a" && !busy) fail("作業がないのにスマホを操作した");
    if (n === "phone_ask" && (busy || asking === 0)) fail("返事が要らないのに問いかけた");
    if (n === "reply_wait" && asking === 0) fail("質問がないのに返事を待った");
    if (n === "reply_got" && !busy) fail("返事がないのにうなずいた");
    if (n === "phone_out" && (busy || asking > 0)) fail("まだ要るのにスマホをしまった");
    if ((n === "think_a" || n === "think_b") && !scanning) fail("見回りがないのに考え続けた");
    if (n === "think_in" && !scanning && !b.found) fail("理由なく考え始めた");
    count[n] = (count[n] || 0) + 1; total++;
    if (!Object.values(BLINK).includes(n)) prev = n;
    const d = meta[n].dur; t += d; step(d); b.done(n, t);
    if (b.hub === "P" && busyAt !== null) { if (withPhone) worst = Math.max(worst, t - busyAt); busyAt = null; }
    stuck = b.hub === "T" && !scanning ? stuck + 1 : 0;
    if (stuck > 2) fail("見回りが終わっても考え中から出ない");
    // 頼まれたのに、スマホのポーズへ向かわない時間が続かない（離席の背中から戻る分と、見回りの考え中を抜ける分を見込む）
    lost = withPhone && busy && b.hub !== "P" ? lost + 1 : 0;
    if (lost > 4) fail(`頼まれたのにスマホを出さない at ${b.hub} after ${n}`);
  }
  for (const c of Object.keys(count)) reached.add(c);
  // 頼まれてからスマホを両手で持つまで。途中のクリップを見終え、うなずいて出すまでに収まる
  if (worst > MAX_REACH) fail(`頼まれてからスマホまで ${worst.toFixed(1)} 秒かかった`);
  if (seed === 1) console.log(`phone ${withPhone} click/s ${clickRate}: 最長 ${worst.toFixed(1)}s, 実時間 ${(t / 3600).toFixed(0)}h, 閃き ${count.idea || 0}, うなずき ${count.ask_ok || 0}, 声かけ ${count.ask_in || 0}, スマホ ${count.phone_in || 0}, 問いかけ ${count.phone_ask || 0}`);
}
const miss = Object.keys(GRAPH).filter((c) => !reached.has(c) && !Object.values(BLINK).includes(c) && (phone || !PHONE.includes(c)));
if (miss.length) fail("未到達 " + miss);
for (const n of SIGNAL) if (ACT.F.concat(ACT.B).some(([x]) => x === n)) fail("合図が自発動作に入っている " + n);
for (const [m, want] of [[24, false], [25, true], [26, true], [27, false], [54, false], [55, true], [56, true], [57, false], [5, false]]) {
  if ((stretchSlot(new Date(2026, 0, 1, 10, m)) !== null) !== want) fail(`伸びの時間帯 ${m} 分`);
}
console.log(process.exitCode ? "FAILED" : "OK", "遷移数", total);

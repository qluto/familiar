// 状態遷移の検査。クリックを任意の時点（クリップ再生中を含む）で入れて長時間シミュレーションする。
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import "./web/brain.js";
const { Brain, GRAPH, HOLD, BLINK, ACT } = globalThis.Brain;
const meta = JSON.parse(fs.readFileSync(new URL("./web/clips/clips.json", import.meta.url)));
execFileSync("node", ["--check", new URL("./web/main.js", import.meta.url).pathname]); // 構文エラーはログも出ず無言で止まる
const fail = (m) => { console.error("NG", m); process.exitCode = 1; };
for (const c of Object.keys(GRAPH)) if (!meta[c]) fail("素材なし " + c);
for (const c of Object.keys(meta)) if (!GRAPH[c]) fail("遷移に未登録 " + c);
const hubs = [...new Set(Object.values(GRAPH).flat())];
for (const h of hubs) {
  if (!HOLD[h]) fail("HOLD なし " + h);
  const seen = new Set([h]); let go = true;
  while (go) { go = false; for (const [a, b] of Object.values(GRAPH)) if (seen.has(a) && !seen.has(b)) { seen.add(b); go = true; } }
  if (!seen.has("F")) fail(`${h} から F へ戻れない`);
}
for (const [k, c] of Object.entries(BLINK)) if (GRAPH[c][0] !== k || GRAPH[c][1] !== k) fail("まばたきが別ハブ " + c);
function lcg(s) { return () => (s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32; }
// familiar の状態を乱数で変えながら、合図の約束が守られるかを見る。
let total = 0;
const reached = new Set();
const SIGNAL = ["think_in", "think_a", "think_b", "think_out", "idea", "idea_out", "idea_ask", "ask_in", "ask_wait", "ask_ok", "ask_out", "blink_t", "blink_q"];
for (const clickRate of [0, 0.05, 0.3, 2]) for (let seed = 1; seed <= 5; seed++) {
  const r = lcg(seed), b = new Brain(r), count = {};
  let t = 0, scanning = false, waiting = 0, panel = false, scanEnd = 0, nextScan = 600, stuck = 0;
  const step = (d) => {
    for (let i = 0; i < d; i++) if (r() < clickRate) { if (waiting > 0) panel = true; else b.click(); }
    if (!scanning && t >= nextScan) { scanning = true; scanEnd = t + 20 + r() * 60; }
    if (scanning && t >= scanEnd) {
      scanning = false; nextScan = t + 1800;
      if (r() < 0.3) { waiting += 1 + Math.floor(r() * 3); b.discover(); }
    }
    if (panel && r() < 0.05) { waiting = Math.max(0, waiting - 1); if (waiting === 0 || r() < 0.3) panel = false; }
    b.sync({ scanning, waiting, panel });
  };
  for (let i = 0; i < 100000; i++) {
    const [lo, hi] = HOLD[b.hub];
    const h = lo + r() * (hi - lo); t += h; step(h);
    const hubBefore = b.hub, n = b.next(t);
    if (!n) continue;
    if (GRAPH[n][0] !== hubBefore) fail(`不正な遷移 ${n} at ${hubBefore}`);
    if (n === "idea" && scanning) fail("見回り中に閃いた");
    if (n === "ask_ok" && waiting > 0) fail("提案が残っているのにうなずいた");
    if (n === "ask_in" && waiting === 0) fail("提案がないのに耳を傾けた");
    if ((n === "think_a" || n === "think_b") && !scanning) fail("見回りがないのに考え続けた");
    if (n === "think_in" && !scanning && !b.found) fail("理由なく考え始めた");
    count[n] = (count[n] || 0) + 1; total++;
    const d = meta[n].dur; t += d; step(d); b.done(n, t);
    stuck = b.hub === "T" && !scanning ? stuck + 1 : 0;
    if (stuck > 2) fail("見回りが終わっても考え中から出ない");
  }
  for (const c of Object.keys(count)) reached.add(c);
  if (seed === 1) console.log(`click/s ${clickRate}: 実時間 ${(t / 3600).toFixed(0)}h, 閃き ${count.idea || 0}, うなずき ${count.ask_ok || 0}, 声かけ ${count.ask_in || 0}`);
}
const miss = Object.keys(GRAPH).filter((c) => !reached.has(c) && !Object.values(BLINK).includes(c));
if (miss.length) fail("未到達 " + miss);
for (const n of SIGNAL) if (ACT.F.concat(ACT.B).some(([x]) => x === n)) fail("合図が自発動作に入っている " + n);
console.log(process.exitCode ? "FAILED" : "OK", "遷移数", total);

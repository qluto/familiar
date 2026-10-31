// 状態遷移と行動の選択。描画に依存しないので qa_graph.mjs でそのまま検査できる。
// ハブ: F=正面 B=背面 T=考え中 I=ひらめき（通過点） Q=耳を傾ける
// T / I / Q は familiar の状態を伝える合図なので、自発的には入らない。
(function (g) {
  const GRAPH = {
    blink: ["F", "F"], idle_f: ["F", "F"], look: ["F", "F"], stretch: ["F", "F"],
    turn_away: ["F", "B"], idle_b: ["B", "B"], turn_back: ["B", "F"],
    think_in: ["F", "T"], blink_t: ["T", "T"], think_a: ["T", "T"], think_b: ["T", "T"],
    think_out: ["T", "F"], idea: ["T", "I"], idea_out: ["I", "F"],
    ask_in: ["F", "Q"], idea_ask: ["I", "Q"], blink_q: ["Q", "Q"], ask_wait: ["Q", "Q"],
    ask_ok: ["Q", "F"], ask_out: ["Q", "F"],
  };
  const HOLD = { F: [4, 9], B: [4, 14], T: [0.8, 2.5], I: [0.8, 0.8], Q: [3, 7] }; // 秒
  const BLINK = { F: "blink", T: "blink_t", Q: "blink_q" };
  const ACT = {
    F: [["idle_f", 5], ["look", 3], ["turn_away", 1.5], ["stretch", 1]],
    B: [["idle_b", 4], ["turn_back", 3]],
  };
  const COOL = { idle_f: 12, idle_b: 8, look: 40, stretch: 180, turn_away: 90, turn_back: 15 };
  const WAITS = 12;      // 返事を待つループ回数。1 回あたり約 8 秒で、約 1.5 分待つ
  const REMIND = 20 * 60; // 放置された提案へ声をかけ直す間隔（秒）

  class Brain {
    constructor(rand = Math.random) {
      this.rand = rand; this.hub = "F"; this.pending = false;
      this.last = {}; this.loops = 0; this.prevThink = null;
      this.scanning = false; this.found = false; this.waiting = 0; this.panel = false; this.asked = -1e9;
    }
    click() { this.pending = true; }
    /** familiar の状態を受け取る。クリップの途中でも呼んでよく、次のハブで反映する。 */
    sync({ scanning, waiting, panel }) {
      this.scanning = scanning; this.waiting = waiting; this.panel = panel;
    }
    /** 見回りが新しい提案を見つけた。次に T へ着いたとき閃く。 */
    discover() { this.found = true; }
    /** 今のハブから出られるクリップを選ぶ。合図を優先し、クリックは必ずここで解決する。 */
    next(now) {
      const hub = this.hub;
      if (hub === "I") return this.use(this.waiting > 0 ? "idea_ask" : "idea_out", now);
      if (hub === "Q") return this.use(this.nextAsk(), now);
      if (hub === "T") return this.use(this.nextThink(), now);
      if (hub === "B" && this.needsFront()) { this.pending = false; return this.use("turn_back", now); }
      if (hub === "F") {
        if (this.scanning || this.found) { this.pending = false; return this.use("think_in", now); }
        if (this.waiting > 0 && (this.panel || now - this.asked > REMIND)) { this.pending = false; return this.use("ask_in", now); }
      }
      if (this.pending) { this.pending = false; return this.use(hub === "F" ? "look" : "turn_back", now); }
      const c = ACT[hub].filter(([n]) => now - (this.last[n] ?? -1e9) > COOL[n]);
      if (!c.length) return null;
      let r = this.rand() * c.reduce((s, x) => s + x[1], 0);
      for (const [n, w] of c) if ((r -= w) <= 0) return this.use(n, now);
      return this.use(c[0][0], now);
    }
    needsFront() { return this.scanning || this.found || this.panel || this.waiting > 0; }
    nextThink() {
      this.pending = false; // 考え中のクリックに意味はない。閃きは本当に見つけたときだけ
      if (this.scanning) {
        const n = this.prevThink === "think_a" ? "think_b" : "think_a";
        return (this.prevThink = n);
      }
      if (this.found) { this.found = false; return "idea"; }
      return "think_out";
    }
    nextAsk() {
      this.pending = false;
      this.found = false; // すでに待っている。件数は吹き出しで伝わる
      if (this.waiting === 0) return "ask_ok"; // 全部に返事があった
      if (this.panel) return "ask_wait";
      if (this.loops > 0) { this.loops--; return "ask_wait"; }
      return "ask_out";
    }
    use(n, now) { this.last[n] = now; return n; }
    done(n, now = 0) {
      this.hub = GRAPH[n][1];
      if (n === "ask_in" || n === "idea_ask") { this.loops = WAITS; this.asked = now; }
    }
  }
  g.Brain = { Brain, GRAPH, HOLD, BLINK, ACT, COOL, WAITS, REMIND };
})(globalThis);

// 状態遷移と行動の選択。描画に依存しないので qa_graph.mjs でそのまま検査できる。
// ハブ: F=正面 B=背面 T=考え中 I=ひらめき（通過点） Q=耳を傾ける P=スマホで進める R=返事を問いかける
// T / I / Q / P / R は familiar の状態を伝える合図なので、自発的には入らない。
// P / R のクリップ（PHONE）はパックになくてもよい。ないパックは、頼まれた作業と返事待ちを P / R で見せない。
(function (g) {
  const GRAPH = {
    blink: ["F", "F"], idle_f: ["F", "F"], look: ["F", "F"], stretch: ["F", "F"],
    turn_away: ["F", "B"], idle_b: ["B", "B"], turn_back: ["B", "F"],
    think_in: ["F", "T"], blink_t: ["T", "T"], think_a: ["T", "T"], think_b: ["T", "T"],
    think_out: ["T", "F"], idea: ["T", "I"], idea_out: ["I", "F"],
    ask_in: ["F", "Q"], idea_ask: ["I", "Q"], blink_q: ["Q", "Q"], ask_wait: ["Q", "Q"],
    ask_ok: ["Q", "F"], ask_out: ["Q", "F"],
    nod: ["F", "F"], phone_in: ["F", "P"], phone_a: ["P", "P"], phone_out: ["P", "F"],
    phone_ask: ["P", "R"], blink_r: ["R", "R"], reply_wait: ["R", "R"], reply_got: ["R", "P"], reply_out: ["R", "F"],
  };
  const PHONE = ["nod", "phone_in", "phone_a", "phone_out", "phone_ask", "blink_r", "reply_wait", "reply_got", "reply_out"];
  const HOLD = { F: [4, 9], B: [4, 14], T: [0.8, 2.5], I: [0.8, 0.8], Q: [3, 7], P: [0.3, 1.2], R: [3, 7] }; // 秒
  const BLINK = { F: "blink", T: "blink_t", Q: "blink_q", R: "blink_r" };
  const NODS = ["nod", "ask_ok", "idea_out"]; // うなずきで終わるクリップ。続けてもう一度うなずかない
  // 伸びは時刻で、背中向きは離席で決まるので、ここには入れない
  const ACT = {
    F: [["idle_f", 5], ["look", 3]],
    B: [["idle_b", 1]],
  };
  const COOL = { idle_f: 12, idle_b: 8, look: 40 };
  const WAITS = 12;      // 返事を待つループ回数。1 回あたり約 8 秒で、約 1.5 分待つ
  const REMIND = 20 * 60; // 放置された提案へ声をかけ直す間隔（秒）
  const AWAY = 10 * 60;   // この秒数だけ入力がなければ離席とみなし、背を向ける
  const STRETCH_LATE = 2; // 合図で遅れた伸びを、毎時 25 分と 55 分から何分後まで許すか

  /** 伸びの時間帯なら、その回を表す分単位の時刻を返す。 */
  function stretchSlot(date) {
    const late = date.getMinutes() % 30 - 25;
    return late >= 0 && late < STRETCH_LATE ? Math.floor(date.getTime() / 60000) - late : null;
  }

  class Brain {
    constructor(rand = Math.random) {
      this.rand = rand; this.hub = "F"; this.pending = false;
      this.last = {}; this.loops = 0; this.prevThink = null;
      this.scanning = false; this.found = false; this.waiting = 0; this.panel = false; this.asked = -1e9;
      this.away = false; this.stretched = null;
      this.phone = false; // パックに PHONE のクリップがある
      this.busy = false; this.asking = 0; this.posed = -1e9; this.prev = null;
      this.cue = false; // 待ち時間を切り上げて、すぐ次を選ぶ
    }
    click() { this.pending = true; }
    /** familiar の状態を受け取る。渡した項目だけ変える。クリップの途中でも呼んでよく、次のハブで反映する。 */
    sync({ scanning = this.scanning, waiting = this.waiting, panel = this.panel, asking = this.asking }) {
      this.scanning = scanning; this.waiting = waiting; this.panel = panel; this.asking = asking;
    }
    /** 話しかけや採用を familiar が進めている。頼まれたらすぐ応えるよう、待ち時間を切り上げる。 */
    setBusy(busy) { if (busy !== this.busy) { this.busy = busy; this.cue = this.phone; } }
    /** 見回りが新しい提案を見つけた。次に T へ着いたとき閃く。 */
    discover() { this.found = true; }
    /** 離席の状態を受け取る。戻ったかどうかは呼び出し側が見られるよう返す。 */
    setAway(away) { const back = this.away && !away; this.away = away; return back; }
    /** 今のハブから出られるクリップを選ぶ。合図を優先し、クリックは必ずここで解決する。 */
    next(now, date = new Date()) {
      const hub = this.hub;
      this.cue = false;
      if (hub === "I") return this.use(this.waiting > 0 && !this.onPhone() ? "idea_ask" : "idea_out", now);
      if (hub === "Q") return this.use(this.nextAsk(), now);
      if (hub === "T") return this.use(this.nextThink(), now);
      if (hub === "P") return this.use(this.nextPhone(), now);
      if (hub === "R") return this.use(this.nextReply(), now);
      if (hub === "B" && (!this.away || this.needsFront())) { this.pending = false; return this.use("turn_back", now); }
      if (hub === "F") {
        // 頼まれたら、まずうなずいてからスマホを出す。返事が要るときも、スマホを出して問いかける
        if (this.onPhone() && (this.busy || this.panel || now - this.posed > REMIND)) {
          this.pending = false;
          return this.use(this.busy && !NODS.includes(this.prev) ? "nod" : "phone_in", now);
        }
        if (this.scanning || this.found) { this.pending = false; return this.use("think_in", now); }
        if (this.others() > 0 && (this.panel || now - this.asked > REMIND)) { this.pending = false; return this.use("ask_in", now); }
        if (this.away && !this.needsFront()) { this.pending = false; return this.use("turn_away", now); }
      }
      if (this.pending) { this.pending = false; return this.use(hub === "F" ? "look" : "turn_back", now); }
      const slot = hub === "F" ? stretchSlot(date) : null;
      if (slot !== null && slot !== this.stretched) { this.stretched = slot; return this.use("stretch", now); }
      const c = ACT[hub].filter(([n]) => now - (this.last[n] ?? -1e9) > COOL[n]);
      if (!c.length) return null;
      let r = this.rand() * c.reduce((s, x) => s + x[1], 0);
      for (const [n, w] of c) if ((r -= w) <= 0) return this.use(n, now);
      return this.use(c[0][0], now);
    }
    needsFront() { return this.scanning || this.found || this.panel || this.waiting > 0 || this.onPhone(); }
    /** スマホのポーズで見せる状態か。頼まれた作業中か、質問や計画が返事を待っている */
    onPhone() { return this.phone && (this.busy || this.asking > 0); }
    /** 返事を待つ質問や計画のほかに、判断待ちの提案があるか。質問の件はスマホで問いかける */
    others() { return this.waiting - (this.phone ? this.asking : 0); }
    nextThink() {
      this.pending = false; // 考え中のクリックに意味はない。閃きは本当に見つけたときだけ
      if (this.onPhone()) return "think_out"; // 頼まれた作業は見回りより先に見せる
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
      if (this.phone && this.busy) return "ask_ok"; // 頼まれた。うなずいてからスマホを出す
      if (this.onPhone()) return "ask_out"; // 質問の件はスマホで問いかけ直す
      if (this.waiting === 0) return "ask_ok"; // 全部に返事があった
      if (this.panel) return "ask_wait";
      if (this.loops > 0) { this.loops--; return "ask_wait"; }
      return "ask_out";
    }
    nextPhone() {
      this.pending = false;
      if (this.busy) return "phone_a";
      return this.asking > 0 ? "phone_ask" : "phone_out";
    }
    nextReply() {
      this.pending = false;
      if (this.busy) return "reply_got"; // 返事をもらった。うなずいて続ける
      if (this.asking === 0) return "reply_out";
      if (this.panel) return "reply_wait";
      if (this.loops > 0) { this.loops--; return "reply_wait"; }
      return "reply_out";
    }
    use(n, now) { this.last[n] = now; return n; }
    done(n, now = 0) {
      this.hub = GRAPH[n][1];
      if (!Object.values(BLINK).includes(n)) this.prev = n;
      if (n === "ask_in" || n === "idea_ask") { this.loops = WAITS; this.asked = now; }
      if (n === "phone_ask") { this.loops = WAITS; this.posed = now; }
      // 頼まれた作業や開いた会話での返事待ちは、スマホのポーズに着くまで間を置かない（うなずきやハブの通過のあとも）
      if (this.onPhone() && (this.busy || this.panel) && this.hub !== "P" && this.hub !== "R") this.cue = true;
    }
  }
  g.Brain = { Brain, GRAPH, PHONE, HOLD, BLINK, ACT, COOL, WAITS, REMIND, AWAY, stretchSlot };
})(globalThis);

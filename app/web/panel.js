// キャラクターとの 1 本の会話。出来事は流れに、判断待ちは棚に置く。
// 文面はメールや Slack 由来の信頼できないデータなので、必ず textContent で入れる。
const { core, event } = window.__TAURI__;
const $ = (id) => document.getElementById(id);
const main = $("m"), thread = $("thread"), cards = $("cards"), shelf = $("shelf"), heading = $("h");
const text = $("text"), send = $("send"), chip = $("chip"), mic = $("mic");
const close = () => core.invoke("hide_panel");
$("close").onclick = close;
$("settings").onclick = () => core.invoke("show_settings");
addEventListener("keydown", (e) => { if (e.key === "Escape") close(); });
const familiar = (...args) => core.invoke("familiar", { args });

const REFRESH_MS = 3000;
let lastThread = "", lastCards = "", timer = null, busy = false, opened = false, generation = 0, suggestions = [], proposal = [], past = [];
const unfolded = new Set(); // 開いている畳みと詳細。描き直しても保つ
const logs = new Map(); // 読み終えた見回りの記録。描き直しても読み直さない
const STALE_MS = 11 * 60 * 1000; // 実行の上限を過ぎても進んでいなければ、止まったとみなす
let topic = null; // 話題にしている提案か実行 { id, label }
let voice = { stt: false, realtime: false, tts: false, rate: 24000 }; // 設定で音声のサーバを指定したものだけ使う

const rich = (body) => Markdown.render(body, (url) => core.invoke("open_url", { url }));
function el(tag, props = {}, ...children) {
  const n = document.createElement(tag);
  Object.assign(n, props);
  n.append(...children);
  return n;
}
const atEnd = () => main.scrollHeight - main.scrollTop - main.clientHeight < 40;
const toEnd = () => { main.scrollTop = main.scrollHeight; };
const clock = (at) => new Date(at).toLocaleString("ja-JP", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" });

function setTopic(next) {
  topic = next;
  chip.hidden = !next;
  $("chip-text").textContent = next ? next.label : "";
  draw(true);
  text.focus();
}
$("chip-clear").onclick = () => setTopic(null);

function setBusy(on) {
  busy = on;
  text.disabled = send.disabled = on;
  if (!Speech.recording()) mic.disabled = on;
  document.querySelectorAll("#cards button").forEach((b) => (b.disabled = on));
  if (!on) text.focus();
}

// ── 会話 ─────────────────────────
const isOpen = (s) => s.status === "new" || s.status === "snoozed" || s.status === "accepting";
const hhmm = (at) => new Date(at).toLocaleTimeString("ja-JP", { hour: "2-digit", minute: "2-digit" });
function entry(e, key) {
  if (e.kind === "text") return el("div", { className: "said" }, rich(e.text));
  return fold(key, "entry", e.title, (box) => box.append(el("pre", { textContent: e.text })));
}
// 畳み。中身は開いたときに作り、描き直しても開いたままにする
function fold(key, className, label, fill) {
  const box = el("div");
  const node = el("details", { className, open: unfolded.has(key) }, el("summary", { textContent: label }), box);
  let filled = false;
  const open = () => { if (!filled) { filled = true; fill(box); } };
  node.addEventListener("toggle", () => {
    if (node.open) { unfolded.add(key); open(); } else unfolded.delete(key);
  });
  if (node.open) open(); // 描き直しでは高さを変えないよう、同じ処理の中で中身を入れる
  return node;
}
function scanLine(item) {
  const label = `${clock(item.at)} ${item.text}`;
  if (!item.run) return el("div", { className: "line error", textContent: label });
  const show = (box, entries) => box.append(...entries.map((e, i) => entry(e, `entry:${item.run}:${i}`)), el("div", { className: "actions" },
    el("button", { className: "talk", textContent: "これについて話す", onclick: () => setTopic({ id: item.run, label: `見回りの記録 ${clock(item.at)}` }) })));
  return fold(`scan:${item.run}`, "scan", label, async (box) => {
    if (logs.has(item.run)) return show(box, logs.get(item.run));
    try {
      const entries = JSON.parse(await familiar("log", item.run, "--json"));
      logs.set(item.run, entries);
      show(box, entries);
    } catch (e) { box.append(el("div", { className: "error", textContent: String(e) })); }
  });
}
function heartbeat(run) {
  if (run.length === 1) return scanLine(run[0]);
  const label = `${clock(run[0].at)}–${hhmm(run.at(-1).at)} 見回り ${run.length} 回、異常なし`;
  return fold(`beat:${run[0].at}`, "scan", label, (box) => box.append(...run.map(scanLine)));
}
// 判断待ちのカードに本文があるときは、同じ文を流れに重ねない
function talkLine(item, s) {
  if (s && (s.plan && item.text.endsWith(s.plan) || s.question && item.text === s.question)) {
    const what = s.plan && item.text.endsWith(s.plan) ? "計画を示しました" : "質問しています";
    return el("div", { className: "line quiet", textContent: `「${s.draft.title}」の${what}。判断待ちで読めます` });
  }
  // 自分の言葉は書いたとおりに見せる
  if (item.role === "you") return el("div", { className: "line you", textContent: item.text });
  return el("div", { className: "line" }, rich(item.text));
}
// 渡したあとの様子。見回りが出力先から確かめたものだけを見せる
const progressLabels = { working: "進行中", waiting: "返事待ち", stalled: "停滞", done: "完了" };
function delegated(s) {
  return s.progress ? progressLabels[s.progress.state] ?? "依頼済み" : "依頼済み";
}
function topicRow(s, group) {
  const pairs = group.filter((i) => i.role === "you").length;
  if (!isOpen(s)) {
    const label = `「${s.draft.title}」 ${pairs} 往復 → ${s.status === "accepted" ? delegated(s) : s.status === "handled" ? "自分で済ませた" : "見送り"}`;
    return fold(`topic:${group[0].at}`, "scan", label, (box) => box.append(...group.map((i) => talkLine(i))));
  }
  return el("div", { className: "topic" }, el("h3", { textContent: `「${s.draft.title}」について` }), ...group.map((i) => talkLine(i, s)));
}
// 履歴を、続いている塊ごとの行にする
function rows(items) {
  const known = new Map(suggestions.map((s) => [s.id, s]));
  const out = [];
  for (let i = 0; i < items.length;) {
    const item = items[i];
    const same = item.role === "scan"
      ? (o) => o.role === "scan" && o.found === 0 && item.found === 0
      : (o) => o.role !== "scan" && item.about && o.about === item.about;
    let end = i + 1;
    while (end < items.length && same(items[end])) end++;
    const run = items.slice(i, end);
    const s = known.get(item.about);
    if (item.role === "scan") out.push(heartbeat(run));
    else if (s && run.some((r) => r.role === "you")) out.push(topicRow(s, run));
    else out.push(...run.map((r) => talkLine(r, s && isOpen(s) ? s : undefined)));
    i = end;
  }
  return out;
}

// ── カード ───────────────────────
async function act(args, restore) {
  if (busy) return;
  setBusy(true);
  const started = Date.now();
  const wait = el("div", { className: "line wait", textContent: "考えています…" });
  thread.append(wait);
  toEnd();
  try {
    const out = await familiar(...args);
    wait.remove();
    setBusy(false);
    readAloud((await reload()).items, started);
    return out;
  } catch (e) {
    wait.replaceWith(el("div", { className: "line error", textContent: String(e) }));
    if (restore) text.value = restore;
    setBusy(false);
    await reload().catch(() => {});
  }
}
// 話題にしている提案なら、入力欄の言葉を判断に添える
function taking(s) {
  if (topic?.id !== s.id) return "";
  const words = text.value.trim();
  text.value = "";
  setTopic(null);
  return words;
}
function acts(s) {
  const talk = el("button", { className: "talk", textContent: "話す", onclick: () => setTopic({ id: s.id, label: `「${s.draft.title}」について` }) });
  const dismiss = (name) => el("button", { textContent: name, onclick: () => {
    const words = taking(s);
    act(["dismiss", s.id, ...(words ? [words] : [])]);
  } });
  if (s.status === "accepting") {
    if (Date.now() - Date.parse(s.updatedAt) < STALE_MS) return [el("span", { className: "meta", textContent: "進めています" })];
    return [el("span", { className: "meta", textContent: "止まったようです。途中まで反映されたかもしれません" }),
      el("button", { textContent: "やり直す", onclick: () => act(["accept", s.id, "--force"]) })];
  }
  if (s.plan) return [
    el("button", { className: "go", textContent: "進める", onclick: () => {
      const words = taking(s); // 話していた条件があれば、承認に添える
      act(["accept", s.id, "--approve", ...(words ? ["--note", words] : [])]);
    } }),
    dismiss("やめる"), talk];
  const accept = el("button", { className: "go", textContent: "採用", onclick: () => {
    const words = taking(s);
    act(["accept", s.id, ...(words ? ["--note", words] : [])]);
  } });
  // 委ねるまでもなく自分で終えたもの。添えた言葉は日々のノートに残る
  const handled = el("button", { textContent: "済ませた", onclick: () => {
    const words = taking(s);
    act(["handled", s.id, ...(words ? [words] : [])]);
  } });
  return [accept, handled, dismiss("却下"), talk];
}
function card(s, compact) {
  const d = s.draft;
  const key = `card:${s.id}`;
  const shown = unfolded.has(key);
  const sources = el("div", { className: "src" }, ...d.sources.map((src) => el("div", {},
    src.url.startsWith("https://")
      ? el("button", { className: "link", textContent: `${src.kind} を開く`, onclick: () => core.invoke("open_url", { url: src.url }) })
      : src.kind,
    el("blockquote", { textContent: src.excerpt }))));
  const talked = past.filter((i) => i.about === s.id && i.role !== "scan");
  const more = el("button", { className: "link", textContent: shown ? "閉じる" : "詳しく", onclick: () => {
    if (shown) unfolded.delete(key); else unfolded.add(key);
    draw(true);
  } });
  const actions = el("div", { className: "actions" }, ...acts(s));
  actions.insertBefore(more, actions.querySelector(".talk"));
  return el("article", { className: `${topic?.id === s.id ? "selected" : ""} ${compact && !shown ? "compact" : ""}` },
    el("div", { className: "card-top" }, el("h2", { textContent: d.title }),
      el("span", { className: `meta ${d.urgency === "high" ? "high" : ""}`, textContent: `緊急度 ${d.urgency}` })),
    el("div", { className: "meta" }, `${d.kind} ・ 手間 ${d.effort}`, d.due ? ` ・ 期日 ${d.due}` : "",
      s.snoozedUntil ? ` ・ ${clock(s.snoozedUntil)} にまた声をかけます` : ""),
    ...(shown ? [el("p", { textContent: d.why }), el("p", { className: "details", textContent: d.details }), sources] : []),
    ...(talked.length ? [fold(`talked:${s.id}`, "talked", `話した内容 ${talked.length}`, (box) =>
      box.append(el("div", { className: "said-list" }, ...talked.map((i) => el("div", {}, el("b", { textContent: i.role === "you" ? "あなた" : "familiar" }), rich(i.text))))))] : []),
    ...(s.question ? [el("div", { className: "question" }, rich(s.question))] : []),
    ...(s.plan ? [el("div", { className: "plan" }, rich(s.plan))] : []),
    actions);
}
// 行単位の最長共通部分列
function diff(before, after) {
  const a = before.split("\n"), b = after.split("\n");
  const t = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i--) for (let j = b.length - 1; j >= 0; j--) {
    t[i][j] = a[i] === b[j] ? t[i + 1][j + 1] + 1 : Math.max(t[i + 1][j], t[i][j + 1]);
  }
  const out = [];
  let i = 0, j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) { out.push(["same", a[i]]); i++; j++; }
    else if (j < b.length && (i === a.length || t[i][j + 1] >= t[i + 1][j])) out.push(["add", b[j++]]);
    else out.push(["del", a[i++]]);
  }
  return out;
}
function changeCard(changes) {
  return el("article", {},
    el("h2", { textContent: "指示の変更案" }),
    ...changes.flatMap((c) => [el("h3", { textContent: c.file }),
      ...diff(c.before, c.after).map(([kind, line]) =>
        el("div", { className: `diff ${kind}`, textContent: line || " " }))]),
    el("div", { className: "actions" },
      el("button", { className: "go", textContent: "反映", onclick: () => act(["apply"]) }),
      el("button", { textContent: "取り消す", onclick: () => act(["discard"]) })));
}
function draw(force) {
  const key = JSON.stringify([suggestions.map((s) => [s.id, s.status, s.updatedAt, s.draft.title, s.plan, s.question]), proposal, topic?.id ?? null, past.length]);
  if (!force && key === lastCards) return false;
  lastCards = key;
  const fresh = suggestions.filter((s) => s.status === "new");
  const waiting = [...fresh, ...suggestions.filter((s) => s.status === "accepting")];
  const shown = [...waiting.map((s, i) => card(s, i > 0 && waiting.length >= 3)), ...(proposal.length ? [changeCard(proposal)] : [])];
  cards.replaceChildren(...shown);
  shelf.hidden = !shown.length;
  $("shelf-title").textContent = `判断待ち ${shown.length} 件`;
  // 計画や差分を読むときは、狭い枠に閉じ込めない
  shelf.classList.toggle("reading", proposal.length > 0 || waiting.some((s) => s.plan || s.question || unfolded.has(`card:${s.id}`)));
  if (busy) setBusy(true);
  heading.textContent = fresh.length ? `気になることが ${fresh.length} 件あります` : "familiar";
  return true;
}

async function reload() {
  const mine = ++generation;
  const state = JSON.parse(await familiar("thread", "--json"));
  const items = JSON.parse(await familiar("list", "--all", "--json"));
  if (mine !== generation) return state; // あとから始めた読み込みの方が新しい
  const follow = atEnd();
  suggestions = items;
  proposal = state.proposal;
  past = state.items;
  // 終わった提案を話題のままにしない
  const current = suggestions.find((s) => s.id === topic?.id);
  if (current && !isOpen(current)) { topic = null; chip.hidden = true; }
  // 出力のキーの順番に左右されないよう、項目を並べて比べる
  const key = JSON.stringify([state.items.map((i) => [i.at, i.role, i.text, i.run, i.about, i.found]),
    suggestions.map((s) => [s.id, s.status, s.plan, s.question, s.draft.title])]);
  const moved = key !== lastThread;
  if (moved) { lastThread = key; thread.replaceChildren(...rows(state.items)); }
  const changed = draw(false);
  if (follow && (moved || changed)) toEnd();
  return state;
}

$("f").addEventListener("submit", async (e) => {
  e.preventDefault();
  const words = text.value.trim();
  if (!words || busy || Speech.recording()) return;
  text.value = "";
  Speech.quiet();
  const about = topic;
  const s = suggestions.find((x) => x.id === about?.id);
  thread.append(el("div", { className: "line you wait", textContent: words }));
  toEnd();
  // 質問や計画への返事は、そのまま採用の続きになる
  const args = s && (s.question || s.plan) ? ["accept", s.id, "--note", words]
    : ["say", "--text", words, ...(about ? ["--about", about.id] : [])];
  thread.lastChild.dataset.pending = "1";
  await act(args, words);
  thread.querySelectorAll("[data-pending]").forEach((n) => n.remove());
});
// 変換の確定の Enter では送らない
text.addEventListener("keydown", (e) => { if (e.key === "Enter" && e.isComposing) e.preventDefault(); });

// ── 声 ─────────────────────────
// この操作のあとに届いた familiar の言葉を読み上げる。Markdown は記号を読まないよう、見た目の文字にする
function readAloud(items, since) {
  if (!voice.tts) return;
  const said = items.filter((i) => i.role === "familiar" && Date.parse(i.at) >= since - 1000)
    .map((i) => [...rich(i.text).children].map((block) => block.textContent).join("\n")).join("\n\n");
  if (said) Speech.say(said).catch(showError);
}
// 聞いている間、声の大きさをボタンに映す。急に下がらないよう、下がるときはゆっくり
let meter = 0;
function showLevel(shown = 0) {
  if (!Speech.recording()) return mic.style.setProperty("--level", 0);
  shown = Math.max(Speech.level(), shown * 0.85);
  mic.style.setProperty("--level", shown.toFixed(3));
  meter = requestAnimationFrame(() => showLevel(shown));
}
function micLabel(label) { mic.setAttribute("aria-label", label); mic.title = label; }
function micIdle() {
  cancelAnimationFrame(meter);
  mic.style.setProperty("--level", 0);
  mic.classList.remove("on", "wait");
  micLabel("声で話す");
  mic.disabled = busy;
  text.readOnly = false;
  text.placeholder = "話しかける";
}
// 聞き取った言葉は入力欄の続きに入れる。直してから送れる
let typed = "";
const heardText = (heard) => { text.value = [typed, heard].filter(Boolean).join(" "); text.scrollLeft = text.scrollWidth; };
mic.onclick = async () => {
  if (!Speech.recording()) {
    typed = text.value.trim();
    mic.disabled = true;
    try { await Speech.listen({ realtime: voice.realtime, rate: voice.rate, onText: heardText }); }
    catch (e) { micIdle(); return showError(e.name === "NotAllowedError" ? "マイクを使う許可がありません。システム設定のプライバシーとセキュリティで許可してください" : String(e.message ?? e)); }
    mic.disabled = false;
    mic.classList.add("on");
    micLabel("止める");
    showLevel();
    text.readOnly = true; // 話している間に打った字を、途中の文で消さない
    text.placeholder = "聞いています…";
    return;
  }
  cancelAnimationFrame(meter);
  mic.style.setProperty("--level", 0);
  mic.classList.replace("on", "wait");
  mic.disabled = true;
  micLabel("文字にしています");
  try { heardText(await Speech.finish()); }
  catch (e) { text.value = typed; showError(e); }
  micIdle();
  text.focus();
};

function showError(e) { thread.append(el("div", { className: "line error", textContent: String(e) })); }

// 入れ替えを待っている新しい版。ボタンで今すぐ再起動する
function showUpdate(version) {
  if (!version) return;
  $("update-text").textContent = `新しいバージョン ${version} が届きました`;
  $("update").hidden = false;
}
$("update-now").onclick = async () => {
  const button = $("update-now");
  button.disabled = true;
  button.textContent = "入れ替えています…";
  try { await core.invoke("restart_now"); }
  catch (e) { button.disabled = false; button.textContent = "今すぐ入れ替える"; showError(e); }
};
event.listen("update-ready", ({ payload }) => showUpdate(payload));

event.listen("panel-open", async () => {
  opened = true;
  voice = await core.invoke("voice");
  mic.hidden = !voice.stt;
  document.body.classList.toggle("notch", (await core.invoke("display")).mode === "notch");
  showUpdate(await core.invoke("update_ready"));
  await core.invoke("fill_panel");
  try {
    const state = await reload();
    toEnd();
    if (state.onboarding && !state.items.some((i) => i.role !== "scan")) await act(["say", "--start"]);
  } catch (e) { showError(e); }
  clearInterval(timer);
  if (!opened) return; // 待っている間に閉じられた
  timer = setInterval(() => { if (!busy) reload().catch(() => {}); }, REFRESH_MS);
  text.focus();
});
event.listen("panel-closed", () => {
  opened = false;
  clearInterval(timer);
  Speech.cancel();
  Speech.quiet();
  micIdle();
});

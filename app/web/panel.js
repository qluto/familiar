// キャラクターとの 1 本の会話。見回りの結果も提案も計画も、ここに並ぶ。
// 文面はメールや Slack 由来の信頼できないデータなので、必ず textContent で入れる。
const { core, event } = window.__TAURI__;
const $ = (id) => document.getElementById(id);
const main = $("m"), thread = $("thread"), cards = $("cards"), heading = $("h");
const text = $("text"), send = $("send"), chip = $("chip");
const close = () => core.invoke("hide_panel");
$("close").onclick = close;
$("settings").onclick = () => core.invoke("show_settings");
addEventListener("keydown", (e) => { if (e.key === "Escape") close(); });
const familiar = (...args) => core.invoke("familiar", { args });

const REFRESH_MS = 3000;
let lastItem = null, lastCards = "", timer = null, busy = false, opened = false, generation = 0, suggestions = [], proposal = [];
const STALE_MS = 11 * 60 * 1000; // 実行の上限を過ぎても進んでいなければ、止まったとみなす
let topic = null; // 話題にしている提案か実行 { id, label }

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
  document.querySelectorAll("#cards button").forEach((b) => (b.disabled = on));
  if (!on) text.focus();
}

// ── 会話 ─────────────────────────
function entry(e) {
  if (e.kind === "text") return el("div", { className: "said", textContent: e.text });
  return el("details", { className: "entry", open: e.kind === "final" || e.kind === "error" },
    el("summary", { textContent: e.title }), el("pre", { textContent: e.text }));
}
// 見回りは 1 行に畳み、開いたときだけ記録を読む
function scanLine(item) {
  const label = `${clock(item.at)} ${item.text}`;
  if (!item.run) return el("div", { className: "line error", textContent: label });
  const box = el("div");
  const node = el("details", { className: "scan" }, el("summary", { textContent: label }), box);
  node.addEventListener("toggle", async () => {
    if (!node.open || box.childElementCount) return;
    try {
      const entries = JSON.parse(await familiar("log", item.run, "--json"));
      box.append(...entries.map(entry), el("div", { className: "actions" },
        el("button", { className: "talk", textContent: "これについて話す", onclick: () => setTopic({ id: item.run, label: `見回りの記録 ${clock(item.at)}` }) })));
    } catch (e) { box.append(el("div", { className: "error", textContent: String(e) })); }
  });
  return node;
}
const lineOf = (item) => item.role === "scan" ? scanLine(item)
  : el("div", { className: `line ${item.role === "you" ? "you" : ""}`, textContent: item.text });

// ── カード ───────────────────────
async function act(args, restore) {
  if (busy) return;
  setBusy(true);
  const wait = el("div", { className: "line wait", textContent: "考えています…" });
  thread.append(wait);
  toEnd();
  try {
    const out = await familiar(...args);
    wait.remove();
    setBusy(false);
    await reload();
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
  const snooze = el("button", { textContent: "後で", onclick: () => act(["snooze", s.id]) });
  return [accept, snooze, dismiss("却下"), talk];
}
function card(s) {
  const d = s.draft;
  const sources = el("div", { className: "src" }, ...d.sources.map((src) => el("div", {},
    src.url.startsWith("https://")
      ? el("button", { className: "link", textContent: `${src.kind} を開く`, onclick: () => core.invoke("open_url", { url: src.url }) })
      : src.kind,
    el("blockquote", { textContent: src.excerpt }))));
  return el("article", { className: topic?.id === s.id ? "selected" : "" },
    el("h2", { textContent: d.title }),
    el("div", { className: "meta" },
      el("span", { className: d.urgency === "high" ? "high" : "", textContent: `緊急度 ${d.urgency}` }),
      ` ・ ${d.kind} ・ 手間 ${d.effort}`,
      d.due ? ` ・ 期日 ${d.due}` : "",
      s.snoozedUntil ? ` ・ ${clock(s.snoozedUntil)} にまた声をかけます` : ""),
    el("p", { textContent: d.why }),
    el("p", { className: "details", textContent: d.details }),
    sources,
    ...(s.question ? [el("p", { className: "question", textContent: s.question })] : []),
    ...(s.plan ? [el("p", { className: "plan", textContent: s.plan })] : []),
    el("div", { className: "actions" }, ...acts(s)));
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
  const key = JSON.stringify([suggestions, proposal, topic?.id ?? null]);
  if (!force && key === lastCards) return false;
  lastCards = key;
  const fresh = suggestions.filter((s) => s.status === "new");
  const later = suggestions.filter((s) => s.status === "snoozed" || s.status === "accepting");
  cards.replaceChildren(...fresh.map(card), ...later.map(card), ...(proposal.length ? [changeCard(proposal)] : []));
  if (busy) setBusy(true);
  heading.textContent = fresh.length ? `気になることが ${fresh.length} 件あります` : "familiar";
  return true;
}

const itemKey = (item) => `${item.at}|${item.role}|${item.text}`;
async function reload() {
  const mine = ++generation;
  const state = JSON.parse(await familiar("thread", "--json"));
  const items = JSON.parse(await familiar("list", "--all", "--json"));
  if (mine !== generation) return state; // あとから始めた読み込みの方が新しい
  const follow = atEnd();
  // 履歴は末尾の窓で届くので、件数ではなく最後に描いた行を手がかりにする
  const from = lastItem === null ? -1 : state.items.findLastIndex((i) => itemKey(i) === lastItem);
  if (from < 0) thread.replaceChildren();
  const added = state.items.slice(from + 1);
  thread.append(...added.map(lineOf));
  if (state.items.length) lastItem = itemKey(state.items.at(-1));
  suggestions = items;
  proposal = state.proposal;
  const changed = draw(false);
  if (follow && (added.length || changed)) toEnd();
  return state;
}

$("f").addEventListener("submit", async (e) => {
  e.preventDefault();
  const words = text.value.trim();
  if (!words || busy) return;
  text.value = "";
  const about = topic;
  const s = suggestions.find((x) => x.id === about?.id);
  thread.append(el("div", { className: "line you wait", textContent: words }));
  toEnd();
  // 質問や計画への返事は、そのまま採用の続きになる
  const args = s && (s.question || s.plan) ? ["accept", s.id, "--note", words]
    : ["say", "--text", words, ...(about ? ["--about", about.id] : [])];
  thread.lastChild.dataset.pending = "1";
  const out = await act(args, words);
  thread.querySelectorAll("[data-pending]").forEach((n) => n.remove());
  if (out !== undefined && about) setTopic(null);
});
// 変換の確定の Enter では送らない
text.addEventListener("keydown", (e) => { if (e.key === "Enter" && e.isComposing) e.preventDefault(); });

function showError(e) { thread.append(el("div", { className: "line error", textContent: String(e) })); }

event.listen("panel-open", async () => {
  opened = true;
  document.body.classList.toggle("notch", (await core.invoke("display")).mode === "notch");
  await core.invoke("fit_panel", { height: Math.min(640, screen.availHeight - 60) });
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
event.listen("panel-closed", () => { opened = false; clearInterval(timer); });

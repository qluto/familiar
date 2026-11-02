// 実行の記録を読みながら AI と話す。記録も AI の言葉も外部の内容を含むので textContent でのみ入れる。
const { core, event } = window.__TAURI__;
const $ = (id) => document.getElementById(id);
const entries = $("entries"), chat = $("chat"), select = $("runs"), text = $("text"), send = $("send");
const familiar = (...args) => core.invoke("familiar", { args });
const close = () => core.invoke("hide_settings");
$("close").onclick = close;
addEventListener("keydown", (e) => { if (e.key === "Escape") close(); });

const REFRESH_MS = 2000;
let list = [], timer = null, shown = 0;

function el(tag, props = {}, ...children) {
  const n = document.createElement(tag);
  Object.assign(n, props);
  n.append(...children);
  return n;
}
const atEnd = (n) => n.scrollHeight - n.scrollTop - n.clientHeight < 24;

function entry(e) {
  if (e.kind === "text") return el("div", { className: "text", textContent: e.text });
  return el("details", { className: e.kind === "error" ? "err" : e.kind, open: e.kind === "final" || e.kind === "error" },
    el("summary", { textContent: e.title }), el("pre", { textContent: e.text }));
}

async function showEntries(reset) {
  const id = select.value;
  if (!id) return;
  const all = JSON.parse(await familiar("log", id, "--json"));
  if (id !== select.value) return; // 読んでいる間に別の記録へ移った
  const follow = atEnd(entries);
  if (reset) { entries.replaceChildren(); shown = 0; }
  entries.append(...all.slice(shown).map(entry)); // 開いた詳細を閉じないよう、増えた分だけ足す
  shown = all.length;
  if (reset || follow) entries.scrollTop = entries.scrollHeight;
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

function showState(state) {
  chat.replaceChildren(...state.lines.map((l) =>
    el("div", { className: `line ${l.role === "familiar" ? "" : "you"}`, textContent: l.text })));
  chat.scrollTop = chat.scrollHeight;
  $("proposal").hidden = !state.proposal.length;
  $("diffs").replaceChildren(...state.proposal.flatMap((c) => [
    el("h3", { textContent: c.file }),
    ...diff(c.before, c.after).map(([kind, line]) => el("div", { className: `diff ${kind}`, textContent: line || " " })),
  ]));
}

function busy(on) {
  text.disabled = send.disabled = $("apply").disabled = $("discard").disabled = on;
  if (!on) text.focus();
}
async function act(args, restore) {
  busy(true);
  const wait = el("div", { className: "line wait", textContent: "考えています…" });
  chat.append(wait);
  chat.scrollTop = chat.scrollHeight;
  try {
    showState(JSON.parse(await familiar("review", ...args)));
  } catch (e) {
    wait.remove();
    chat.append(el("div", { className: "line error", textContent: String(e) }));
    chat.scrollTop = chat.scrollHeight;
    if (restore) text.value = restore;
  }
  busy(false);
}

async function pick() {
  await showEntries(true);
  if (select.value) showState(JSON.parse(await familiar("review", "log", select.value)));
}
const label = (r) => `${new Date(r.started).toLocaleString("ja-JP", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" })}  ${r.label} ${r.model ?? ""}  ${{ running: "実行中", done: "", failed: "失敗", stopped: "中断" }[r.status]}${r.costUsd ? `  $${r.costUsd.toFixed(3)}` : ""}`;

async function loadRuns() {
  list = JSON.parse(await familiar("runs", "--json"));
  const keep = select.value;
  select.replaceChildren(...list.map((r) => el("option", { value: r.id, textContent: label(r) })));
  if (list.some((r) => r.id === keep)) select.value = keep;
}
async function refresh() {
  if (document.hidden) return;
  await loadRuns();
  if (list.find((r) => r.id === select.value)?.status === "running") await showEntries(false);
}

select.onchange = () => pick().catch((e) => chat.replaceChildren(el("div", { className: "line error", textContent: String(e) })));
$("f").addEventListener("submit", (e) => {
  e.preventDefault();
  const words = text.value.trim();
  if (!words || send.disabled || !select.value) return;
  text.value = "";
  chat.append(el("div", { className: "line you", textContent: words }));
  act(["say", select.value, words], words);
});
text.addEventListener("keydown", (e) => { if (e.key === "Enter" && e.isComposing) e.preventDefault(); });
$("apply").onclick = () => act(["apply", select.value]);
$("discard").onclick = () => act(["discard", select.value]);

event.listen("review-open", async () => {
  document.body.classList.toggle("notch", (await core.invoke("display")).mode === "notch");
  await core.invoke("fit_panel", { height: Math.min(720, screen.availHeight - 60), width: 680 });
  try {
    await loadRuns();
    if (!list.length) entries.replaceChildren(el("div", { className: "text", textContent: "まだ記録がありません。次の見回りから残ります" }));
    await pick();
  } catch (e) { entries.replaceChildren(el("div", { className: "line error", textContent: String(e) })); }
  clearInterval(timer);
  timer = setInterval(() => refresh().catch(() => {}), REFRESH_MS);
  text.focus();
});

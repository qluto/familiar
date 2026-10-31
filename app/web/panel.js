// 提案を載せる大きな吹き出し。文面はメールや Slack 由来の信頼できないデータなので、必ず textContent で入れる。
const { core, event } = window.__TAURI__;
const main = document.getElementById("m");
const heading = document.getElementById("h");
const close = () => core.invoke("hide_panel");
document.getElementById("close").onclick = close;
addEventListener("keydown", (e) => { if (e.key === "Escape") close(); });
const steward = (...args) => core.invoke("steward", { args });

function el(tag, props = {}, ...children) {
  const n = document.createElement(tag);
  Object.assign(n, props);
  n.append(...children);
  return n;
}
function field(label, value, attrs = {}, tag = "input") {
  const input = el(tag, { value: value ?? "", ...attrs });
  return [el("label", {}, label, input), input];
}

// 入力欄は内容に合わせて伸ばし、吹き出しもそれに合わせる
function grow(area) {
  area.style.height = "auto";
  area.style.height = `${area.scrollHeight}px`;
}

function card(s) {
  const d = s.draft, l = d.linear_draft;
  const note = el("div", { className: "note" });
  const [titleField, title] = field("タイトル", l.title);
  const [teamField, team] = field("チーム（空なら既定）", l.team);
  const [dueField, due] = field("期日", l.due, { type: "date" });
  const [bodyField, body] = field("本文", l.description, {}, "textarea");
  body.addEventListener("input", () => { grow(body); fit(); });
  const [reasonField, reason] = field("却下の理由（任意）", "");

  const buttons = [];
  const act = async (args, after) => {
    buttons.forEach((b) => (b.disabled = true));
    note.textContent = "";
    try {
      after(await steward(...args));
    } catch (e) {
      note.textContent = String(e);
      buttons.forEach((b) => (b.disabled = false));
    }
  };
  const remove = () => { reload().catch(showError); };
  const accept = el("button", { className: "go", textContent: "採用" });
  accept.onclick = () => {
    const args = ["accept", s.id];
    if (title.value.trim() !== l.title) args.push("--title", title.value.trim());
    if (team.value.trim()) args.push("--team", team.value.trim());
    if (due.value) args.push("--due", due.value);
    if (body.value.trim() && body.value !== l.description) args.push("--description", body.value);
    accept.textContent = "作成中…";
    act(args, remove).finally(() => (accept.textContent = "採用"));
  };
  const snooze = el("button", { textContent: "後で", onclick: () => act(["snooze", s.id], remove) });
  const dismiss = el("button", {
    textContent: "却下",
    onclick: () => act(["dismiss", s.id, ...(reason.value.trim() ? [reason.value.trim()] : [])], remove),
  });
  buttons.push(accept, snooze, dismiss);

  const sources = el("div", { className: "src" }, ...d.sources.map((src) => el("div", {},
    el("button", { textContent: `${src.kind} を開く`, onclick: () => core.invoke("open_url", { url: src.url }) }),
    el("blockquote", { textContent: src.excerpt }))));
  const draft = el("details", {}, el("summary", { textContent: "Linear の下書きを直す" }),
    el("div", { className: "form" }, titleField, bodyField, el("div", { className: "two" }, teamField, dueField), reasonField));
  draft.addEventListener("toggle", async () => {
    if (draft.open) grow(body); // 閉じている間は高さを測れない
    await fit();
    if (draft.open) draft.scrollIntoView({ block: "nearest" });
  });
  const node = el("article", {},
    el("h2", { textContent: d.title }),
    el("div", { className: "meta" },
      el("span", { className: d.urgency === "high" ? "high" : "", textContent: `緊急度 ${d.urgency}` }),
      ` ・ ${d.kind} ・ 手間 ${d.effort}`,
      s.snoozedUntil ? ` ・ ${new Date(s.snoozedUntil).toLocaleString("ja-JP", { month: "numeric", day: "numeric", hour: "numeric", minute: "2-digit" })} にまた声をかけます` : ""),
    el("p", { textContent: d.why }),
    sources,
    draft,
    el("div", { className: "actions" }, accept, snooze, dismiss),
    note);
  return node;
}

// 窓は透明なので、内容の高さに合わせる。余った透明部分がクリックを奪わないように。
// 入り切らないときは main だけがスクロールし、見出しと閉じるボタンは残る
function fit() {
  const wanted = document.querySelector("header").offsetHeight + main.scrollHeight + 4;
  return core.invoke("fit_panel", { height: Math.min(wanted, screen.availHeight - 60) });
}
function showError(e) {
  main.replaceChildren(el("div", { className: "error", textContent: String(e) }));
  return fit();
}

async function reload() {
  const live = JSON.parse(await core.invoke("live"));
  const items = JSON.parse(await steward("list", "--all", "--json"));
  const fresh = items.filter((s) => s.status === "new");
  const held = items.filter((s) => s.status === "snoozed");
  heading.textContent = fresh.length ? `気になることが ${fresh.length} 件あります`
    : held.length ? `後回しの件が ${held.length} 件残っています` : "";
  const nodes = [];
  if (live.lastError) nodes.push(el("div", { className: "error", textContent: `見回りがうまくいきませんでした\n${live.lastError}` }));
  nodes.push(...fresh.map(card));
  if (held.length) nodes.push(el("h3", { textContent: "後回しにしたもの" }), ...held.map(card));
  if (!nodes.length) {
    nodes.push(el("div", { className: "empty", textContent: "全部片付きました" }));
    setTimeout(close, 900);
  }
  main.replaceChildren(...nodes);
  return fit();
}

let qa = "";
core.invoke("qa_flags").then((f) => (qa = f));
event.listen("panel-open", () => reload().then(() => {
  if (qa.includes("paneldraft")) document.querySelector("details").open = true; // 実機で下書きを開く計測用
}).catch(showError));

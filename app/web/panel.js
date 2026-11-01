// 提案を載せる大きな吹き出し。文面はメールや Slack 由来の信頼できないデータなので、必ず textContent で入れる。
const { core, event } = window.__TAURI__;
const main = document.getElementById("m");
const heading = document.getElementById("h");
const close = () => core.invoke("hide_panel");
document.getElementById("close").onclick = close;
document.getElementById("settings").onclick = () => core.invoke("show_settings");
addEventListener("keydown", (e) => { if (e.key === "Escape") close(); });
const familiar = (...args) => core.invoke("familiar", { args });

function el(tag, props = {}, ...children) {
  const n = document.createElement(tag);
  Object.assign(n, props);
  n.append(...children);
  return n;
}
function card(s) {
  const d = s.draft;
  const note = el("div", { className: "note" });
  const instruction = el("input", {
    placeholder: s.question ? "返事を書いて「採用」" : "AI への指示（任意）例: 金曜までにして",
    ariaLabel: "AI への指示",
  });
  const buttons = [];
  const act = async (args, after) => {
    buttons.forEach((b) => (b.disabled = true));
    note.textContent = "";
    try {
      after(await familiar(...args));
    } catch (e) {
      note.textContent = String(e);
      buttons.forEach((b) => (b.disabled = false));
    }
  };
  const remove = () => { reload().catch(showError); };
  const text = () => instruction.value.trim();
  const accept = el("button", { className: "go", textContent: "採用" });
  accept.onclick = () => {
    accept.textContent = "お願いしています…";
    act(["accept", s.id, ...(text() ? ["--note", text()] : [])], remove).finally(() => (accept.textContent = "採用"));
  };
  const snooze = el("button", { textContent: "後で", onclick: () => act(["snooze", s.id], remove) });
  const dismiss = el("button", { textContent: "却下", onclick: () => act(["dismiss", s.id, ...(text() ? [text()] : [])], remove) });
  buttons.push(accept, snooze, dismiss);

  const sources = el("div", { className: "src" }, ...d.sources.map((src) => el("div", {},
    el("button", { textContent: `${src.kind} を開く`, onclick: () => core.invoke("open_url", { url: src.url }) }),
    el("blockquote", { textContent: src.excerpt }))));
  return el("article", {},
    el("h2", { textContent: d.title }),
    el("div", { className: "meta" },
      el("span", { className: d.urgency === "high" ? "high" : "", textContent: `緊急度 ${d.urgency}` }),
      ` ・ ${d.kind} ・ 手間 ${d.effort}`,
      d.due ? ` ・ 期日 ${d.due}` : "",
      s.snoozedUntil ? ` ・ ${new Date(s.snoozedUntil).toLocaleString("ja-JP", { month: "numeric", day: "numeric", hour: "numeric", minute: "2-digit" })} にまた声をかけます` : ""),
    el("p", { textContent: d.why }),
    el("p", { className: "details", textContent: d.details }),
    sources,
    ...(s.question ? [el("p", { className: "question", textContent: s.question })] : []),
    instruction,
    el("div", { className: "actions" }, accept, snooze, dismiss),
    note);
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
  const items = JSON.parse(await familiar("list", "--all", "--json"));
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

const syncDisplay = async () => document.body.classList.toggle("notch", (await core.invoke("display")).mode === "notch");
event.listen("panel-open", () => syncDisplay().then(reload).catch(showError));

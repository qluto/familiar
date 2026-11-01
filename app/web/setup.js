// AI との対話で指示と記憶を整える。AI の言葉は外部の内容を含みうるので textContent で入れる。
const { core, event } = window.__TAURI__;
const log = document.getElementById("log"), form = document.getElementById("f"), text = document.getElementById("text");
const send = document.getElementById("send"), again = document.getElementById("again"), main = document.getElementById("m");
const familiar = (...args) => core.invoke("familiar", { args });
const close = () => core.invoke("hide_settings");
document.getElementById("close").onclick = close;
addEventListener("keydown", (e) => { if (e.key === "Escape") close(); });

function add(line, className = "") {
  const node = document.createElement("div");
  node.className = `line ${className}`;
  node.textContent = line;
  log.append(node);
  log.scrollTop = log.scrollHeight;
  return node;
}
function busy(on) { text.disabled = send.disabled = again.disabled = on; if (!on) text.focus(); }

async function turn(words) {
  busy(true);
  const wait = add("考えています…", "wait");
  try {
    const reply = JSON.parse(await familiar("setup", "say", ...(words === null ? [] : [words])));
    wait.remove();
    add(reply.message);
    busy(false);
    if (reply.done) { add("保存しました", "wait"); text.disabled = send.disabled = true; }
  } catch (e) {
    wait.remove();
    add(String(e), "error");
    busy(false);
    if (words !== null) text.value = words; // 失敗した言葉は残っていないので、そのまま再送できるようにする
  }
}
form.addEventListener("submit", (e) => {
  e.preventDefault();
  const words = text.value.trim();
  if (!words || send.disabled) return;
  text.value = "";
  add(words, "you");
  turn(words);
});
// 変換の確定の Enter では送らない
text.addEventListener("keydown", (e) => { if (e.key === "Enter" && e.isComposing) e.preventDefault(); });

async function open() {
  log.replaceChildren();
  document.body.classList.toggle("notch", (await core.invoke("display")).mode === "notch");
  await core.invoke("fit_panel", { height: document.querySelector("header").offsetHeight + main.scrollHeight + 4 });
  const lines = JSON.parse(await familiar("setup", "log"));
  lines.forEach((l) => add(l.text, l.role === "familiar" ? "" : "you"));
  if (lines.length) busy(false); else turn(null);
}
again.onclick = async () => { await familiar("setup", "reset"); open(); };
event.listen("setup-open", open);

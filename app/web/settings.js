// 設定画面。項目ごとに section を足していく。保存先はアプリの state の config.json。
const { core, event } = window.__TAURI__;
const DEFAULT_KEYS = "Control+Alt+Space";
const HELP = "押すとキャラクターが応えます。もう一度押すと待機に戻ります";
const record = document.getElementById("record"), reset = document.getElementById("reset"), note = document.getElementById("note");
const main = document.getElementById("m");
let keys = "", recording = false;
const close = () => core.invoke("hide_settings");
document.getElementById("close").onclick = close;

function show(status, error) {
  keys = status.keys;
  record.textContent = hotkeyLabel(keys);
  note.textContent = error ?? (status.active ? HELP : "このキーを登録できませんでした。別のキーを選んでください");
  note.classList.toggle("error", !!error || !status.active);
}
const refresh = async (error) => show(await core.invoke("hotkey"), error);

function stop() {
  recording = false;
  record.classList.remove("on");
}
async function cancel() {
  if (!recording) return;
  stop();
  await core.invoke("hotkey_recording", { on: false });
  await refresh();
}
async function save(next) {
  stop();
  try { show(await core.invoke("set_hotkey", { keys: next })); }
  catch (e) { await refresh(String(e)); }
}
record.onclick = async () => {
  if (recording) return cancel();
  recording = true;
  record.classList.add("on");
  record.textContent = "キーを押してください";
  note.textContent = "Esc で取り消します";
  note.classList.remove("error");
  await core.invoke("hotkey_recording", { on: true });
};
reset.onclick = async () => {
  await cancel();
  await save(DEFAULT_KEYS);
};
addEventListener("keydown", (e) => {
  if (!recording) { if (e.key === "Escape") close(); return; }
  e.preventDefault();
  if (e.key === "Escape") return void cancel();
  if (["Control", "Alt", "Shift", "Meta"].includes(e.key)) return; // 修飾キーだけではまだ確定しない
  const mods = [e.ctrlKey && "Control", e.altKey && "Alt", e.shiftKey && "Shift", e.metaKey && "Command"].filter(Boolean);
  save([...mods, e.code].join("+"));
});
addEventListener("blur", cancel);
const modeButtons = { character: document.getElementById("character"), notch: document.getElementById("notch") };
const displayNote = document.getElementById("display-note");
function showDisplay({ mode, hasNotch }) {
  for (const [name, button] of Object.entries(modeButtons)) button.classList.toggle("selected", name === mode);
  modeButtons.notch.disabled = !hasNotch;
  displayNote.textContent = hasNotch ? "ノッチでは、提案の件数を画面上部に出します" : "ノッチのある画面がないので、キャラクターで知らせます";
  document.body.classList.toggle("notch", mode === "notch");
}
for (const [name, button] of Object.entries(modeButtons)) {
  button.onclick = async () => { showDisplay(await core.invoke("set_display", { mode: name })); await core.invoke("hide_settings"); };
}
document.getElementById("setup").onclick = () => core.invoke("show_setup");
document.getElementById("workspace").onclick = () => core.invoke("open_workspace");
const fit = () => core.invoke("fit_panel", { height: document.querySelector("header").offsetHeight + main.scrollHeight + 4 });
event.listen("hotkey-changed", ({ payload }) => { if (!recording) show(payload); });
event.listen("settings-open", () => Promise.all([refresh(), core.invoke("display").then(showDisplay)]).then(fit));

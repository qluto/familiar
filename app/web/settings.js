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
  if (!recording) { if (e.key === "Escape") { document.activeElement?.blur(); close(); } return; }
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
document.getElementById("workspace").onclick = () => core.invoke("open_workspace");
// 音声のサーバ。欄を離れたら保存する
const ttsTry = document.getElementById("tts-try");
const sttModes = { file: document.getElementById("stt-file"), live: document.getElementById("stt-live") };
const ttsModes = { on: document.getElementById("tts-on"), off: document.getElementById("tts-off") };
let realtime = false, speak = true;
const voiceNotes = {
  get stt() {
    return realtime ? "話している間も文字にします。Realtime API（/v1/realtime）に対応したサーバで使えます"
      : "マイクのボタンを押して話し、もう一度押すとまとめて文字にし、入力欄に入れます";
  },
  get tts() { return speak ? "会話の返事を読み上げます" : "返事は読み上げません。「試す」で声だけ確かめられます"; },
};
function voiceNote(kind, text, error) {
  const note = document.getElementById(`${kind}-note`);
  note.textContent = text ?? voiceNotes[kind];
  note.classList.toggle("error", !!error);
}
function showVoice(settings) {
  for (const kind of ["stt", "tts"]) {
    for (const input of document.getElementById(kind).elements) {
      if (document.activeElement !== input) input.value = settings[kind][input.name] ?? "";
    }
  }
  ttsTry.disabled = !settings.tts.baseUrl;
  realtime = !!settings.stt.realtime;
  sttModes.file.classList.toggle("selected", !realtime);
  sttModes.live.classList.toggle("selected", realtime);
  speak = settings.tts.speak !== false;
  ttsModes.on.classList.toggle("selected", speak);
  ttsModes.off.classList.toggle("selected", !speak);
  voiceNote("stt");
  voiceNote("tts");
}
for (const kind of ["stt", "tts"]) {
  const form = document.getElementById(kind);
  const saveVoice = async () => {
    const fields = Object.fromEntries([...form.elements].map((input) => [input.name, input.value.trim()]));
    if (kind === "stt") fields.realtime = realtime;
    else fields.speak = speak;
    try { showVoice(await core.invoke("set_voice", { kind, fields })); voiceNote(kind); }
    catch (e) { voiceNote(kind, String(e), true); }
  };
  form.addEventListener("change", saveVoice);
  if (kind === "stt") for (const [mode, button] of Object.entries(sttModes)) {
    button.onclick = () => { realtime = mode === "live"; saveVoice(); };
  }
  if (kind === "tts") for (const [mode, button] of Object.entries(ttsModes)) {
    button.onclick = () => { speak = mode === "on"; if (!speak) Speech.quiet(); saveVoice(); };
  }
  form.addEventListener("submit", (e) => { e.preventDefault(); saveVoice(); });
}
ttsTry.onclick = async () => {
  ttsTry.disabled = true;
  voiceNote("tts", "読み上げています…");
  try { await Speech.say("こんにちは。この声で返事を読み上げます。"); voiceNote("tts"); }
  catch (e) { voiceNote("tts", String(e), true); }
  ttsTry.disabled = false;
};
// 見回りの予定。決めるのは CLI（familiar tick）で、ここは config.json に書くだけ
const DAYS = ["日", "月", "火", "水", "木", "金", "土"]; // Calendar の表記では 1 が日曜
const scanForm = document.getElementById("scan"), scanNote = document.getElementById("scan-note");
const timesInput = document.getElementById("scan-times"), every = document.getElementById("scan-every");
const startHour = document.getElementById("scan-start"), endHour = document.getElementById("scan-end");
const modeButtons2 = { times: document.getElementById("mode-times"), interval: document.getElementById("mode-interval") };
const meetButtons = { on: document.getElementById("meet-on"), off: document.getElementById("meet-off") };
const dayButtons = [2, 3, 4, 5, 6, 7, 1].map((day) => {
  const b = document.createElement("button");
  b.type = "button";
  b.textContent = DAYS[day - 1];
  b.dataset.day = day;
  b.onclick = () => { b.classList.toggle("selected"); saveSchedule(); };
  document.getElementById("days").append(b);
  return b;
});
const option = (value, label) => Object.assign(document.createElement("option"), { value, textContent: label });
const clockText = (t) => t.replace(/^0(?=\d)/, ""); // 08:00 → 8:00
const minutes = (n) => n % 60 ? `${n} 分ごと` : `${n / 60} 時間ごと`;
for (let h = 0; h < 24; h++) startHour.append(option(h, `${h} 時`));
for (let h = 1; h <= 24; h++) endHour.append(option(h, `${h} 時`));
let schedule = null;

function dayWords(days) {
  const key = [...days].sort().join();
  if (days.length === 7) return "毎日";
  if (key === "2,3,4,5,6") return "平日";
  if (key === "1,7") return "土日";
  return [2, 3, 4, 5, 6, 7, 1].filter((d) => days.includes(d)).map((d) => DAYS[d - 1]).join("・") + "曜";
}
function scanSummary(s) {
  const when = s.mode === "times"
    ? `${dayWords(s.weekdays)}、${s.times.map(clockText).join("・")} に見回ります。スリープで逃したときは、戻ったときに 1 回見回ります`
    : `${dayWords(s.weekdays)}の ${s.startHour} 時から ${s.endHour} 時まで、${minutes(s.intervalMinutes)}に見回ります`;
  return `${when}。${s.meetingScans ? "人と会う予定の前と後にも見回ります" : "会議の前後には見回りません"}`;
}
function showSchedule(s, error) {
  schedule = s;
  for (const b of dayButtons) b.classList.toggle("selected", s.weekdays.includes(Number(b.dataset.day)));
  for (const [mode, b] of Object.entries(modeButtons2)) b.classList.toggle("selected", mode === s.mode);
  for (const node of scanForm.querySelectorAll("[data-mode]")) node.hidden = node.dataset.mode !== s.mode;
  if (document.activeElement !== timesInput) timesInput.value = s.times.map(clockText).join(", ");
  const steps = [15, 30, 60, 120, 180, 240, 360];
  every.replaceChildren(...[...new Set([...steps, s.intervalMinutes])].sort((a, b) => a - b).map((n) => option(n, minutes(n))));
  every.value = s.intervalMinutes;
  startHour.value = s.startHour;
  endHour.value = s.endHour;
  meetButtons.on.classList.toggle("selected", s.meetingScans);
  meetButtons.off.classList.toggle("selected", !s.meetingScans);
  scanNote.textContent = error ?? scanSummary(s);
  scanNote.classList.toggle("error", !!error);
  fit();
}
async function saveSchedule(change = {}) {
  const fields = {
    mode: schedule.mode,
    times: timesInput.value.split(/[,、\s]+/).filter(Boolean),
    intervalMinutes: Number(every.value),
    startHour: Number(startHour.value),
    endHour: Number(endHour.value),
    weekdays: dayButtons.filter((b) => b.classList.contains("selected")).map((b) => Number(b.dataset.day)),
    meetingScans: schedule.meetingScans,
    ...change,
  };
  try { showSchedule(JSON.parse(await core.invoke("set_schedule", { fields }))); }
  catch (e) { showSchedule(schedule, String(e)); }
}
for (const [mode, b] of Object.entries(modeButtons2)) b.onclick = () => saveSchedule({ mode });
for (const [on, b] of Object.entries(meetButtons)) b.onclick = () => saveSchedule({ meetingScans: on === "on" });
scanForm.addEventListener("change", () => saveSchedule());
scanForm.addEventListener("submit", (e) => { e.preventDefault(); timesInput.blur(); });
const loadSchedule = () => core.invoke("familiar", { args: ["schedule"] }).then((out) => showSchedule(JSON.parse(out)))
  .catch((e) => { scanNote.textContent = String(e); scanNote.classList.add("error"); });

const fit = () => core.invoke("fit_panel", { height: document.querySelector("header").offsetHeight + main.scrollHeight + 4 });
event.listen("hotkey-changed", ({ payload }) => { if (!recording) show(payload); });
event.listen("settings-open", () => Promise.all([refresh(), core.invoke("display").then(showDisplay), core.invoke("voice_settings").then(showVoice), loadSchedule()]).then(fit));
event.listen("settings-closed", () => Speech.quiet());

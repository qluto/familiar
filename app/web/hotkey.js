// 設定に保存したキーの表記を、macOS の記号にする。
function hotkeyLabel(keys) {
  const marks = { Control: "⌃", Alt: "⌥", Shift: "⇧", Command: "⌘" };
  const parts = keys.split("+"), key = parts.pop();
  const name = key.replace(/^Key|^Digit/, "").replace(/^Arrow(.).*/, (_, d) => ({ U: "↑", D: "↓", L: "←", R: "→" }[d]));
  return parts.map((m) => marks[m] ?? m).join("") + name;
}

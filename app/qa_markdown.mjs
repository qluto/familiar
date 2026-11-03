// 会話の Markdown 表示の検査: node app/qa_markdown.mjs
import assert from "node:assert/strict";
await import("./web/markdown.js");
const { parse, inline } = globalThis.Markdown;

assert.deepEqual(parse("一行目\n二行目\n\n次の段落").map((b) => b.text), ["一行目\n二行目", "次の段落"]);
assert.deepEqual(parse("## 背景\n経緯").map((b) => b.type), ["heading", "paragraph"]);
assert.deepEqual(parse("説明\n- a\n- [ ] b\n- [x] c")[1].items.map((i) => i.checked), [null, false, true]);
assert.equal(parse("1. a\n2. b")[0].items[1].marker, "2.");
assert.equal(parse("- a\n  - b")[0].items[1].depth, 1);
assert.equal(parse("- a\n  続き")[0].items[0].text, "a\n続き");
assert.equal(parse("```\n# 見出しではない\n- 箇条書きでもない\n```")[0].text, "# 見出しではない\n- 箇条書きでもない");
assert.equal(parse("```\n閉じていない").at(-1).type, "code");
assert.equal(parse("> 引用\n> 続き")[0].blocks[0].text, "引用\n続き");
assert.deepEqual(parse("| a | b |\n|---|---|\n| 1 | 2 |")[0].rows, [["1", "2"]]);
assert.equal(parse("a | b")[0].type, "paragraph");
assert.equal(parse("---")[0].type, "hr");

assert.deepEqual(inline("**太字**と`コード`"), [{ type: "strong", children: [{ type: "text", text: "太字" }] }, { type: "text", text: "と" }, { type: "code", text: "コード" }]);
assert.deepEqual(inline("[元](https://x.test/1)"), [{ type: "link", text: "元", url: "https://x.test/1" }]);
assert.equal(inline("https://x.test/1。続き")[0].url, "https://x.test/1");
assert.equal(inline("https://x.test/1. 続き")[0].url, "https://x.test/1");
assert.equal(inline("https://x.test/1. 続き")[1].text, ". 続き");
// HTML は文字のまま、危ない URL はリンクにしない
assert.deepEqual(inline("<img src=x onerror=alert(1)>"), [{ type: "text", text: "<img src=x onerror=alert(1)>" }]);
assert.deepEqual(inline("[押す](javascript:alert(1))"), [{ type: "text", text: "[押す](javascript:alert(1))" }]);
assert.deepEqual(inline("2 * 3 * 4"), [{ type: "text", text: "2 * 3 * 4" }]);
console.log("OK");

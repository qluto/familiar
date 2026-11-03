// 会話の文面の Markdown 表示。文面はメールや Slack 由来のデータを含むので、
// HTML として解釈せず、記法だけを読んで textContent で組み立てる。
(() => {
  const LIST = /^(\s*)([-*+・]|\d+[.)])\s+(.*)$/;
  const CHECK = /^\[( |x|X)\]\s+(.*)$/;
  const CELLS = (line) => line.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
  const isRule = (line) => /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/.test(line) && line.includes("-");
  const startsBlock = (line) => /^(#{1,6}\s|>|```)/.test(line) || LIST.test(line) || /^\s*([-*_])(\s*\1){2,}\s*$/.test(line);

  function parse(text) {
    const lines = String(text).replace(/\r\n?/g, "\n").split("\n");
    const blocks = [];
    for (let i = 0; i < lines.length;) {
      const line = lines[i];
      if (!line.trim()) { i++; continue; }
      if (line.startsWith("```")) {
        const body = [];
        for (i++; i < lines.length && !lines[i].startsWith("```"); i++) body.push(lines[i]);
        i++;
        blocks.push({ type: "code", text: body.join("\n") });
        continue;
      }
      const heading = line.match(/^(#{1,6})\s+(.*)$/);
      if (heading) { blocks.push({ type: "heading", level: heading[1].length, text: heading[2].replace(/\s+#+\s*$/, "") }); i++; continue; }
      if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) { blocks.push({ type: "hr" }); i++; continue; }
      if (line.startsWith(">")) {
        const body = [];
        for (; i < lines.length && lines[i].startsWith(">"); i++) body.push(lines[i].replace(/^>\s?/, ""));
        blocks.push({ type: "quote", blocks: parse(body.join("\n")) });
        continue;
      }
      if (LIST.test(line)) {
        const items = [];
        for (; i < lines.length; i++) {
          const m = lines[i].match(LIST);
          if (m) {
            const check = m[3].match(CHECK);
            items.push({ depth: Math.min(Math.floor(m[1].length / 2), 3), ordered: /\d/.test(m[2]), marker: m[2],
              checked: check ? check[1] !== " " : null, text: check ? check[2] : m[3] });
          } else if (/^\s+\S/.test(lines[i]) && items.length) {
            items.at(-1).text += `\n${lines[i].trim()}`;
          } else break;
        }
        blocks.push({ type: "list", items });
        continue;
      }
      if (line.includes("|") && i + 1 < lines.length && lines[i + 1].includes("|") && isRule(lines[i + 1])) {
        const head = CELLS(line), rows = [];
        for (i += 2; i < lines.length && lines[i].includes("|") && lines[i].trim(); i++) rows.push(CELLS(lines[i]));
        blocks.push({ type: "table", head, rows });
        continue;
      }
      const body = [];
      for (; i < lines.length && lines[i].trim() && (!body.length || !startsBlock(lines[i])); i++) body.push(lines[i]);
      blocks.push({ type: "paragraph", text: body.join("\n") });
    }
    return blocks;
  }

  const SPAN = /`([^`\n]+)`|\*\*(.+?)\*\*|\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)|(https?:\/\/[^\s<>「」『』（）、。]+)|(?<![*\w])\*([^*\s][^*\n]*?)\*(?![*\w])/g;
  function inline(text) {
    const out = [];
    let at = 0;
    for (const m of text.matchAll(SPAN)) {
      if (m.index > at) out.push({ type: "text", text: text.slice(at, m.index) });
      at = m.index + m[0].length;
      if (m[1] !== undefined) out.push({ type: "code", text: m[1] });
      else if (m[2] !== undefined) out.push({ type: "strong", children: inline(m[2]) });
      else if (m[3] !== undefined) out.push({ type: "link", text: m[3], url: m[4] });
      else if (m[5] !== undefined) {
        // 文末の記号はリンクに含めない
        const url = m[5].replace(/[.,;:!?)\]]+$/, "");
        out.push({ type: "link", text: url, url });
        at -= m[5].length - url.length;
      } else out.push({ type: "em", children: inline(m[6]) });
    }
    if (at < text.length) out.push({ type: "text", text: text.slice(at) });
    return out;
  }

  function render(text, open) {
    const make = (tag, className, ...children) => {
      const n = document.createElement(tag);
      if (className) n.className = className;
      n.append(...children);
      return n;
    };
    const spans = (source) => inline(source).flatMap(function toNodes(s) {
      if (s.type === "text") return s.text.split("\n").flatMap((part, i) => i ? [make("br"), part] : [part]);
      if (s.type === "code") return [make("code", "", s.text)];
      if (s.type === "strong") return [make("strong", "", ...s.children.flatMap(toNodes))];
      if (s.type === "em") return [make("em", "", ...s.children.flatMap(toNodes))];
      if (!s.url.startsWith("https://")) return [s.text]; // 開けるのは https だけ
      const link = make("button", "md-link", s.text);
      link.type = "button";
      link.title = s.url;
      link.onclick = () => open(s.url);
      return [link];
    });
    const block = (b) => {
      if (b.type === "paragraph") return make("p", "", ...spans(b.text));
      if (b.type === "heading") return make("h4", "", ...spans(b.text));
      if (b.type === "hr") return make("hr");
      if (b.type === "code") return make("pre", "", b.text);
      if (b.type === "quote") return make("blockquote", "", ...b.blocks.map(block));
      if (b.type === "table") {
        const row = (cells, tag) => make("tr", "", ...cells.map((c) => make(tag, "", ...spans(c))));
        return make("div", "md-table", make("table", "", make("thead", "", row(b.head, "th")), make("tbody", "", ...b.rows.map((r) => row(r, "td")))));
      }
      return make("ul", "", ...b.items.map((item) => {
        const mark = item.checked === null ? (item.ordered ? item.marker : "・") : item.checked ? "☑" : "☐";
        const li = make("li", "", make("span", "md-mark", mark), make("span", "md-item", ...spans(item.text)));
        li.style.marginLeft = `${item.depth * 14}px`;
        return li;
      }));
    };
    return make("div", "md", ...parse(text).map(block));
  }

  globalThis.Markdown = { parse, inline, render };
})();

// 声の出し入れ。サーバとのやりとりはアプリ側（voice.rs）が行い、ページは録音と再生だけをする。
(() => {
  const { core, event } = window.__TAURI__;

  // ── 読み上げ。新しく読むときと止めるときは、前の声を切る
  let audio = null, url = null, turn = 0;
  function quiet() {
    turn++;
    if (audio) { audio.pause(); audio = null; }
    if (url) { URL.revokeObjectURL(url); url = null; }
  }
  async function say(text) {
    quiet();
    const mine = turn;
    const bytes = await core.invoke("speak", { text });
    if (mine !== turn || !bytes.byteLength) return;
    url = URL.createObjectURL(new Blob([bytes], { type: "audio/mpeg" }));
    audio = new Audio(url);
    await new Promise((resolve, reject) => {
      audio.onended = resolve;
      audio.onerror = () => reject(new Error("音声を再生できません"));
      audio.play().catch(reject);
    });
  }

  // ── 録音。マイクの音を PCM16 にして、話しながら送るか、止めたときに WAV で送る
  let capture = null, onText = null;
  event.listen("listen-text", ({ payload }) => onText?.(payload));
  const recording = () => !!capture;
  const level = () => capture?.level ?? 0; // いまの声の大きさ（0〜1）

  function wav(chunks, rate) {
    const length = chunks.reduce((n, c) => n + c.byteLength, 0);
    const out = new DataView(new ArrayBuffer(44 + length));
    const text = (at, s) => [...s].forEach((c, i) => out.setUint8(at + i, c.charCodeAt(0)));
    text(0, "RIFF"); out.setUint32(4, 36 + length, true); text(8, "WAVE");
    text(12, "fmt "); out.setUint32(16, 16, true); out.setUint16(20, 1, true); out.setUint16(22, 1, true);
    out.setUint32(24, rate, true); out.setUint32(28, rate * 2, true); out.setUint16(32, 2, true); out.setUint16(34, 16, true);
    text(36, "data"); out.setUint32(40, length, true);
    let at = 44;
    for (const c of chunks) { new Uint8Array(out.buffer, at, c.byteLength).set(new Uint8Array(c)); at += c.byteLength; }
    return new Uint8Array(out.buffer);
  }

  // realtime なら話しながら送り、途中の文を onText に渡す
  async function listen({ realtime, rate, onText: show }) {
    quiet(); // 自分の声と読み上げを重ねない
    if (realtime) await core.invoke("listen_start"); // つながらないなら、マイクを開く前に知らせる
    let stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true } });
    } catch (e) {
      if (realtime) core.invoke("listen_cancel");
      throw e;
    }
    const context = new AudioContext();
    await context.audioWorklet.addModule("pcm-worklet.js");
    const node = new AudioWorkletNode(context, "pcm16", { numberOfOutputs: 0, processorOptions: { rate } });
    const c = { stream, context, node, realtime, rate, chunks: [], sending: Promise.resolve(), flushed: null, level: 0 };
    node.port.onmessage = ({ data }) => {
      if (data === "flushed") return c.flushed?.();
      if (typeof data === "number") return void (c.level = data);
      if (!realtime) return void c.chunks.push(data);
      // 届いた順に送る。止めるときは送り終えてから区切る
      c.sending = c.sending.then(() => core.invoke("listen_audio", new Uint8Array(data))).catch(() => {});
    };
    context.createMediaStreamSource(stream).connect(node);
    onText = show;
    capture = c;
  }
  async function release() {
    const c = capture;
    capture = null; onText = null;
    c.stream.getTracks().forEach((t) => t.stop());
    await c.context.close();
  }
  // 録った声を文字にする。何も録れていなければ空文字
  async function finish() {
    const c = capture;
    if (!c) return "";
    await new Promise((resolve) => { c.flushed = resolve; c.node.port.postMessage("flush"); });
    const show = onText;
    await release();
    if (c.realtime) {
      onText = show; // 区切ったあとの仕上げも見せる
      await c.sending;
      try { return await core.invoke("listen_stop"); } finally { onText = null; }
    }
    if (!c.chunks.length) return "";
    return core.invoke("transcribe", wav(c.chunks, c.rate), { headers: { "content-type": "audio/wav" } });
  }
  async function cancel() {
    const c = capture;
    if (!c) return;
    await release();
    if (c.realtime) core.invoke("listen_cancel");
  }

  globalThis.Speech = { say, quiet, listen, finish, cancel, recording, level };
})();

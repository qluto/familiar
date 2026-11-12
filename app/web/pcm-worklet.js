// マイクの音を、音声認識に渡す PCM16 モノラルへ変える。間引くときは区間の平均を取り、折り返しの雑音を抑える。
// 100 ms ごとにまとめて送る。"flush" を受けたら残りを送ってから "flushed" を返す。
// 約 50 ms ごとに音の大きさ（0〜1 の数値）も送る。マイクのボタンの動きに使う。
class Pcm16 extends AudioWorkletProcessor {
  constructor({ processorOptions }) {
    super();
    this.step = sampleRate / processorOptions.rate; // 出力 1 サンプルあたりの入力サンプル数
    this.out = new Int16Array(Math.round(processorOptions.rate / 10));
    this.n = 0; this.sum = 0; this.count = 0; this.acc = 0;
    this.power = 0; this.heard = 0; this.every = sampleRate / 20;
    this.port.onmessage = () => { this.flush(); this.port.postMessage("flushed"); };
  }
  flush() {
    if (!this.n) return;
    const chunk = this.out.slice(0, this.n);
    this.port.postMessage(chunk.buffer, [chunk.buffer]);
    this.n = 0;
  }
  // 二乗平均をデシベルにし、-60 dB から -12 dB を 0〜1 に割り当てる
  measure(samples) {
    for (const s of samples) this.power += s * s;
    this.heard += samples.length;
    if (this.heard < this.every) return;
    const db = 10 * Math.log10(this.power / this.heard + 1e-12);
    this.port.postMessage(Math.max(0, Math.min(1, (db + 60) / 48)));
    this.power = 0; this.heard = 0;
  }
  process([input]) {
    const samples = input[0];
    if (!samples) return true;
    this.measure(samples);
    for (const s of samples) {
      this.sum += s; this.count++; this.acc++;
      if (this.acc < this.step) continue;
      this.acc -= this.step;
      const v = Math.max(-1, Math.min(1, this.sum / this.count));
      this.out[this.n++] = v < 0 ? v * 0x8000 : v * 0x7fff;
      this.sum = 0; this.count = 0;
      if (this.n === this.out.length) this.flush();
    }
    return true;
  }
}
registerProcessor("pcm16", Pcm16);

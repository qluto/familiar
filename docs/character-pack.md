# キャラクターパック

作り方は [`app/packs/README.md`](../app/packs/README.md)。

キャラクターは「同じ名前のクリップ一式」で差し替える。アプリは合図の意味（考える、閃く、耳を傾ける）だけを知っていて、見た目はパックに任せる。

## 置き場所と選び方
```
~/.local/share/familiar/packs/<id>/clips/
  clips.json
  blink.mp4 ...
```

`~/.local/state/familiar/config.json` の `character` に `<id>` を書き、アプリを再起動する。未指定、見つからない、壊れている場合は同梱のデフォルトを使う。`<id>` は英数字、`-`、`_` のみ。

## クリップ
必要なクリップとハブは `app/web/brain.js` の `GRAPH` のとおり。ハブは F 正面、B 背面、T 考え中、I ひらめき、Q 耳を傾ける。各クリップの最初と最後のコマは、[始点, 終点] のハブの絵と画素で揃える。

## 動画の形式
- H.264、24fps、横幅は表示する絵の 2 倍
- 左半分は乗算済みの色、右半分はアルファ（白 = 不透明）
- 窓は 280×373 で、絵の下端が画面の下端に接する

## clips.json
クリップ名ごとに `{ "frames": 総コマ数, "dur": 秒, "draw": [絵が変わるコマ番号] }`。`draw` にないコマは描かないので、動きの少ないクリップほど負荷が下がる。

## 検査
```sh
node app/qa_graph.mjs ~/.local/share/familiar/packs/<id>
```

## デフォルト
`app/packs/generate_default.py` がコードだけで描く。第三者の素材も生成モデルも使わないので、権利の問題がない。再生成には `rsvg-convert` と `ffmpeg` が要る。

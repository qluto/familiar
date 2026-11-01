# familiar

身の回りを見回り、「タスクにした方がよさそうなこと」を教えてくれる macOS の常駐マスコット。

Claude Code のコネクタ（既定は Slack / Gmail / Google Calendar / Notion / GitHub / Linear）を見回ります。提案は吹き出しで届き、採用すると指示どおりの処理を AI エージェントが行います（既定は Linear に issue を作成）。見回る先と採用時の動きは `~/.local/state/familiar/` の `sources.md` と `output.md` に日本語で書いて変えられます。権限は Claude Code の設定と許可済みの MCP に従います。守りたい方針は `output.md` に書いてください。

- **読むだけ:** 見回りのプロセスは書き込みツールを持ちません。外部に書き込むのは、人が採用した確定済みの値だけです
- **キャラクターは差し替え可能:** 同梱のデフォルトのほか、[キャラクターパック](docs/character-pack.md)を[自分で作れます](app/packs/README.md)

## 必要なもの
- macOS 13 以降（Apple Silicon）
- [Claude Code](https://claude.com/claude-code) が `~/.local/bin/claude` にあり、使うコネクタが認証済みであること

## インストール
[Releases](../../releases) の dmg から `familiar.app` を Applications に入れて起動します。定期見回りとログイン時の起動は、アプリが登録します。

## 使い方
普段のキャラクターはクリックを下のウィンドウへ通し、カーソルが重なると薄くなります。ホットキー（既定は `⌃⌥Space`）で呼ぶと、提案があれば大きな吹き出しを開き、なければ一言答えます。もう一度押すか、約 10 秒触らないと待機に戻ります。

呼んでいる間と、大きな吹き出しを × や Esc で閉じたあとの約 10 秒は、キャラクターをクリックやドラッグでき、右クリックから設定と終了を選べます。設定は大きな吹き出しの ⚙︎ からも開けます。ホットキーは設定画面で変更できます。

## 設定
その他の設定は `~/.local/state/familiar/config.json` に書きます。

```json
{ "linearTeam": "チーム名", "character": "パックの ID" }
```

## 開発
```sh
swift test --package-path cli   # CLI のテスト
node app/qa_graph.mjs           # 状態遷移の検査
app/install.sh                  # ビルドして /Applications へ入れる
```

企画は [`docs/plan.md`](docs/plan.md)、リリースの手順は [`docs/release.md`](docs/release.md)。

## ライセンス
[MIT](LICENSE)

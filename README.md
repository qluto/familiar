# familiar

身の回りを見回り、「タスクにした方がよさそうなこと」を教えてくれて、相談にも乗ってくれる macOS の常駐マスコット。

Claude Code のコネクタ（既定は Slack / Gmail / Google Calendar / Notion / GitHub / Linear）を見回ります。提案は吹き出しで届きます。採用すると AI エージェントが計画を示し、承認すると実行します（既定は Linear に issue を作成）。権限は Claude Code の設定と許可済みの MCP に従います

## 指示と記憶

`~/.local/state/familiar/workspace/` の Markdown が familiar の全ての記憶です。初回起動で会話が開き、話した内容をもとに AI が各ファイルの案を作ります。その後も話しかければ見直せます。変更は差分を見て `反映` を押すと保存されます。

| ファイル | 役割 | 書くのは |
|---|---|---|
| `SOUL.md` | 人格と振る舞い | 対話で更新 |
| `HEARTBEAT.md` | 見回りで確認すること | 対話で更新 |
| `OUTPUT.md` | 採用時にすること。守りたい方針もここへ | 対話で更新 |
| `USER.md` | 好み、関係者、進行中の仕事 | 対話と整理で更新 |
| `MEMORY.md` | 判断の基準など長く使う事実 | familiar |
| `memory/YYYY-MM-DD.md` | 採用・却下・後回しと、話した言葉 | familiar |
| `DREAMS.md` | 記憶を整理した内容の記録 | familiar |

判断が 3 件以上たまると、1 日 1 回 `USER.md` と `MEMORY.md` へ整理します。書き換える前の版は `memory/previous-*.md` に残ります。

- **権限はあなたの設定に従います:** 見回りと会話は、Claude Code の設定と許可済みの MCP の範囲で動きます。外部へ書き込まないことは指示で守らせており、強制ではありません。守りたい方針は `OUTPUT.md` に書きます
- **キャラクターは差し替え可能:** 同梱のデフォルトのほか、[キャラクターパック](docs/character-pack.md)を[自分で作れます](app/packs/README.md)

## 必要なもの
- macOS 13 以降（Apple Silicon）
- [Claude Code](https://claude.com/claude-code) が `~/.local/bin/claude` にあり、使うコネクタが認証済みであること

## インストール
[Releases](../../releases) の dmg から `familiar.app` を Applications に入れて起動します。定期見回りとログイン時の起動は、アプリが登録します。

## 使い方
普段のキャラクターはクリックを下のウィンドウへ通し、カーソルが重なると薄くなります。ホットキー（既定は `⌃⌥Space`）で呼ぶと会話が開きます。もう一度押すか、× や Esc で閉じます。

会話には見回りの結果、提案、計画、指示の変更案が並びます。見回りの行を開くと、その回の経過を読めます。

会話を閉じたあとの約 10 秒は、キャラクターをクリックやドラッグでき、右クリックから設定と終了を選べます。設定は会話の ⚙︎ からも開けます。ホットキーは設定画面で変更できます。

会話と実行の記録は `~/.local/state/familiar/` に残ります（`runs/` は 14 日間）。メールや Slack の本文を含みます。

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

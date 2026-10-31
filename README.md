# familiar

身の回りを見回り、「タスクにした方がよさそうなこと」を教えてくれる macOS の常駐マスコット。

Claude Code のコネクタ（Slack / Gmail / Google Calendar / Notion / GitHub / Linear）を読み取り専用で見回ります。提案は吹き出しで届き、採用すると Linear に issue を作ります。

- **読むだけ:** 見回りのプロセスは書き込みツールを持ちません。外部に書き込むのは、人が採用した確定済みの値だけです
- **キャラクターは差し替え可能:** 同梱のデフォルトのほか、[キャラクターパック](docs/character-pack.md)を[自分で作れます](app/packs/README.md)

## 必要なもの
- macOS 13 以降（Apple Silicon）
- [Claude Code](https://claude.com/claude-code) が `~/.local/bin/claude` にあり、使うコネクタが認証済みであること

## インストール
[Releases](../../releases) の dmg から `familiar.app` を Applications に入れて起動します。定期見回りとログイン時の起動は、アプリが登録します。

設定は `~/.local/state/familiar/config.json` に書きます。

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

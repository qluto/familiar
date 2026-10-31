# familiar — 作業メモ（Claude 向け）

Claude Code の権限（claude.ai コネクタの Slack / Gmail / Google Calendar / Notion / GitHub / Linear）で定期的に見回り、
「タスクにした方がよさそうなこと」を提案する常駐アシスタント。企画は [`docs/plan.md`](docs/plan.md)。

## 原則
- **見回りは読み取り専用。** 書き込みは、人が採用した確定済みの値を、書き込みツールだけを許可した別プロセスで行う（プロンプトインジェクション対策）
- 提案の通知先は、Mac ではマスコット、離席中は iPhone（mobile-herdr の `herdr-notify` 経由）
- 採用したタスクは Linear に作る

## 関連プロジェクト
- キャラクターはパック（`docs/character-pack.md`）。リポジトリに入れるのは、権利の問題がないデフォルトだけ。個人のパックは `~/.local/share/familiar/packs/` に置き、絶対にコミットしない
- iPhone・通知: `~/dev/projects/mobile-herdr`（`host/notify` の launchd 常駐 `herdr-notify` が APNs を送る）

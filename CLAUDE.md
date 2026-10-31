# desk-steward — 作業メモ（Claude 向け）

Claude Code の権限（claude.ai コネクタの Slack / Gmail / Google Calendar / Notion / GitHub / Linear）で定期的に見回り、
「タスクにした方がよさそうなこと」を提案する常駐アシスタント。企画は [`docs/plan.md`](docs/plan.md)。

## 原則
- **見回りは読み取り専用。** 書き込みは、人が採用した確定済みの値を、書き込みツールだけを許可した別プロセスで行う（プロンプトインジェクション対策）
- 提案の通知先は、Mac ではマスコット、離席中は iPhone（mobile-herdr の `herdr-notify` 経由）
- 採用したタスクは Linear に作る

## 関連プロジェクト
- マスコット: `~/dev/projects/animation-studio/2d/clip-mascot`（Tauri、`app/web/brain.js` が状態遷移。ハブ F 正面 / B 背面 / T 考え中 / I ひらめき）。素材の作り方は同ディレクトリの `RECIPE.md`
- iPhone・通知: `~/dev/projects/mobile-herdr`（`host/notify` の launchd 常駐 `herdr-notify` が APNs を送る）

# familiar — 作業メモ（Claude 向け）

Claude Code の権限（claude.ai コネクタの Slack / Gmail / Google Calendar / Notion / GitHub / Linear）で定期的に見回り、
「タスクにした方がよさそうなこと」を提案する常駐アシスタント。企画は [`docs/plan.md`](docs/plan.md)。

## 原則
- **入力元と出力先はユーザーの指示で決める。** `HEARTBEAT.md` と `OUTPUT.md`（`~/.local/state/familiar/workspace/`）に書き、コードにサービス固有の知識を持たせない
- **権限はエージェントとユーザーの設定に任せる。** familiar 側でツールを制限しない。守りたい方針は `OUTPUT.md` に書く。エージェントが質問を返したときだけ人に戻す
- 提案の通知先は、Mac ではマスコット、離席中は iPhone（mobile-herdr の `herdr-notify` 経由）
- 既定の出力先は Linear
- **記憶はファイルだけに置く。** 判断を日々のノートへ記録し、1 日 1 回 `USER.md` と `MEMORY.md` へ整理する。`SOUL.md` は対話か手で変え、整理では変えない
- **指示と記憶は人が全部書かなくてよい。** 初回と再セットアップの対話で、AI が聞いて書く

## 関連プロジェクト
- キャラクターはパック（`docs/character-pack.md`）。リポジトリに入れるのは、権利の問題がないデフォルトだけ。個人のパックは `~/.local/share/familiar/packs/` に置き、絶対にコミットしない
- iPhone・通知: `~/dev/projects/mobile-herdr`（`host/notify` の launchd 常駐 `herdr-notify` が APNs を送る）

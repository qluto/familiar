# familiar 企画書（ドラフト）

作成: 2026-10-31 / 状態: 企画中（実装前）

> 2026-11-02 更新: 体験の中心をキャラクターとの 1 本の会話に変えた（提案パネル、対話設定、記録の窓を統合）。採用は計画の承認を挟む。以下の 3.3 までの記述には当時の設計が残る。

## 1. 何を作るか
Claude Code が使える権限（claude.ai コネクタの Slack / Gmail / Google Calendar / Notion / GitHub / Linear）で
**一定間隔ごとに身の回りを見回り、「タスクにした方がよさそうなこと」を提案する** 常駐アシスタント。

- Mac の前にいる時は **デスクトップのマスコット**（clip-mascot）が「考え中 → ひらめき」の動きと吹き出しで知らせる
- 離席中は **iPhone**（mobile-herdr の通知経路）に届く
- 提案を採用すると **Linear に issue** を作る。コードの作業なら、そのまま herdr のペインで Claude Code に着手させる（任意）

OpenClaw との違い: チャットの入口や何でもできる実行役は作らず、**読むだけで提案する役** に絞る。
書き込みは人が採用した瞬間の 1 操作だけにする。重い実行は herdr 上のエージェントに任せる（mobile-herdr の範囲）。

## 2. 体験の流れ
1. 平日の作業時間帯、30 分ごとに見回り（間隔は設定可。会議の 30 分前や終了後などカレンダーをきっかけに臨時の見回りもする）
2. 見回り中、マスコットは **T（考え中）** のループ
3. 提案があれば **I（ひらめき / Eureka）** のポーズを決め、吹き出しで「3 件あります」
4. マスコットをクリック → 提案パネル（別ウィンドウ）
   - 各提案: タイトル / なぜ（根拠の要約）/ 出典リンク（Slack のスレッド、メール…）/ 緊急度 / Linear の下書き
   - 操作: **採用**（タイトル・チーム・期日を直してから）/ **済ませた**（委ねるまでもなく自分で終えた）/ **却下**（理由を一言、任意）
5. 採用 → Linear に issue を作り、URL を表示する。コード作業なら「herdr で着手」のボタン
6. Mac を 5 分以上触っていない、または緊急度が高い → iPhone に通知（採用・却下のアクション付き）

## 3. 構成
```
familiar/
  cli/   見回りの CLI + launchd 常駐（スケジューラ）
  app/       マスコット（clip-mascot の app/ を取り込み、提案パネルと吹き出しを足す）。familiar と prompts/ を同梱する
  prompts/   見回りの指示、出力スキーマ
  memory/    好み（採用・却下の傾向）。見回りのたびに読む

~/.local/state/familiar/
  suggestions.jsonl   提案と状態（new / shown / accepted / snoozed / dismissed）
  cursor.json         情報源ごとの「どこまで見たか」
  scan.log
```

### 3.1 見回り（読み取り専用の Claude）
```
claude -p "<prompts/scan.md + 前回以降の範囲 + 未処理・却下済みの提案一覧 + memory/preferences.md>" \
  --output-format stream-json --verbose --json-schema "<prompts/suggestions.schema.json の内容>" \
  --permission-mode dontAsk --setting-sources user --settings '{"disableAllHooks":true}' \
  --tools ToolSearch --allowedTools <読み取り系の MCP ツールだけ> \
  --disallowedTools <書き込みツール全部と無関係なサーバー> \
  --max-turns <上限> --max-budget-usd <上限> --no-session-persistence
```
- 各指定の理由は [`spike-results.md`](spike-results.md)。ユーザー設定が `defaultMode: auto` なので `dontAsk` は必須。動く実例は `spikes/scan-once.sh`
- ツール一覧と呼び出し履歴を許可リストと照合し、ずれていたら見回りを止める（初期化時点の一覧だけでは、遅れて接続するサーバーを見落とす）
- `dedupe_key` はモデルに作らせず、familiar が出典 URL から正規化する
- 出力: `coverage[]` = `{source, status(ok|partial|failed), note}` と `suggestions[]` = `{dedupe_key, title, why, sources[{kind, url, excerpt}], urgency, effort, kind(code|reply|meeting_prep|follow_up|other), linear_draft{team, title, description, due}, confidence}`
- 重複を除く: `dedupe_key`（出典 URL ベース）と Linear の既存 issue 検索で、出したことがあるもの・すでに issue 化されたものを除く
- 2 段構え: Haiku で動きの有無と候補を見て、既知を除いた候補があれば Sonnet で本文を読み下書きを作る。Sonnet だけだと 6 情報源で 1 日約 $5.5 相当になるため（S2）。候補の取りこぼしは P2 で確認する

### 3.2 採用時の書き込み（別プロセス・書き込み専用）
- 採用した提案の **確定済みの値** だけを渡し、`mcp__claude_ai_Linear__save_issue` だけを許可した `claude -p` で作る
- `save_issue` は `id` を渡すと既存 issue を更新するので、familiar が実行中のイベントを見て、確定値と完全一致する 1 回だけを通す。
  不一致なら停止するが、検知と実行は並行するため事前遮断ではない（値は人が確認済みという前提で許容する）
- **見回り役は書き込みツールを一切持たない。** メールや Slack に仕込まれた指示（プロンプトインジェクション）が
  影響できるのは提案の文面までで、人が見てからでないと外部に何も書かれない

### 3.3 マスコット（app/）
- 描画は clip-mascot の方式を使う。キャラクターはパックとして差し替える（`character-pack.md`）。リポジトリにはデフォルトだけを置く
- **T / I / Q は familiar の合図専用。** 自発動作から外し、提案がないのに閃いて見えないようにする

| 状況 | 動作 |
|---|---|
| 見回り開始 | `think_in` → T のループ |
| 終了・新規なし | `think_out` → F |
| 終了・新規あり | `idea` → I（吹き出し「N 件あります」）→ `idea_ask` → Q |
| Q でクリック | 大きな吹き出しを開く（開いている間は Q で待つ） |
| 提案をすべて処理 | `ask_ok` → F |
| 約 1.5 分放置 | `ask_out` → F（吹き出しは残す）。20 分ごとに `ask_in` で声をかけ直す |
| 見回りの失敗 | `think_out` → F、警告の吹き出し |
| 平常時 | `idle_f` / `look` / `stretch` / `turn_away` のみ |

- 吹き出しは、判断待ちか保留が 1 件でもあれば出し続ける。見回り中も消さない
- 提案は「大きな吹き出し」に表示する。紙色・線・尾を小さな吹き出しと揃え、同じ位置から広げる。保留中の提案もここで判断できる
- どちらも別ウィンドウで、マスコットの移動に追従する。閉じるのは ×、Esc、マスコットの再クリック
- familiar とのやりとり: マスコットは `live.json` を 2 秒ごとに読むだけ。状態の変更は必ず `familiar` CLI を経由する。マスコットを閉じても見回りは止まらない
- 提案の文面は信頼できないデータなので `textContent` でのみ表示し、外部リンクは https だけ開く

### 配布
- 名前とアイコンは特定のキャラクターに依存させない。キャラクターは差し替えられ、人間以外も選べる。アイコンの原本は `app/src-tauri/icons/icon.svg`
- dmg 1 つで完結する。`.app` に familiar（sidecar）と `prompts/` を同梱し、`/Applications` から起動すると定期見回りとログイン時の起動をアプリが登録する
- 公証は GitHub Actions（`.github/workflows/release.yml`）で行う。必要な secret は `docs/release.md`

### 3.4 iPhone（mobile-herdr と連携）
- 送信は既存の `herdr-notify`（APNs 実装済み）に「任意の通知を送る」入口を足して頼む。familiar 自身は APNs の鍵を持たない
- アプリ側: 通知アクション「採用 / 却下」→ SSH で `familiar accept|dismiss <id>`。一覧画面は後回し

## 4. 先に検証すること（スパイク）
S1〜S3 は完了、S4 は未着手。結果は [`spike-results.md`](spike-results.md)。

| # | 確かめること | 決まること |
|---|---|---|
| S1 | launchd から起動した `claude -p` で claude.ai コネクタ（Slack/Gmail/Calendar/Notion/GitHub/Linear）が読み込まれるか。ツール名の一覧（許可リスト用） | 構成 3.1 / 3.2 の可否 |
| S2 | `--json-schema` の出力が安定するか。1 回の見回りの所要時間と使用量（サブスクの枠をどれだけ食うか） | 見回りの間隔、2 段構えの要否 |
| S3 | Slack / Calendar / Linear コネクタの認証（今は未認証）と、読める範囲（DM・メンション・スレッド） | 情報源ごとの取り方 |
| S4 | Tauri で吹き出し用の 2 つ目のウィンドウを出し、マスコットの位置に追従させる | UI の作り |

## 5. 段階
| 段階 | 内容 | 完了の条件 |
|---|---|---|
| P0 | S1〜S3 | 1 回の見回りがターミナルで JSON を返す |
| P1 | `familiar scan / list / accept / dismiss / snooze` と状態ファイル、重複除去 | ターミナルだけで提案 → 採用 → Linear に issue |
| P2 | launchd で定期実行、作業時間帯・間隔・カレンダーきっかけ | 1 日放置して提案が溜まる。同じ提案が繰り返し出ない |
| P3 | マスコット取り込み、考え中・ひらめき・吹き出し・提案パネル | Mac 上で全部完結 |
| P4 | iPhone 通知（離席時・緊急）と通知アクション | 外出先から採用できる |
| P5 | 好みの学習（採用・却下の理由を memory に要約）、「herdr で着手」 | 却下が減る |

## 6. 決めていないこと
決定済み: familiar は Swift。既定は平日 9–20 時・30 分間隔、会議の 30 分前と、終了の 10 分後・25 分後（書き起こしが届く頃）に臨時の見回り（`config.json` で変更可）。
launchd は 5 分ごとに `familiar tick` を起こし、実行の要否は familiar が判断する。

- Linear のラベル（例: `from:familiar`）
- 却下した提案を何日覚えておくか
- 提案の上限（1 回 5 件まで、など。多すぎるとノイズになる）

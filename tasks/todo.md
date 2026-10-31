# desk-steward

企画: `docs/plan.md` / スパイク結果: `docs/spike-results.md`

## P0 スパイク
- [x] S1: launchd から起動した `claude -p` でコネクタが読めるか。読み取り系ツール名の一覧
- [x] S2: `--json-schema` で提案 JSON を返させ、所要時間と使用量を測る
- [x] S3: 6 情報源の認証、許可・拒否リストへの反映、読める範囲の確認
- [ ] S4: Tauri の 2 つ目のウィンドウ（吹き出し）をマスコットに追従させる（P3 の前に実施）

## P1
- [x] `steward scan / list / show / accept / dismiss / snooze` と状態ファイル（`steward/`、Swift）
- [x] 重複キーを steward 側で出典 URL から正規化
- [x] ツール一覧と呼び出し履歴を許可リストと照合し、ずれたら止める
- [x] partial の情報源は cursor を進めない（期間の上限は 7 日）
- [x] 実際の Linear 書き込みの確認（QLU-6 を作成）

## P2
- [x] `steward tick`（作業時間帯・間隔・会議前のきっかけ）と launchd の登録スクリプト（`steward/install.sh`）
- [x] 2 段構え（Haiku → Sonnet）。新しい候補があるときだけ Sonnet を呼ぶ
- [x] launchd で 6 情報源を通しで確認（一時ジョブと状態のコピーで実施）
- [x] Gmail のページ送りと Slack / Notion の coverage の基準を `scan.md` に明記
- [x] `steward status`
- [x] 常駐の登録（2026-10-31）
- [ ] 平日に 1 日放置して、提案が溜まること・同じ提案が出ないことを確認
- [ ] Haiku の取りこぼしを確認する

## 未決
- [ ] Slack の DM 検索の 0 件が正しいか確認する
- [ ] Notion の更新をどう検知するか（現プランでは更新日時で絞れない）
- [ ] Linear のラベル（`from:steward` を付けるか）

## レビュー（2026-10-31）
- P2: launchd 経由の 2 段構えで 6 情報源すべて ok（61 秒、換算 $0.096）。7 日分の見回りで Haiku は CI 失敗の提案を出さなかった。実行ごとのばらつきがあり、平日の結果で判断する
- launchd 経由の見回りが Gmail / Notion を読み、schema どおりの JSON を返すことを確認
- 認証後、6 情報源すべてを手動の見回りで読めることを確認（launchd での 6 情報源の実行は未実施）
- 企画書 3.1 のコマンドは読み取り専用にならなかったため修正（`dontAsk`、書き込みツールの拒否、hook 無効）
- 見回りの書き込み遮断は無害なツールの拒否で確認した（書き込みツール自体は試していない）
- P1: 提案 → 採用 → Linear の issue（QLU-6）まで実機で確認。題名の修正、チーム、優先度、担当、日本語の表記が正しいことを Linear 側で確認

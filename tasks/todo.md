# familiar

企画: `docs/plan.md` / スパイク結果: `docs/spike-results.md`

## P0 スパイク
- [x] S1: launchd から起動した `claude -p` でコネクタが読めるか。読み取り系ツール名の一覧
- [x] S2: `--json-schema` で提案 JSON を返させ、所要時間と使用量を測る
- [x] S3: 6 情報源の認証、許可・拒否リストへの反映、読める範囲の確認
- [x] S4: 吹き出しを別ウィンドウにしてマスコットの移動に追従させる（ドラッグでの実機確認は未実施）

## P1
- [x] `familiar scan / list / show / accept / dismiss / snooze` と状態ファイル（`cli/`、Swift）
- [x] 重複キーを familiar 側で出典 URL から正規化
- [x] ツール一覧と呼び出し履歴を許可リストと照合し、ずれたら止める
- [x] partial の情報源は cursor を進めない（期間の上限は 7 日）
- [x] 実際の Linear 書き込みの確認（QLU-6 を作成）

## P2
- [x] `familiar tick`（作業時間帯・間隔・会議前のきっかけ）と launchd の登録スクリプト（`cli/install.sh`）
- [x] 2 段構え（Haiku → Sonnet）。新しい候補があるときだけ Sonnet を呼ぶ
- [x] launchd で 6 情報源を通しで確認（一時ジョブと状態のコピーで実施）
- [x] Gmail のページ送りと Slack / Notion の coverage の基準を `scan.md` に明記
- [x] `familiar status`
- [x] 常駐の登録（2026-10-31）
- [ ] 平日に 1 日放置して、提案が溜まること・同じ提案が出ないことを確認
- [ ] Haiku の取りこぼしを確認する

## P3
- [x] clip-mascot の `app/` を取り込み、T / I / Q を合図専用に変更（`docs/plan.md` 3.3）
- [x] `live.json` と `familiar list --json`
- [x] 吹き出しと提案パネル
- [x] 状態機械の検査（`node app/qa_graph.mjs`）と台本での実機確認
- [x] `cli/install.sh` と `app/install.sh` の実行
- [x] 大きな吹き出しの操作を実機で確認
- [x] 署名済みの `.app` と dmg のビルド（`cargo tauri build`）

## 配布
- [x] familiar と prompts の同梱、アプリによる launchd 登録、二重起動の防止
- [x] GitHub Actions のワークフローと `docs/release.md`
- [x] キャラクターに依存しないアプリアイコン（`app/src-tauri/icons/icon.svg` が原本）
- [x] MIT ライセンスで公開リポジトリを用意
- [ ] secret を登録して、ワークフローを実行する

## キャラクターパック
- [x] パック形式と読み込み、壊れたパックのときのデフォルトへの切り替え
- [x] 権利の問題がないデフォルトのキャラクター（`app/packs/generate_default.py`）
- [x] 既存のキャラクターをリポジトリの外のパックへ移動
- [ ] 履歴から旧素材と旧アイコンを除去し、push し直す

## 未決
- [ ] Slack の DM 検索の 0 件が正しいか確認する
- [ ] Notion の更新をどう検知するか（現プランでは更新日時で絞れない）
- [ ] Linear のラベル（`from:familiar` を付けるか）

## レビュー（2026-10-31）
- P2: launchd 経由の 2 段構えで 6 情報源すべて ok（61 秒、換算 $0.096）。7 日分の見回りで Haiku は CI 失敗の提案を出さなかった。実行ごとのばらつきがあり、平日の結果で判断する
- launchd 経由の見回りが Gmail / Notion を読み、schema どおりの JSON を返すことを確認
- 認証後、6 情報源すべてを手動の見回りで読めることを確認（launchd での 6 情報源の実行は未実施）
- 企画書 3.1 のコマンドは読み取り専用にならなかったため修正（`dontAsk`、書き込みツールの拒否、hook 無効）
- 見回りの書き込み遮断は無害なツールの拒否で確認した（書き込みツール自体は試していない）
- P1: 提案 → 採用 → Linear の issue（QLU-6）まで実機で確認。題名の修正、チーム、優先度、担当、日本語の表記が正しいことを Linear 側で確認

## 待機と応答、設定画面（2026-11-01）
- [x] 待機中はクリックを通し、カーソルが重なると薄くする。吹き出しも連動する
- [x] ホットキーで応答する。提案があれば大きな吹き出しを開き、なければ一言答える
- [x] 右クリックを、設定と終了のメニューにする
- [x] 設定画面でホットキーを変更して config.json に保存する
- [x] 設定画面を大きな吹き出しと同じ紙・線・尾にする（`sheet.css` を共用）
- [ ] 設定画面でのキー変更、衝突時の表示、`元に戻す` を実機の手操作で確認する
- [ ] macOS 初期設定で `⌃⌥Space` が入力ソース切り替えと重なる件の扱いを決める

### レビュー
- 実機で確認: 重なると薄くなる、待機中のクリックが page に届かない、ホットキーで開閉、右クリックメニュー、設定画面が開く、config.json の他の項目が残る
- 単体テスト: 設定画面が記録するキー文字列の解析、修飾キーなしの拒否
- 大きな吹き出しの間は背後のキャラクターへの最初のクリックが page に届かず WebView 標準メニューが出るため、この間はクリックを通す

## モーションの時刻と離席（2026-11-01）
- [x] 伸びは毎時 25 分と 55 分だけ。合図で遅れても 2 分以内なら行う
- [x] 背中向きは 10 分無入力のときだけ。入力が戻るとすぐ正面に戻る。提案があれば正面を優先する

## ノッチ表示の試作（2026-11-01、`notch-mode` ブランチ）
- [x] ノッチの左右に印と件数を出す。何もなければ隠す
- [x] 設定で切り替え、キャラクターの再生を止める。大きな吹き出しはノッチの下に尾なしで開く
- [x] 全画面の Space ではノッチもキャラクターも出さず、動画と呼吸も止める（枠の大きさは最大化と同じで判定に使えないため、macOS の Space の扱いと `document.hidden` に任せる）
- [ ] クリック、右クリック、メニューバーとの干渉を手操作で確認する
- [ ] 新しい提案を見つけたときに広がる表示
- [ ] ノッチのある画面の抜き差しへの追従（今は起動時と切り替え時だけ判定する箇所がある）

## 入力元と出力先の自由化（2026-11-01）
- [x] `HEARTBEAT.md` と `OUTPUT.md` を指示として読み、なければ同梱の既定を置く
- [x] 提案の形式からサービス固有の項目を外す。保存済みの提案は読み込み時に引き継ぐ
- [x] familiar 側のツール制限をやめ、権限はエージェントとユーザーの設定に任せる
- [x] 編集欄を AI への一言に置き換え、質問が返ったときだけ人に戻す
- [x] 実物の Claude で、見回り、質問、返事からの完了を一時フォルダで通す
- [ ] Linear への実際の作成を、採用から確認する
- [ ] Codex など Claude Code 以外の実行役

## ファイルの記憶（2026-11-01、OpenClaw を参考）
- [x] `workspace/` に指示と記憶を集め、以前の指示を引き継ぐ
- [x] SOUL / USER / MEMORY と直近の判断を全ての実行へ渡す
- [x] 採用・却下・後回しを日々のノートへ記録する
- [x] 1 日 1 回、ツールなしの実行で `USER.md` と `MEMORY.md` へ整理する
- [ ] 実データで整理の質を確かめる

## 対話での設定（2026-11-01）
- [x] 初回起動で AI との対話を開き、合意した内容を AI が各ファイルへ書く
- [x] 設定から同じ対話を開いて見直せる。閉じても続きから再開できる
- [ ] 実際の初回起動を、最初の質問から保存まで画面で通す

## 新キャラクターの正面待機画像（2026-11-01）
- [x] パック作成手順と元絵の条件を確認
- [x] 落ち着いた成人女性、お尻の下付近から上、両手が見える基準絵を生成
- [x] 構図・手・背景を確認し、生成プロンプトと画像を保存

### 制作方針
控えめなイラスト調、淡い日常着、小さな微笑み。両手を重ねず腰の前に自然に下ろす。単色背景、明瞭な輪郭、固定カメラで後のハブ編集に備える。今回は正面待機の元絵まで。

### 基準絵のレビュー
- 組み込み image_gen で生成。両肩から肘・手首・指先まで入り、左右の手が重ならないことを目視確認。淡色の日常着と控えめな表情。
- `output/character-concepts/calm-woman-v1/idle-f.png` と `prompt.txt` に保存。個人用素材は `output/.gitignore` でコミット対象から除外。
- 背景は淡青色。動画制作前に背景の完全な単色化、表示枠に対する頭上の余白を再確認する。今回は元絵のみで、動画・パック化は未実施。

## 待機画像の調整（2026-11-01）
- [x] 真正面から斜め向きへ変更し、直視を避ける
- [x] 質感を簡略化し、アニメ調へ変更
- [x] 両手と指先が画面内にあることを目視確認し、v2 とプロンプトを保存

### レビュー
組み込み image_gen で元絵を編集。斜めの体、横へ逃がした視線、簡潔な線と陰影を確認。元絵は保持し、`output/character-concepts/calm-woman-v2/` に保存。

## 待機画像の手と視線の調整（2026-11-01）
- [x] 両手を腰の前で指先から軽く組む姿勢に編集
- [x] 身体の斜め向きを維持して視線をこちらに戻す
- [x] 両手・手首の接続と画面内の収まり、視線を目視確認

### レビュー
組み込み image_gen で編集し、元画像を保持して `output/character-concepts/calm-woman-v3/idle-f.png` と `prompt.txt` に保存。腕組みではなく低い位置で指を添える形。アニメ調、服装、配色を維持。

## 待機画像の服装と正面方向の調整（2026-11-01）
- [x] ブラウスと控えめなジャケットで少しフォーマルに編集
- [x] 身体の角度を浅くし、顔と目線を画面手前の見る人へ向ける
- [x] 指先を軽く組む姿勢、両手の収まり、服装と視線を目視確認

### レビュー
組み込み image_gen で編集。`output/character-concepts/calm-woman-v4/idle-f.png` と `prompt.txt` に保存し、旧版を保持。

## 待機画像の下端調整（2026-11-01）
- [x] 下側の脚の見える範囲を短く編集
- [x] 両手の指先が余白を持って画面内に収まることを目視確認

### レビュー
組み込み image_gen で編集し、`output/character-concepts/calm-woman-v5/idle-f.png` と `prompt.txt` に保存。旧版を保持。

## v5 採用・アニメーションと配布条件の調査（2026-11-01）
- [x] ユーザーが v5 を採用。以後の基準元絵は `output/character-concepts/calm-woman-v5/idle-f.png`
- [x] パック手順と GRAPH を確認（5 ハブ、閉じ目差分、全20クリップ）
- [x] OpenAI、Google Cloud、Creative Commons、OSI、文化庁の一次資料を確認

### レビュー
- 制作可能性は高いが、動画生成は未実施。手の接触解除・背面への回転を試作で検証する。背景の単色化と頭上の動作余白を整え、伸びは肩・肘の小さな動作にする。
- OpenAI 規約は法令の許す範囲で Output の権利を利用者へ帰属・譲渡する。著作権の成立や第三者権利の非侵害を保証するものではない。
- コード MIT、素材 CC0 または CC BY 4.0 が配布案。素材への適用はまだ行っていない。動画提供元の条件を制作時に確定し、下流の再配布を含めて確認する。非商用限定は OSS の要件を満たさない。
- Google Cloud の Veo 3.1 は始点・終点指定に対応。ただし Cloud 規約には生成出力のモデル競合・学習用途等の制約もあり、出力の所有権条項だけで無制限の再許諾を断定しない。Gemini API の Veo preview は現行資料で終了済み。
- 利用可能な接続ツールに動画生成機能は見つからず。動画生成には別途実行環境・サービスの接続が必要。
- 資料: https://openai.com/policies/terms-of-use/ ; https://cloud.google.com/terms/service-terms ; https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/video/generate-videos-from-first-and-last-frames ; https://creativecommons.org/publicdomain/zero/1.0/ ; https://creativecommons.org/licenses/by/4.0/ ; https://opensource.org/osd ; https://www.bunka.go.jp/seisaku/chosakuken/kaizoku/faq.html

## fal.ai の動画モデルと配布条件（2026-11-01）
- [x] `.env` の FAL_KEY の存在のみ確認（値は非表示、API認証は未検証）
- [x] fal 利用規約・API補足規約・AUPと候補モデルの公式ページを確認
- [x] Wan FLF2V の公式重みライセンスと生成物の権利説明を確認

### レビュー
- 第一候補: `fal-ai/wan-flf2v`（Wan 2.1、2.2/2.7/3.0 と混同しない）。始点・終点指定、fal上で商用利用可。公式重み Apache-2.0、開発元は生成物の権利を主張しない。これを根拠に素材配布の有力候補とするが、生成物が自動的にApache-2.0になるという意味ではない。
- 料金表示: 標準81フレームで480p $0.20、720p $0.40。試作2本は720pで$0.80、16生成なら$6.40（画像生成・再試行を除く）。生成は未実施。
- Kling 2.5 Turbo Pro / 3.0 Pro: 始点・終点対応、fal Partner商用利用可。公開資料でCC0/CC BYによる素材単体の再許諾・下流利用条件までは確認できず。商用利用表示を無制限再許諾と同一視しない。
- Veo 3.1 Fast first-last endpoint: 商用利用可だが2026-11-17廃止予定と表示。新規採用の第一候補から除外。
- fal本体規約では入力の所有権は明記されるが、出力の包括的権利譲渡やCC0再配布許諾は確認できない。API補足規約も権利の成立・非侵害を保証しない。必要なら素材単体のOSS同梱、改変・再配布、CC0/CC BY、下流義務についてfalに確認する（問い合わせ未送信）。
- 前回答のコードMIT・素材CC0は配布案であり、すべての動画提供元で成立確認済みではない。
- 今回は完成MP4の同梱であり、利用者にfal生成APIを提供するアプリとは区別する。

### 一次資料
- https://fal.ai/legal/terms-of-service （2026-09-08改定）
- https://fal.ai/legal/api-services
- https://fal.ai/legal/acceptable-use-policy
- https://fal.ai/models/fal-ai/wan-flf2v
- https://fal.ai/models/fal-ai/wan-flf2v/api
- https://huggingface.co/Wan-AI/Wan2.1-FLF2V-14B-720P
- https://github.com/Wan-Video/Wan2.1#license-agreement
- https://github.com/Wan-Video/Wan2.1/blob/main/LICENSE.txt
- https://fal.ai/models/fal-ai/kling-video/v2.5-turbo/pro/image-to-video
- https://fal.ai/models/fal-ai/kling-video/v3/pro/image-to-video
- https://fal.ai/models/fal-ai/veo3.1/fast/first-last-frame-to-video

## Kling の権利条件の追加調査（2026-11-01）
- [x] Kling直販の一般規約・Web有料会員規約・有料API規約を区別して確認
- [x] fal Partner条件での商用利用表示と照合
- [x] OSS素材配布に残る確認事項を具体化

### レビュー
- 新たな根拠: Kling有料API規約（2026-04-21）の6.3は適法な入力に基づく生成物の知財権を利用者側に帰属させる（法律・別合意の留保あり）。6.4は生成物の商用利用を制限しない。これは配布を支持する根拠で、Klingを配布不可とするものではない。
- ただし直販API規約の契約相手はKling。falとKlingの個別提携契約本文、上記条項のfal利用者への適用・承継は公開資料では確認できない。
- 一般規約4.4はContentの所有権を主張しない。4.5には使用・配布時のブランド表示義務、4.6には書面許可なしの商用利用制限がある。API規約は矛盾箇所で優先し、未規定事項に一般規約を適用すると説明する。
- Web有料会員規約（2026-10-10）は複製・配布・改変・派生物を許可するが競合製品・サービス目的を除外。7.2には会員のブランド透かし除去権。Web会員特典をfal経由へ自動適用しない。
- API仕様に透かしなし出力があっても、法的な表示義務免除と同一ではない。CC BYにすれば任意の表示位置義務まで満たすとも限らない。
- 公開資料にCC0やCC BY指定がないことだけを理由に不可とはしない。残る論点はfal経由の出力権限、表示義務の免除範囲、下流利用者への契約制限の有無。
- 有料API規約本文はweb検索索引で取得できたが、直接openではJSページの見出しのみ。ブラウザの追加確認はホスト利用不可。一般規約・Web有料会員規約・falページは直接openで取得。
- 問い合わせ・動画生成は実行していない。

### 追加一次資料
- https://kling.ai/document-api/protocols/paidServiceProtocol （6.3、6.4、冒頭の優先条項）
- https://kling.ai/docs/user-policy （4.4–4.6）
- https://kling.ai/docs/payment-policy （3条の会員特典、7.2）
- https://fal.ai/models/fal-ai/kling-video/v3/pro/image-to-video

### falへの確認文案（未送信）
I plan to generate short character animations through fal's Kling 2.5 Turbo Pro and/or Kling 3.0 Pro endpoints using an original AI-generated character image that I am authorized to use. The finished clips will be background-removed, trimmed, looped and encoded for a free MIT-licensed desktop app. End users will only receive static image/video files; the app will not expose or call the Kling or fal generation APIs.
Please confirm: (1) May I distribute the original and edited clips publicly in the GitHub repository and application releases? (2) May I dedicate rights I hold in these assets under CC0, or license them under CC BY 4.0, allowing downstream modification, redistribution and commercial use without a fal/Kling account? (3) Does your Kling partner agreement waive the branding/display obligations in Kling's general Terms 4.5? If not, is an attribution in an accompanying README/NOTICE sufficient, and must recipients preserve it? (4) Do any competitive-use, model-training, redistribution or other restrictions attach to the clips or need to be passed to recipients? Please identify the terms applicable specifically to output generated through fal.

## Kling/fal追加調査・結論の更新（2026-11-01）
- [x] falの第三者コンテンツ条項を全文確認し、前回の見落としを補足
- [x] CC0/CC BYの許諾範囲と契約上の制限を区別

### レビュー
- fal利用規約14.3(1)は第三者モデルの出力を競合製品・サービスの開発・改善等に使うことを禁止する。学習・微調整を含む。これはfal契約者への利用制限であり、すべての受取人へ自動的に同じ義務が移るとは断定しない。14.2は第三者の追加条件が適用され得るとする。
- 前回は表示義務を主要な未確認点としたが、出力の競合用途制限も具体的な論点。CC0は保有する著作権等の放棄であり、falとの契約義務を消さない。CC0を付ける行為そのものが必ず禁止とも言い切れない。
- 完成素材の通常の同梱を支持する商用利用表示はある。無条件の再利用・再配布については公開資料から確定不可。個別提携契約・公式回答を得たとの主張はしない。
- https://fal.ai/legal/terms-of-service （14.2、14.3）
- https://creativecommons.org/publicdomain/zero/1.0/legalcode.en
- https://creativecommons.org/licenses/by/4.0/legalcode.en

## Wan 2.1 FLF2V パイロット制作（2026-11-01）
- [ ] v5の見た目と構図を維持して単色背景のF/B基準絵を用意・目視確認
- [ ] 素材ディレクトリにCC BY 4.0全文とASSETS.mdを配置
- [ ] fal-ai/wan-flf2v、720p、81フレームでidle_fとturn_awayの2本だけ生成
- [ ] フレーム抽出で顔・手・背景・カメラ移動を検査し、プレビューと結果を保存

### 制作計画
採用元絵v5を保持し、`output/character-concepts/calm-woman-pack/` に制作物を集める。今回の先行2本で品質を判断し、未検証のまま残りを一括生成しない。API送信は各1回、結果取得は保存したrequest_idで再開可能にする。FAL_KEYは表示・出力ファイルへ保存しない。

## 見回りの記録と見直し（2026-11-02）
- [x] 全ての `claude -p` の stream-json と指示を `runs/` に残す（本人のみ読める形、14 日で削除）
- [x] `familiar runs / log / review` と `prompts/review.md`
- [x] 大きな吹き出しで記録を読み、AI と話し、差分を見て反映する（右クリックと設定の `記録`）
- [x] 思考の本文は記録に残らないので、見回りに判断を文章で書かせる
- [ ] 実機で手操作の確認（右クリックから開く、`実行中` の追従、反映）
- [ ] `scan --dry-run --since` で同じ範囲をやり直して比べる
- [ ] workspace の git 管理（今は 1 世代の控えのみ）

### レビュー
- 単体テスト 36 件、`cargo test`、`node app/qa_graph.mjs` が成功
- 一時フォルダの状態で、実物の Claude により 見回り → 記録の表示 → 変更案 → 反映 を確認。見回りは 35 秒、$0.017、37 項目。案は反映まで保存されなかった
- 窓が開き、680x720 に広がることを CGWindowList で確認。実機のスクリーンショットは真っ黒で取れず、見た目は同じ HTML を実データとスタブでブラウザに描いて確認。ログ欄が潰れる不具合をこれで発見して修正
- AI はツールなし・コネクタなしで案だけを返す。案のあとにファイルが変わっていたら反映しない
- 見回り自体の権限は未対応。README の「読むだけ」と実装のずれは残っている

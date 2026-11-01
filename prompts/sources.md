# 見回る先
このファイルを書き換えると、見回る先と確認の手順を変えられます。

メール、Slack（メンション・DM・自分が関わるスレッド）、カレンダー（今後の予定と準備）、Notion の更新・コメント、
GitHub（自分宛てのレビュー依頼・担当 issue）、Linear（担当 issue・通知）のうち、この指示の末尾に示す期間に動きがあったものを見ます。

- gmail: 期間の開始時刻を `after:<UNIX 秒>` にして検索する。次ページは、結果の `nextPageToken` をそのまま渡して送る。件名で候補を絞り、候補の本文を読む
- slack: 自分へのメンションと DM を検索する。自分の ID は `slack_search_users` か `slack_read_user_profile` で調べる
- calendar: 今後 7 日の予定を取得する
- notion: 検索と最近のページ一覧で確認する。更新日時で絞れないのは既知の制約なので、これができれば coverage は ok とする
- github: `get_me` の後、`review-requested:@me` の PR、`assignee:@me` と `mentions:@me` の open な issue を検索する
- linear: 担当 issue と通知を確認する。すでに issue があるものは提案しない

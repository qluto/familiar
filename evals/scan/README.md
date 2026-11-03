# 見回りの eval

`familiar eval` で、見回りの判断を架空の情報源で確かめます。ツールは使わず、各ケースの `data` を情報源から取得した内容として渡します。`scan.md` を直したときに、取りこぼしや余計な提案が増えていないかを測ります。

```sh
familiar eval                  # haiku で全ケース
familiar eval --model sonnet   # 精査と同じモデル
familiar eval --only follow    # 名前に follow を含むケース
```

## ケースの形
- `data`: 情報源から取得したことにする内容。URL は出典として使われる
- `known`: すでに出した提案と、預けたもの（`status: accepted`）
- `expect.suggest`: 出るべき提案。1 件ごとに、題か details に含まれるべき語の候補。ここにない提案は「余計な提案」
- `expect.allow`: 出なくてもよいが、出ても誤りではない提案の語（不審なメールへの注意など）
- `expect.revise`: 出るべき見直し（`[id, action]`）。ここにない見直しは誤り
- `expect.follow`: 預けたものごとに許す様子。`null` は「何も返さない」を許す

人や会社の名前、ドメインはすべて架空にします。実在のメールを入れると、モデルが例を答えと取り違えるうえ、個人の内容がリポジトリに残ります。

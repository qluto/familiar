# リリース

`v*` のタグを push するか、Actions の手動実行で `.github/workflows/release.yml` が走る。
テスト → ビルド → 署名 → 公証 → ステープルのあと、dmg を Artifacts に残す。タグのときは GitHub Release にも載せる。

## 自動更新
タグのリリースには、dmg のほかに `familiar.app.tar.gz`（署名付きの更新）と `latest.json` を載せる。
`/Applications` のアプリは、起動の 1 分後と 6 時間ごとに `releases/latest/download/latest.json` を確かめる。
新しい版があれば裏で入れ替え、会話と設定が閉じていて 2 分操作がないときに再起動する。再起動のあと、キャラクターが新しい版を知らせる。

更新の署名鍵は `app/setup-updater-key.sh` で作る。公開鍵を `tauri.conf.json` に書き、秘密鍵とパスワードを secret に登録する。
秘密鍵は `~/.tauri/familiar.key`、パスワードはキーチェーンの「familiar updater signing key」にある。
**鍵をなくすと、配布済みのアプリは自動で更新できなくなる。** 必ずバックアップする。手元の `install.sh` のビルドは更新用のアーカイブを作らないので、鍵は要らない。

## リポジトリの secret
| 名前 | 内容 |
|---|---|
| `APPLE_CERTIFICATE` | Developer ID Application 証明書の .p12 を base64 にしたもの |
| `APPLE_CERTIFICATE_PASSWORD` | .p12 のパスワード |
| `KEYCHAIN_PASSWORD` | CI の一時キーチェーン用。任意の長いランダム文字列 |
| `APPLE_ID` | Apple ID のメールアドレス |
| `APPLE_PASSWORD` | Apple ID の App 用パスワード（通常のパスワードではない） |
| `APPLE_TEAM_ID` | `RS9ESGN72R` |
| `TAURI_SIGNING_PRIVATE_KEY` | 更新の署名に使う秘密鍵（`app/setup-updater-key.sh` が登録） |
| `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | その鍵のパスワード（同上） |

証明書は「キーチェーンアクセス」で秘密鍵ごと .p12 に書き出し、次のように登録する。

```sh
base64 -i DeveloperID.p12 | gh secret set APPLE_CERTIFICATE
```

## ローカルでのビルド
`app/install.sh` で署名済みのアプリをビルドし、`/Applications` へ入れて起動する。ローカルでは公証しない。

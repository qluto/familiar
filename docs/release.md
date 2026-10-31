# リリース

`v*` のタグを push するか、Actions の手動実行で `.github/workflows/release.yml` が走る。
テスト → ビルド → 署名 → 公証 → ステープルのあと、dmg を Artifacts に残す。タグのときは GitHub Release にも載せる。

## リポジトリの secret
| 名前 | 内容 |
|---|---|
| `APPLE_CERTIFICATE` | Developer ID Application 証明書の .p12 を base64 にしたもの |
| `APPLE_CERTIFICATE_PASSWORD` | .p12 のパスワード |
| `KEYCHAIN_PASSWORD` | CI の一時キーチェーン用。任意の長いランダム文字列 |
| `APPLE_ID` | Apple ID のメールアドレス |
| `APPLE_PASSWORD` | Apple ID の App 用パスワード（通常のパスワードではない） |
| `APPLE_TEAM_ID` | `RS9ESGN72R` |

証明書は「キーチェーンアクセス」で秘密鍵ごと .p12 に書き出し、次のように登録する。

```sh
base64 -i DeveloperID.p12 | gh secret set APPLE_CERTIFICATE
```

## ローカルでのビルド
`app/install.sh` で署名済みのアプリをビルドし、`/Applications` へ入れて起動する。ローカルでは公証しない。

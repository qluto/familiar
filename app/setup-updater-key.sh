#!/usr/bin/env bash
# 自動更新の署名鍵を作り、公開鍵を tauri.conf.json へ、秘密鍵とパスワードを GitHub の secret へ登録する。
# 秘密鍵は ~/.tauri/familiar.key、パスワードはキーチェーン（familiar updater signing key）に残る。
# 鍵をなくすと、配布済みのアプリは自動では更新できなくなる。必ずバックアップする。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="${HOME}/.tauri/familiar.key"
SERVICE="familiar updater signing key"

if [ -e "${KEY}" ]; then
  echo "既存の鍵を使います: ${KEY}"
  PW=$(security find-generic-password -s "${SERVICE}" -a "${USER}" -w)
else
  mkdir -p "${HOME}/.tauri"
  PW=$(openssl rand -base64 24)
  cargo tauri signer generate --ci -p "${PW}" -w "${KEY}" >/dev/null
  chmod 600 "${KEY}"
  security add-generic-password -U -s "${SERVICE}" -a "${USER}" -w "${PW}"
  echo "鍵を作りました: ${KEY}（パスワードはキーチェーンの「${SERVICE}」）"
fi

node -e '
  const fs = require("fs");
  const [conf, pub] = process.argv.slice(1);
  const c = JSON.parse(fs.readFileSync(conf, "utf8"));
  c.plugins.updater.pubkey = fs.readFileSync(pub, "utf8").trim();
  fs.writeFileSync(conf, JSON.stringify(c, null, 2) + "\n");
' "${DIR}/src-tauri/tauri.conf.json" "${KEY}.pub"
echo "公開鍵を tauri.conf.json に書きました"

gh secret set TAURI_SIGNING_PRIVATE_KEY < "${KEY}"
printf '%s' "${PW}" | gh secret set TAURI_SIGNING_PRIVATE_KEY_PASSWORD
echo "GitHub の secret を登録しました"

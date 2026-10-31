#!/usr/bin/env bash
# 署名済みのアプリと dmg をビルドし、/Applications へ入れて起動する。
# 定期見回りとログイン時の起動は、アプリが起動時に自分で登録する。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="io.qluto.familiar.mascot"
APP="/Applications/familiar.app"

echo "==> build"
(cd "$DIR/src-tauri" && cargo tauri build)

echo "==> install $APP"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# 旧名のアプリ。定期見回りと状態の移行は、新しいアプリが起動時に行う
launchctl bootout "gui/$(id -u)/dev.qluto.desk-steward.mascot" 2>/dev/null || true
osascript -e 'quit app "desk-steward"' 2>/dev/null || true
rm -rf /Applications/desk-steward.app
osascript -e 'quit app "familiar"' 2>/dev/null || true
rm -rf "$APP"
ditto "$DIR/src-tauri/target/release/bundle/macos/familiar.app" "$APP"
open "$APP"
echo "dmg: $(ls "$DIR"/src-tauri/target/release/bundle/dmg/*.dmg)"

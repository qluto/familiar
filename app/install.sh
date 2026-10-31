#!/usr/bin/env bash
# 署名済みのアプリと dmg をビルドして /Applications へ入れ、ログイン時に起動する launchd エージェントとして（再）登録する。
# 右クリックの終了は正常終了なので、再起動しない。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="dev.qluto.desk-steward.mascot"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="/Applications/desk-steward.app"
BIN="$APP/Contents/MacOS/desk-steward-mascot"
STATE="$HOME/.local/state/desk-steward"

echo "==> build"
(cd "$DIR/src-tauri" && cargo tauri build)

echo "==> install $APP"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -rf "$APP"
ditto "$DIR/src-tauri/target/release/bundle/macos/desk-steward.app" "$APP"
mkdir -p "$STATE" "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$STATE/mascot.log</string>
</dict>
</plist>
PLIST

echo "==> (re)start launchd agent $LABEL"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "dmg: $(ls "$DIR"/src-tauri/target/release/bundle/dmg/*.dmg)"
echo "停止: launchctl bootout gui/$(id -u)/$LABEL"

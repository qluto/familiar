#!/usr/bin/env bash
# steward をビルドし、launchd の定期実行として（再）登録する。再実行で再ビルド＋再登録。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="dev.qluto.desk-steward.tick"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$HOME/.local/bin/steward"
STATE="$HOME/.local/state/desk-steward"

echo "==> build"
swift build -c release --package-path "$DIR"
mkdir -p "$HOME/.local/bin" "$STATE" "$HOME/Library/LaunchAgents"
install -m 755 "$DIR/.build/release/steward" "$BIN"

# 実行するかどうかは tick が判断する。launchd は起こすだけ
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>tick</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$STATE/tick.out.log</string>
  <key>StandardErrorPath</key><string>$STATE/tick.out.log</string>
</dict>
</plist>
PLIST

echo "==> (re)start launchd agent $LABEL"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
"$BIN" status
echo
echo "停止: launchctl bootout gui/$(id -u)/$LABEL"

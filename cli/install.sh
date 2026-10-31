#!/usr/bin/env bash
# ターミナルで使う familiar を ~/.local/bin へ入れる。定期見回りはアプリが登録するので、ここでは触らない。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
swift build -c release --package-path "$DIR"
mkdir -p "$HOME/.local/bin"
rm -f "$HOME/.local/bin/steward" # 旧名
install -m 755 "$DIR/.build/release/familiar" "$HOME/.local/bin/familiar"
"$HOME/.local/bin/familiar" status

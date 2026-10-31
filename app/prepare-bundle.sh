#!/usr/bin/env bash
# familiar をビルドし、Tauri の sidecar として置く。cargo tauri build の前に自動で走る。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIPLE="$(rustc -vV | sed -n 's/^host: //p')"
swift build -c release --package-path "$ROOT/cli"
mkdir -p "$ROOT/app/src-tauri/binaries"
install -m 755 "$ROOT/cli/.build/release/familiar" "$ROOT/app/src-tauri/binaries/familiar-$TRIPLE"

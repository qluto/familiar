#!/bin/sh
# 読み取り専用の見回りを 1 回実行する。 usage: scan-once.sh <出力先.jsonl> [model] [期間]
# 権限の根拠は docs/spike-results.md。ユーザー設定は dontAsk で上書きし、hook は無効にする。
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out=$1; model=${2:-sonnet}; window=${3:-直近 24 時間}
allow=$(paste -sd, "$root/prompts/allowed-tools.txt")
deny=$(paste -sd, "$root/prompts/denied-tools.txt")
servers=mcp__blender,mcp__pencil,mcp__playwright,mcp__openaiDeveloperDocs,mcp__plugin_context7_context7
cd "$(dirname "$out")"
exec "${CLAUDE_BIN:-$HOME/.local/bin/claude}" -p "$(cat "$root/prompts/scan.md")

## 期間
${window}（現在: $(date '+%Y-%m-%d %H:%M %Z')）" \
  --model "$model" --max-turns 40 --max-budget-usd 2 \
  --output-format stream-json --verbose --no-session-persistence \
  --json-schema "$(cat "$root/prompts/suggestions.schema.json")" \
  --permission-mode dontAsk --setting-sources user --settings '{"disableAllHooks":true}' \
  --tools ToolSearch --allowedTools "$allow" \
  --disallowedTools "$deny,$servers,Bash,Write,Edit,WebFetch" </dev/null > "$out"

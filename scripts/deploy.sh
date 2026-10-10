#!/usr/bin/env bash
# 侧载到 SteamOS 设备:构建前端 → rsync 插件文件 → 写入 plugins 目录 → 重启 plugin_loader。
# 用法:DECK_HOST=deck@<ip> DECK_PASS=<sudo 口令> bash scripts/deploy.sh
# 口令只经 stdin 传给远端 sudo,不进命令行/日志。插件目录 = ~/homebrew/plugins/<plugin.json name>。
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DECK_HOST:?需要指定目标机:DECK_HOST=deck@<ip> bash scripts/deploy.sh}"
NAME=$(python3 -c 'import json; print(json.load(open("plugin.json"))["name"])')

pnpm build

stage=$(ssh "$DECK_HOST" 'mktemp -d /tmp/decky-tools.XXXXXXXX')
trap 'ssh "$DECK_HOST" "rm -rf -- $stage"' EXIT
rsync -a --exclude '__pycache__' \
  plugin.json package.json main.py LICENSE dist py_modules "$DECK_HOST:$stage/plugin/"
rsync -a scripts/deploy-remote.sh "$DECK_HOST:$stage/install.sh"
printf '%s\n' "${DECK_PASS:-}" | ssh "$DECK_HOST" "bash $stage/install.sh $stage $(printf '%q' "$NAME")"
echo "Deployed $NAME to $DECK_HOST"

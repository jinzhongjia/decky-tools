#!/usr/bin/env bash
# 由 deploy.sh 拷到设备上执行:把暂存目录装成插件并重启 plugin_loader。sudo 口令从 stdin 读。
# 用法(设备上):bash install.sh <stage 目录> <插件名>
set -euo pipefail
stage=$1
name=$2
dest="$HOME/homebrew/plugins/$name"
case "$stage" in /tmp/decky-tools.*) ;; *) echo "unexpected stage dir" >&2; exit 1 ;; esac

rm -f "$stage/plugin/deploy-remote.sh"
touch "$stage/plugin/dev_mode"
sudo -S -p '' bash -c '
  set -euo pipefail
  rm -rf -- "$2"
  mv -- "$1" "$2"
  chown -R root:root "$2"
  systemctl restart plugin_loader
' _ "$stage/plugin" "$dest"

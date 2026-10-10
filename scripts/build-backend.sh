#!/usr/bin/env bash
# 本机构建 Zig 子进程到 bin/(侧载用;release 由 Decky CLI 经 backend/Dockerfile 构建)。
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(zig version)" == 0.16.* ]] || { echo "需要 Zig 0.16.x" >&2; exit 2; }
(cd backend && zig build test && zig build -Doptimize=ReleaseSmall)
out=backend/zig-out/bin/dt-monitor
# 必须是无动态依赖、无解释器的静态 x86-64 ELF,才能在任意 SteamOS 上直接运行
if readelf -d "$out" 2>/dev/null | grep -q NEEDED || readelf -l "$out" | grep -q INTERP; then
  echo "dt-monitor 不是静态可执行文件" >&2; exit 1
fi
install -D -m 755 "$out" bin/dt-monitor
echo "built bin/dt-monitor ($(stat -c %s bin/dt-monitor) bytes)"

#!/bin/sh
# 在 Decky CLI 的后端容器里运行:测试并构建 dt-monitor,产物写到 /backend/out(→ 插件 bin/)。
# 缓存放 /tmp,不污染挂载进来的源码目录;容器可能以非 root 用户运行。
set -eu
cd /backend
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-global-cache
zig build test --cache-dir /tmp/zig-cache
zig build -Doptimize=ReleaseSmall --cache-dir /tmp/zig-cache --prefix /tmp/zig-out
install -m 755 /tmp/zig-out/bin/dt-monitor /backend/out/dt-monitor
echo "built dt-monitor"

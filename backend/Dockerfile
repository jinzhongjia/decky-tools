# Decky CLI 自定义后端构建镜像:`decky plugin build` 会 docker build 本文件,
# 再以 /backend(本目录)与 /backend/out(→ 插件 zip 的 bin/)挂载运行 entrypoint.sh。
# 基础镜像与 Zig 工具链都按摘要固定。
FROM ghcr.io/steamdeckhomebrew/builder@sha256:03c1850fba3ed0f1f74828f64e8a103c11fbddc3273406affa893a977a10d28f

ARG ZIG_VERSION=0.17.0
ARG ZIG_SHA256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026

RUN apk add --no-cache xz \
 && wget -q -O /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
 && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
 && mkdir -p /opt/zig \
 && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
 && rm /tmp/zig.tar.xz \
 && ln -s /opt/zig/zig /usr/local/bin/zig

ENTRYPOINT ["/backend/entrypoint.sh"]

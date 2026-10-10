# Decky Tools

SteamOS 游戏模式下的工具箱插件(基于 [Decky Loader](https://github.com/SteamDeckHomebrew/decky-loader)),
在右侧快捷菜单(QAM)中使用。

## 功能

### Proton 运行时

- 浏览并一键安装 **GE-Proton**、**Proton-CachyOS** 的发布版本
- 自动选择适合本机的构建:跳过 aarch64 包;CPU 支持 x86-64-v3(如 Steam Deck)时优先 CachyOS 的 v3 优化版
- 下载进度、可取消、断点续传,sha512 校验后安全解压到 `compatibilitytools.d`
- 管理已安装的兼容层:卸载、标记架构不符的版本
- 安装/卸载后一键重启 Steam 使其生效
- 可选 GitHub 下载镜像前缀(设置页)

后续会陆续加入更多工具。

## 安装

在 Decky 开发者模式中从 [Releases](https://github.com/jinzhongjia/decky-tools/releases) 下载 `Decky Tools.zip` 安装。

## 开发

见 [AGENTS.md](AGENTS.md)。

```bash
pnpm install && pnpm build
pnpm test:py
DECK_HOST=deck@<ip> DECK_PASS=<sudo 口令> bash scripts/deploy.sh
```

## License

MIT

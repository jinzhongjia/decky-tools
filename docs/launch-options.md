# 启动参数预设(规划中,未实现)

> 状态:调研完成,暂缓实现。本文记录调研结论与设计草案,开工前先复核下文「待确认」与各选项的时效性。
> 调研日期:2026-10-10。设备实测:Steam Deck OLED(Galileo),SteamOS 20260922.1,内核 6.18.50-valve2,Mesa 26.1.2。

## 目标

在 QAM 新增「启动参数」工具:为单个游戏勾选常用启动参数 / 环境变量,自主搭配后写入该游戏的 Steam 启动选项;
支持把一组勾选保存为预设,一键套用到其它游戏。所有条目可十字键操作。

## 已验证的技术路径

Steam 前端(SharedJSContext)可直接读写,无需 root、无需后端参与:

| 用途 | API | 实测 |
|---|---|---|
| 已安装游戏列表 | `collectionStore.localGamesCollection.allApps`(`appid`、`display_name`、`app_type`、`rt_last_time_played_or_installed`) | 33 款均可取到 |
| 读取启动参数 / 当前兼容层 | `SteamClient.Apps.RegisterForAppDetails(appid, cb)` → `strLaunchOptions`、`strCompatToolName`、`strCompatToolDisplayName`(回调后立即 `unregister()`) | 可用;原生 Linux 游戏的兼容层为 `steamlinuxruntime` |
| 写入启动参数 | `SteamClient.Apps.SetAppLaunchOptions(appid, string)`;非 Steam 游戏用 `SetShortcutLaunchOptions` | Balatro 写入 `DT_TEST=1 %command%` 后读回一致,并已恢复为空 |

注意:`GetLaunchOptionsForApp` 返回的是游戏自带的启动项配置,不是用户启动参数。

设备环境核实:
- `/dev/ntsync` 存在,内核支持 NTSync。
- 游戏模式下只有 `GAMESCOPE_WAYLAND_DISPLAY`,没有 `WAYLAND_DISPLAY` → Proton 的 Wayland 开关在游戏模式不生效。
- 系统含 `ja_JP.utf8`、`zh_CN.utf8`、`en_US.utf8` locale。
- `STEAM_GAMESCOPE_HDR_SUPPORTED=1`(OLED)。
- `mangohud`、`gamemoderun`、`gamescope` 二进制都存在,但不建议在游戏模式使用(见下文)。

## 参数目录

写法约定:环境变量放在 `%command%` 之前,游戏参数放在之后,如 `PROTON_LOG=1 %command% -skipintro`。
「适用」列:V = Valve Proton 10/11,GE = GE-Proton 10/11,C = Proton-CachyOS 11。

### 兼容性(崩溃、黑屏、卡死时尝试)

| 选项 | 写法 | 作用 | 适用 | 备注 |
|---|---|---|---|---|
| 关闭 NTSync | `PROTON_NO_NTSYNC=1` | NTSync 默认开启,个别游戏卡死时关闭 | V11, GE | 排障用 |
| 关闭 fsync | `PROTON_NO_FSYNC=1` | 卡死 / 死锁时回退 | V, GE, C | 排障用 |
| 使用 WineD3D | `PROTON_USE_WINED3D=1` | 改用 OpenGL 渲染 d3d9/10/11 | V, GE, C | 很慢,仅渲染错误兜底 |
| 禁用 D3D11 / D3D10 | `PROTON_NO_D3D11=1` / `PROTON_NO_D3D10=1` | 强制回退 d3d9 | V, GE, C | |
| D3D8 走 DXVK | `PROTON_DXVK_D3D8=1` | 老游戏 d3d8 | V, C | |
| 堆延迟释放 | `PROTON_HEAP_DELAY_FREE=1` | 修复 use-after-free 类崩溃 | V, GE, C | |
| 旧版 GL 字符串 | `PROTON_OLD_GL_STRING=1` | 修复老 OpenGL 游戏崩溃 | V, GE, C | |
| 隐藏 Deck GPU | `PROTON_HIDE_VANGOGH_GPU=1` | 对识别 Deck GPU 后异常的游戏伪装 | V10/11(脚本中有,README 未写) | 伪装成的具体型号未核实 |
| 游戏盘 S: | `PROTON_SET_GAME_DRIVE=1` | 为库目录挂 S: 盘 | V, GE, C | 少数游戏需要 |
| Xalia 手柄界面 | `PROTON_USE_XALIA=0` / `=1` | 关闭 / 强制启动器的手柄辅助界面 | V, GE, C | |

### 视频 / 媒体(过场动画异常)

| 选项 | 写法 | 作用 | 适用 |
|---|---|---|---|
| 修复粉屏视频 | `WINE_DO_NOT_CREATE_DXGI_DEVICE_MANAGER=1` | 视频偏粉、花屏 | V, GE, C |
| 强制 GStreamer | `PROTON_MEDIA_FORCE_GST=1` | 过场无画面或无声 | **仅 C** |

### 区域(乱码、日文游戏)

| 选项 | 写法 | 作用 |
|---|---|---|
| 日文区域 | `HOST_LC_ALL=ja_JP.UTF-8` | 修复日文游戏乱码 / 报错 |
| 简体中文区域 | `HOST_LC_ALL=zh_CN.UTF-8` | 中文游戏同理 |

必须用 `HOST_LC_ALL`:Steam 会把 `LC_ALL` 设成 `C`,Proton 再把 `HOST_LC_ALL` 映射为 `LC_ALL`。

### 画面与性能

| 选项 | 写法 | 作用 | 适用 | 备注 |
|---|---|---|---|---|
| 以桌面模式运行 | `SteamDeck=0` | 游戏与 DXVK 不再按 Deck 调优,常用于解锁完整画质设置或键鼠图标 | 全部 | 会失去 Deck 专用调优 |
| 强制光追 | `VKD3D_CONFIG=dxr` | 给必须光追的 D3D12 游戏 | V, GE, C | 与下一项互斥;Deck 上很慢 |
| 关闭光追 | `VKD3D_CONFIG=nodxr` | | V, GE, C | |
| DXVK 限帧 | `DXVK_CONFIG="dxgi.maxFrameRate=N"`(D3D9 用 `d3d9.maxFrameRate`) | 高帧率物理异常的游戏 | V, GE, C | 平时用 QAM 自带限帧 |
| D3D12 限帧 | `VKD3D_FRAME_RATE=N` | 同上,D3D12 | V, GE, C | |
| FSR4 升级(实验) | `PROTON_FSR4_UPGRADE=1` | FSR 3.1 游戏升级到 FSR4 | GE, C | Deck 为 RDNA2,效果未验证 |
| HDR | `DXVK_HDR=1`(GE 也认 `PROTON_ENABLE_HDR=1`) | 向游戏暴露 HDR10 | 全部 | 仅 OLED;Steam 是否已自动设置待确认 |
| 独立着色器缓存 | `PROTON_LOCAL_SHADER_CACHE=1` | 按游戏单独缓存 | 仅 C | |

### 调试

| 选项 | 写法 | 作用 | 备注 |
|---|---|---|---|
| Proton 日志 | `PROTON_LOG=1`(也可写通道,如 `+mfplat,+quartz`) | 写入 `~/steam-<appid>.log` | 反馈问题用,注意日志体积 |
| DXVK HUD | `DXVK_HUD=fps,frametimes,compiler` | 帧时间、着色器编译 | 仅 D3D9–11 |
| DXVK 日志级别 | `DXVK_LOG_LEVEL=none\|error\|warn\|info\|debug` | | |

### 游戏自带参数

`-skipintro`、`-dx11`、`-windowed` 等因游戏而异,提供自由输入框,放在 `%command%` 之后。

## 不收录

| 参数 | 原因 |
|---|---|
| `DXVK_ASYNC=1` | 从未进入上游 DXVK,当前版本不存在;现代 DXVK 用 GPL 减少卡顿 |
| `DXVK_FRAME_RATE` | 已从 DXVK 移除 |
| `PROTON_USE_NTSYNC=1` | Valve / GE 脚本不读取;NTSync 已默认开启 |
| `PROTON_NO_ESYNC` | Proton 11 已废弃 |
| `mangohud %command%`、`MANGOHUD_CONFIG` | gamescope 下不支持;QAM 性能叠加层本身就是 mangoapp |
| `gamemoderun` | SteamOS 自行管理功耗与调度 |
| 游戏模式内嵌套 `gamescope -- %command%` | 第二层合成器会破坏叠加层与输入、增加延迟 |
| `PROTON_ENABLE_WAYLAND` / `PROTON_USE_WAYLAND` | 游戏模式无 `WAYLAND_DISPLAY`,不生效 |
| `PROTON_ENABLE_NVAPI`、`PROTON_DLSS_*`、`PROTON_HIDE_NVIDIA_GPU` | 仅 NVIDIA |
| `PROTON_FORCE_LARGE_ADDRESS_AWARE` | 已默认开启 |
| `WINE_FULLSCREEN_FSR*`、`WINE_FULLSCREEN_INTEGER_SCALING` | 与 gamescope 自带缩放重复 |
| `PROTON_USE_SECCOMP`、`PROTON_USE_D9VK`、`PROTON_FSR4_RDNA3_UPGRADE`、`PROTON_ENABLE_MEDIACONV`、`PROTON_MEDIA_USE_GST`、`PROTON_VKD3D_HEAP` | 已废弃 / 官方标注勿用 |
| `RADV_PERFTEST=*` | 实验性驱动开关,无可靠推荐值 |

## 设计草案

- **入口**:QAM 新工具「启动参数」。先列最近玩过的游戏,可浏览全部已安装游戏,显示当前兼容层。
- **编辑页**:按分类逐项开关(`ToggleField`),限帧数值、区域用下拉;底部实时预览最终字符串,确认后「应用」。全部可十字键操作。
- **不覆盖用户内容**:解析现有字符串为「环境变量 / 包装命令 / `%command%` / 游戏参数」四段,插件只增删目录中认得的项,其余原样保留在原位置;原字符串没有 `%command%` 时,视为整串都是游戏参数(Steam 的旧语义)。
- **按游戏过滤**:兼容层为 `steamlinuxruntime`(原生 Linux)时隐藏 Proton 专用选项;某选项仅部分 Proton 版本支持时标注。
- **互斥**:`VKD3D_CONFIG=dxr` 与 `nodxr`、两种区域等同组只能选一个。
- **预设**:一组勾选可保存为命名预设(存后端配置 `launch` 命名空间),一键套用到其它游戏。
- **分层**(遵循「前端完全受后端控制」):参数目录、现有字符串的解析与拼接、互斥规则、按兼容层过滤、预设持久化全部在后端,配单测。
  前端只做两件只有 Steam 前端能做的事:把游戏列表与当前启动参数 / 兼容层上报给后端;按后端下令把算好的字符串写入
  `SetAppLaunchOptions`(经 `core/command`,命令需带参数)。界面渲染后端快照,文案按选项 id 本地化。

## 待确认

- Steam 在 OLED 开启 HDR 时是否已自动设置 `DXVK_HDR`。
- `PROTON_HIDE_VANGOGH_GPU` 伪装成的 GPU 型号,以及 GE / CachyOS 是否继承。
- `HOST_LC_ALL` 指定的 locale 在 pressure-vessel 运行时容器内是否都可用(宿主机已确认存在)。
- FSR4 在 RDNA2 上的实际表现。
- `PROTON_COMPAT_CONFIG=noforcelgadd` 能否经启动参数传入(README 写法,未实测)。

## 资料来源

- Valve Proton README 与 `proton` 脚本(proton_10.0 / proton_11.0 / bleeding-edge):https://github.com/ValveSoftware/Proton
- GE-Proton README 与 `proton` 脚本(GE-Proton11-7):https://github.com/GloriousEggroll/proton-ge-custom
- Proton-CachyOS README 与 CHANGELOG(11.0-20261005):https://github.com/CachyOS/proton-cachyos
- DXVK README、dxvk.conf 与源码(v3.1.1):https://github.com/doitsujin/dxvk
- VKD3D-Proton README:https://github.com/HansKristian-Work/vkd3d-proton
- MangoHud README(gamescope 部分):https://github.com/flightlessmango/MangoHud

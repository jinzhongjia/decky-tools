# AGENTS.md

Decky Tools:SteamOS 游戏模式(Decky Loader)工具箱插件。当前工具:Proton 运行时下载管理、系统监控。
只有右侧 QAM 面板,**不做大屏页**。

参考:
- https://github.com/SteamDeckHomebrew/decky-loader —— 插件宿主 / API 来源(`decky` 模块、`@decky/api`、`@decky/ui`)
- 姊妹项目 decky-music —— 同作者,QAM 布局与工程约定的来源
- 姊妹项目 decky-scope —— 系统监控的 Zig 采样逻辑来源(本项目只取 CPU/GPU/内存/功耗/电池/IP 的精简子集)

## 架构

```
QAM (React)  ── callable("call", tool, method, params) ──▶  main.py ─▶ core.App
     ▲                                                            │ 按 tool 分发到 Tool 子类的 @rpc 方法
     └──────── decky.emit("decky_tools_event", {tool,type,data}) ◀┘
```

- **前端完全受后端控制**:状态与业务判断只在后端。后端持有每个工具的完整界面快照,
  经 RPC 返回、经 `view` 事件推送;前端只做三件事——渲染快照、把用户操作发回后端、把错误码/通知 key 本地化。
  前端可以保留的本地状态仅限纯展示(列表折叠、焦点等)。
  - 通知:工具调用 `ctx.notify(key, params)`,后端排队并推 `core/notify`;前端显示后 `core.ack`。
    前端不在线时(切换桌面/游戏模式、Steam 重启)留在队列,重新加载后经 `core.notifications` 补发,不会重复。
  - 只有 Steam 前端能做的动作(重启 Steam、读写游戏启动参数等):后端经 `ctx.command(name)` 下令,
    `src/core/commands.ts` 按白名单执行,前端不自行决定何时执行。
- 需要原生能力的工具用 **Zig 子进程**:源码在 `backend/`(Zig 0.17,无 libc、静态链接),产物 `bin/<name>`;
  由 `core/child.py` 拉起,stdin 写命令行、stdout 读 NDJSON,stdin 关闭即退出。
- **一个 RPC、一个事件**。前端只调 `call(tool, method, params)`,返回信封
  `{ok:true,data}` / `{ok:false,error:<code>}`;后端只发 `decky_tools_event`。新增功能不改 `main.py`。
- `py_modules/deckytools/core/` —— 内核:`app.py`(装配 + 分发 + 错误信封 + `core` 工具:任务/全局选项)、
  `tool.py`(`Tool` 基类、`@rpc`、`Context`:配置/任务/通知/命令)、`tasks.py`(后台任务:进度/阶段/取消/去重,回调给发起工具)、
  `notify.py`(通知队列与确认)、
  `net.py`(urllib + certifi、下载续传、GitHub 镜像前缀)、`settings.py`(按工具命名空间的 JSON 配置)、
  `runtime.py`(隔离 `decky` 模块,单测时退化)、`log.py`、`errors.py`(稳定错误码)。
- `py_modules/deckytools/tools/<id>/` —— 各工具。`proton/`:`sources.py`(数据驱动的发行源)、
  `compat.py`(compatibilitytools.d 列表/安全解压/卸载)、`installer.py`(空间检查→下载→sha512→解压)、
  `cpu.py`(x86-64-v3 探测)、`steam.py`(读 /proc 判断 Steam 是否已重启)、`tool.py`(RPC + 界面快照)。
  `monitor/tool.py`:守护 `dt-monitor` 子进程(插件加载期间常驻;等待退出事件后按指数退避重启,不轮询);
  租约用定时器实现(前端每 5s `watch()` 续租,15s 无续租即 `live off`);子进程每秒推来的快照行原样透传(见下方性能约定)。
- `backend/` —— Zig 子进程 `dt-monitor`:`apu.zig`(AMD APU gpu_metrics 解析)、`sensors.zig`(apu 模式 / 通用 sysfs 模式)、
  `battery.zig`(电池读数节流 + uevent 驱动的 status)、`sampler.zig`(CPU 占用差分、内存)、`history.zig`(按 tick 序号预聚合的环形桶,
  2 分钟 × 1 秒、30 分钟 × 10 秒,纯内存)、`view.zig`(每秒的完整快照 JSON)、`out.zig`(非阻塞 stdout 整行队列)、
  `netinfo.zig`(rtnetlink 选推荐 IP)、`sysinfo.zig`(主机名/系统/内核/机型)、`main.zig`(epoll 事件循环、调度提示与 stdio 协议)。
  `Dockerfile` + `entrypoint.sh` 供 Decky CLI 在 release 打包时构建进 zip 的 `bin/`。
- `src/core/` —— 前端内核:`api.ts`(唯一接口层:`invoke` / `onToolEvent`)、`commands.ts`(执行后端下令的 Steam 动作)、
  `store.ts`(跨 QAM 重挂保留状态的模块级 store)、`errors.ts`(错误总线 + `guard`)、`i18n.ts`、`registry.ts`(`ToolDef`)。
- `src/ui/` —— 通用组件:`notifications.ts`(显示后端通知并确认)、`Hub`(工具列表 ⇄ 工具面板 ⇄ 设置)、`ActionRow`、`LineChart`(SVG 折线图)、`MetricCard`(可聚焦指标卡)、`InfoRow`、`TaskProgress`(`TaskRow`)、`Badge`、`ErrorBanner`、`Boundary`、`Footer`、`Settings`。
- `src/tools/<id>/` —— 各工具前端,`index.tsx` 导出 `ToolDef`,在 `src/tools/index.ts` 注册。

### 新增一个工具

1. 后端:`py_modules/deckytools/tools/<id>/`,写 `Tool` 子类(`id = "<id>"`),对外方法加 `@rpc`;
   提供 `view()` 返回完整界面快照,状态变化时 `ctx.emit("view", snapshot)`;操作类 RPC 返回最新快照。
   耗时操作用 `self.ctx.start_task(kind, key, title, body, on_change=...)`,body 内阻塞工作放 `asyncio.to_thread`,
   线程里调 `handle.check()` / `handle.progress()`;进行中任务经 `ctx.task_snapshot(key)` 放进快照。
   需要提示用户时 `ctx.notify(key, params)`。加入 `tools/__init__.py` 的 `TOOLS`。
2. 前端:`src/tools/<id>/`,`api.ts` 声明接口与快照类型,`state.ts` 只存快照,组件只渲染;
   `strings.ts` 用 `defineStrings` 写中英文案,`index.tsx` 导出 `ToolDef`(含通知文案 `message`),加入 `src/tools/index.ts`。
3. 后端方法与前端 `api.ts` 是同一契约的两端,**同一次改动里同步修改**。

## 规划文档

- `docs/launch-options.md` —— 启动参数预设(已调研,暂缓实现):参数目录、已验证的 Steam API、设计草案与待确认项。

## Coding rules

- 单文件不超过 500 行,函数不超过 50 行。
- i18n:中文 + 英文,文案按工具放各自 `strings.ts`;错误码文案在 `src/core/i18n.ts`。
- 后端跑在 Decky 冻结的 CPython 3.11 里,**只能用 stdlib**(certifi/lzma 由宿主运行时提供,`net.py` 已兜底)。
- 后端子进程如需调用系统命令,必须清空 `LD_LIBRARY_PATH`(冻结运行时会注入自己的库路径);`core/child.py` 已处理。
- Zig 代码禁止 `linkLibC()` / `@cImport`;传感器按能力探测,读不到就省略该字段,不得用 0 冒充;不读取 MAC、序列号、SSID 等隐私信息。
- 失败一律抛 `ToolError(code)`,code 需在 `src/core/i18n.ts` 有中英文案;第三方原始错误不透给 UI。
- 解压不可信归档必须逐成员校验(见 `compat._check_member`),不得直接 `extractall`。
- QAM 内所有展示条目都要能用十字键聚焦(`Focusable` / `Field focusable`),不能只支持触屏。
- 代码里用 `ponytail:` 注释标记刻意的简化 / 延后项及其升级路径。

## 性能约定(Steam Deck 实测,详见 git log 中的 Zig 0.17 优化提交)

后台常驻的代码按"每秒都在付出"来写。设备上每次读取的 CPU 开销(Steam Deck OLED,1 秒间隔):

| 数据源 | CPU | 说明 |
|---|---|---|
| amdgpu `gpu_metrics` | ~350 µs | SMU 固件往返,驱动忙等;一次拿到 GPU/CPU 频率温度与功耗,替代下面多项 |
| 电池属性(缓存过期后首读) | ~340 µs | ACPI `_BST`,内核缓存 1 秒;为保证电量与功率是当前值,仍每秒读 |
| 电池 `status`(放电时) | ~400 µs + 阻塞 1 ms | 额外查询交流适配器 `_PSR`;只在 uevent / 启动 / 每分钟读 |
| ACPI 温度区 `acpitz` | ~200 µs | 每次求值 ACPI 方法;APU 上改用 gpu_metrics 的核心温度 |
| `/proc/stat` | ~64 µs | 内核每次完整生成;只读首行 |
| `/proc/meminfo` | ~25 µs | 同上 |
| 单个普通 sysfs 属性 | ~3 µs | 系统调用本身(含 Zen 2 缓解措施)约 5 µs |

- 新增数据源先在真机上量开销(含 1 秒间隔下的固件/ACPI 缓存行为),再决定读取频率。
- 高频数据(≥ 1 Hz)由生产者(Zig)直接生成最终 JSON,Python 与 Decky loader 只透传字符串,不解析成对象再序列化;
  低频的 RPC / 事件照常用结构化数据。
- 高频负载尽量小:图表序列输出整数(48 像素高的图分辨不出 0.1%),续租心跳不重复传快照。
- 空闲路径不得有定时轮询:子进程守护等待退出事件,租约用 `call_later`。
- 后台采样进程设 `SCHED_BATCH` + nice 10 与 50 ms 定时器松弛,不抢占游戏线程,唤醒可与其它定时器合并。

## Logging rules

- 复用 `decky.logger`,格式 `[scope] where: msg`;英文;插件目录有 `dev_mode` 标记(侧载部署时创建)时开 DEBUG。
- 日志不得含密钥、cookie、带签名参数的完整 URL(`net.py` 只记主机名)。
- 日志位置:设备上 `~/homebrew/logs/Decky Tools/`,每次 plugin_loader 重启一个文件。

## Dev environment

```bash
pnpm install
pnpm build                     # 前端 → dist/
pnpm lint                      # tsc --noEmit + prettier --check;pnpm format 自动格式化
pnpm test:py                   # 后端单测(stdlib unittest)
bash scripts/build-backend.sh  # Zig 0.17 单测 + 构建 bin/dt-monitor(deploy.sh 会自动调用)
DECK_HOST=deck@<ip> DECK_PASS=<sudo 口令> bash scripts/deploy.sh   # 构建并侧载到设备,重启 plugin_loader
bash scripts/decky-build.sh    # 官方 Decky CLI 打 release zip → out/(默认 sudo + Docker;
                               # 无 sudo:DECKY_BUILD_SUDO=0 bash scripts/decky-build.sh --build-as-root)
```

- 重启 plugin_loader 时 Decky 会同时重启 steamwebhelper,这是宿主行为,不是插件崩溃。
- 真机调试(CDP 驱动 Steam UI、截图、拉日志、防休眠)参考 decky-music 的 `decky-dev` / `steam-cdp` skill。
- 新兼容层需重启 Steam 才会出现在游戏兼容性设置中(面板提供“立即重启 Steam”,调用 `SteamClient.User.StartRestart`)。

## Commit messages

- Conventional Commits:`<type>(<scope>): <subject>`,中文。
- 修改较多时按作用拆分多个 commit。
* 不带有任何 LLM 信息。

## Agent behavior

- 仅在明确要求时才 `git commit` / `git push`。
- 重新部署到真机前需征得用户同意。
- 禁止把密钥、口令写入代码或文档,使用环境变量。

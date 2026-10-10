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

- 需要原生能力的工具用 **Zig 子进程**:源码在 `backend/`(Zig 0.16,无 libc、静态链接),产物 `bin/<name>`;
  由 `core/child.py` 拉起,stdin 写命令行、stdout 读 NDJSON,stdin 关闭即退出。
- **一个 RPC、一个事件**。前端只调 `call(tool, method, params)`,返回信封
  `{ok:true,data}` / `{ok:false,error:<code>}`;后端只发 `decky_tools_event`。新增功能不改 `main.py`。
- `py_modules/deckytools/core/` —— 内核:`app.py`(装配 + 分发 + 错误信封 + `core` 工具:任务/全局选项)、
  `tool.py`(`Tool` 基类、`@rpc`、`Context`)、`tasks.py`(后台任务:进度/阶段/取消/去重,事件推送)、
  `net.py`(urllib + certifi、下载续传、GitHub 镜像前缀)、`settings.py`(按工具命名空间的 JSON 配置)、
  `runtime.py`(隔离 `decky` 模块,单测时退化)、`log.py`、`errors.py`(稳定错误码)。
- `py_modules/deckytools/tools/<id>/` —— 各工具。`proton/`:`sources.py`(数据驱动的发行源)、
  `compat.py`(compatibilitytools.d 列表/安全解压/卸载)、`installer.py`(空间检查→下载→sha512→解压)、
  `cpu.py`(x86-64-v3 探测)、`tool.py`(RPC)。
  `monitor/tool.py`:守护 `dt-monitor` 子进程(插件加载期间常驻,崩溃指数退避重启);实时推送按租约开关(前端每 5s `watch()` 续租,15s 无续租即 `live off`),历史经 `history(window)` 向子进程查询。
- `backend/` —— Zig 子进程 `dt-monitor`:`sensors.zig`(按能力探测 hwmon/drm/power_supply)、`sampler.zig`(CPU 占用差分、内存 + 读数)、`history.zig`(30 分钟纯内存环形缓冲,按时间分桶求均值,不落盘)、
  `netinfo.zig`(rtnetlink 同步 dump 选推荐 IP)、`sysinfo.zig`(主机名/系统/内核/机型)、`main.zig`(timerfd + epoll 事件循环与 stdio 协议)。
  `Dockerfile` + `entrypoint.sh` 供 Decky CLI 在 release 打包时构建进 zip 的 `bin/`。
- `src/core/` —— 前端内核:`api.ts`(唯一接口层:`invoke` / `onToolEvent`)、`tasks.ts`(任务镜像)、
  `store.ts`(跨 QAM 重挂保留状态的模块级 store)、`errors.ts`(错误总线 + `guard`)、`i18n.ts`、`registry.ts`(`ToolDef`)。
- `src/ui/` —— 通用组件:`Hub`(工具列表 ⇄ 工具面板 ⇄ 设置)、`ActionRow`、`LineChart`(SVG 折线图)、`MetricCard`(可聚焦指标卡)、`InfoRow`、`TaskProgress`(`TaskRow`)、`Badge`、`ErrorBanner`、`Boundary`、`Footer`、`Settings`。
- `src/tools/<id>/` —— 各工具前端,`index.tsx` 导出 `ToolDef`,在 `src/tools/index.ts` 注册。

### 新增一个工具

1. 后端:`py_modules/deckytools/tools/<id>/`,写 `Tool` 子类(`id = "<id>"`),对外方法加 `@rpc`;
   耗时操作用 `self.ctx.start_task(kind, key, title, body)`,body 内阻塞工作放 `asyncio.to_thread`,
   线程里调 `handle.check()` / `handle.progress()`。加入 `tools/__init__.py` 的 `TOOLS`。
2. 前端:`src/tools/<id>/`,`api.ts` 用 `invoke(TOOL, method, params)` 声明接口,
   `strings.ts` 用 `defineStrings` 写中英文案,`index.tsx` 导出 `ToolDef`,加入 `src/tools/index.ts`。
3. 后端方法与前端 `api.ts` 是同一契约的两端,**同一次改动里同步修改**。

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
bash scripts/build-backend.sh  # Zig 0.16 单测 + 构建 bin/dt-monitor(deploy.sh 会自动调用)
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

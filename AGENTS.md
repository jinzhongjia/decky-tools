# AGENTS.md

Decky Tools:SteamOS 游戏模式(Decky Loader)工具箱插件。当前工具:Proton 运行时下载管理。
只有右侧 QAM 面板,**不做大屏页**。

参考:
- https://github.com/SteamDeckHomebrew/decky-loader —— 插件宿主 / API 来源(`decky` 模块、`@decky/api`、`@decky/ui`)
- 姊妹项目 decky-music —— 同作者,QAM 布局与工程约定的来源

## 架构

```
QAM (React)  ── callable("call", tool, method, params) ──▶  main.py ─▶ core.App
     ▲                                                            │ 按 tool 分发到 Tool 子类的 @rpc 方法
     └──────── decky.emit("decky_tools_event", {tool,type,data}) ◀┘
```

- **一个 RPC、一个事件**。前端只调 `call(tool, method, params)`,返回信封
  `{ok:true,data}` / `{ok:false,error:<code>}`;后端只发 `decky_tools_event`。新增功能不改 `main.py`。
- `py_modules/deckytools/core/` —— 内核:`app.py`(装配 + 分发 + 错误信封 + `core` 工具:任务/全局选项)、
  `tool.py`(`Tool` 基类、`@rpc`、`Context`)、`tasks.py`(后台任务:进度/阶段/取消/去重,事件推送)、
  `net.py`(urllib + certifi、下载续传、GitHub 镜像前缀)、`settings.py`(按工具命名空间的 JSON 配置)、
  `runtime.py`(隔离 `decky` 模块,单测时退化)、`log.py`、`errors.py`(稳定错误码)。
- `py_modules/deckytools/tools/<id>/` —— 各工具。`proton/`:`sources.py`(数据驱动的发行源)、
  `compat.py`(compatibilitytools.d 列表/安全解压/卸载)、`installer.py`(空间检查→下载→sha512→解压)、
  `cpu.py`(x86-64-v3 探测)、`tool.py`(RPC)。
- `src/core/` —— 前端内核:`api.ts`(唯一接口层:`invoke` / `onToolEvent`)、`tasks.ts`(任务镜像)、
  `store.ts`(跨 QAM 重挂保留状态的模块级 store)、`errors.ts`(错误总线 + `guard`)、`i18n.ts`、`registry.ts`(`ToolDef`)。
- `src/ui/` —— 通用组件:`Hub`(工具列表 ⇄ 工具面板 ⇄ 设置)、`ActionRow`、`TaskProgress`(`TaskRow`)、`Badge`、`ErrorBanner`、`Boundary`、`Footer`、`Settings`。
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
- 后端子进程如需调用系统命令,必须清空 `LD_LIBRARY_PATH`(冻结运行时会注入自己的库路径)。
- 失败一律抛 `ToolError(code)`,code 需在 `src/core/i18n.ts` 有中英文案;第三方原始错误不透给 UI。
- 解压不可信归档必须逐成员校验(见 `compat._check_member`),不得直接 `extractall`。
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

## Agent behavior

- 仅在明确要求时才 `git commit` / `git push`。
- 重新部署到真机前需征得用户同意。
- 禁止把密钥、口令写入代码或文档,使用环境变量。

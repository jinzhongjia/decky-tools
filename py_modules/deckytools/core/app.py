"""插件门面:装配工具、按 (tool, method) 分发 RPC、统一错误信封。

前端 → `call(tool, method, params)` → `{"ok": true, "data": ...}` 或 `{"ok": false, "error": code}`。
"""

import asyncio
import inspect
from typing import Any

from . import runtime
from .errors import INTERNAL, INVALID_REQUEST, UNKNOWN_METHOD, UNKNOWN_TOOL, ToolError
from .log import Logger
from .settings import SettingsStore
from .tasks import TaskManager
from .tool import EVENT, Context, Tool, rpc

_log = Logger("core")
CORE = "core"


def _mirror_ok(v: Any) -> bool:
    if not isinstance(v, str) or len(v) > 200:
        return False
    v = v.strip()
    return not v or (v.startswith(("https://", "http://")) and not any(c.isspace() for c in v))


# 全局选项白名单:key → 校验函数
CORE_OPTIONS = {"github_mirror": _mirror_ok}


class CoreTool(Tool):
    """内核自身也以工具形式暴露:任务与全局配置。"""

    id = CORE

    def __init__(self, ctx: Context, app: "App"):
        super().__init__(ctx)
        self._app = app

    @rpc
    async def tools(self) -> list[str]:
        return [t for t in self._app.tools if t != CORE]

    @rpc
    async def tasks(self) -> list[dict[str, Any]]:
        return self._app.tasks.list()

    @rpc
    async def cancel_task(self, id: str) -> bool:
        return self._app.tasks.cancel(id)

    @rpc
    async def get_options(self) -> dict[str, Any]:
        return {"github_mirror": "", **self.ctx.settings.all()}

    @rpc
    async def set_option(self, key: str, value: Any) -> None:
        check = CORE_OPTIONS.get(key)
        if not check or not check(value):
            raise ToolError(INVALID_REQUEST, f"bad option {key}")
        self.ctx.settings.set(key, value.strip() if isinstance(value, str) else value)


class App:
    def __init__(self, tool_classes: list[type[Tool]], settings: SettingsStore | None = None):
        self.settings = settings or SettingsStore()
        self.tasks = TaskManager(self._emit_task)
        self.tools: dict[str, Tool] = {CORE: CoreTool(self._ctx(CORE), self)}
        for cls in tool_classes:
            self.tools[cls.id] = cls(self._ctx(cls.id))
        self._methods = {tid: tool.methods() for tid, tool in self.tools.items()}

    def _ctx(self, tool_id: str) -> Context:
        return Context(tool_id, self.settings.scoped(tool_id), self.tasks, self.settings.scoped(CORE))

    async def _emit_task(self, task: dict[str, Any]) -> None:
        await runtime.emit(EVENT, {"tool": CORE, "type": "task", "data": task})

    async def start(self) -> None:
        for tool in self.tools.values():
            try:
                await tool.start()
            except Exception as e:  # noqa: BLE001 —— 单个工具失败不影响其它工具
                _log.error("start", f"tool {tool.id} failed to start: {type(e).__name__}: {e}")
        _log.info("start", f"loaded tools: {', '.join(self.tools)}")

    async def stop(self) -> None:
        await self.tasks.shutdown()
        for tool in self.tools.values():
            try:
                await tool.stop()
            except Exception as e:  # noqa: BLE001
                _log.warn("stop", f"tool {tool.id} stop failed: {type(e).__name__}")

    async def call(self, tool: str, method: str, params: Any = None) -> dict[str, Any]:
        try:
            fn = self._resolve(tool, method)
            if params is not None and not isinstance(params, dict):
                raise ToolError(INVALID_REQUEST, "params must be an object")
            try:
                inspect.signature(fn).bind(**(params or {}))
            except TypeError:
                raise ToolError(INVALID_REQUEST, f"bad params for {tool}.{method}") from None
            data = await fn(**(params or {}))
            return {"ok": True, "data": data}
        except ToolError as e:
            _log.warn("call", f"{tool}.{method} -> {e}")
            return {"ok": False, "error": e.code}
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001 —— 未知异常不外抛原文
            _log.error("call", f"{tool}.{method} crashed: {type(e).__name__}: {e}")
            return {"ok": False, "error": INTERNAL}

    def _resolve(self, tool: str, method: str):
        if tool not in self._methods:
            raise ToolError(UNKNOWN_TOOL, str(tool)[:40])
        fn = self._methods[tool].get(method)
        if not fn:
            raise ToolError(UNKNOWN_METHOD, f"{tool}.{str(method)[:40]}")
        return fn

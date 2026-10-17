"""工具抽象:每个功能(Proton 下载、后续其它工具)实现一个 Tool 子类并在 tools/__init__.py 注册。

工具只通过 Context 访问内核能力(配置、任务、事件、日志、私有数据目录),
对前端暴露的方法用 @rpc 标注,参数以关键字传入(前端传一个 params 对象)。
"""

import os
from typing import Any, Awaitable, Callable

from . import runtime
from .log import Logger
from .notify import Notifier
from .settings import ScopedSettings
from .tasks import OnChange, TaskHandle, TaskManager

EVENT = "decky_tools_event"  # 唯一的 decky.emit 事件名,载荷 {tool, type, data}
# 只有 Steam 前端能执行的动作;后端下令,前端照做(src/core/commands.ts)
COMMANDS = frozenset({"restart_steam"})


def rpc(fn: Callable[..., Awaitable[Any]]) -> Callable[..., Awaitable[Any]]:
    fn.__rpc__ = True  # type: ignore[attr-defined]
    return fn


class Context:
    def __init__(
        self, tool_id: str, settings: ScopedSettings, tasks: TaskManager,
        core_settings: ScopedSettings, notifier: Notifier,
    ):
        self.tool_id = tool_id
        self._notifier = notifier
        self.settings = settings
        self.core_settings = core_settings  # 只读用途:全局选项(如下载镜像)
        self.log = Logger(tool_id)
        self._tasks = tasks
        self.data_dir = os.path.join(runtime.runtime_dir(), tool_id)
        os.makedirs(self.data_dir, exist_ok=True)

    async def emit(self, type_: str, data: Any = None) -> None:
        await runtime.emit(EVENT, {"tool": self.tool_id, "type": type_, "data": data})

    async def notify(self, key: str, params: dict[str, Any] | None = None) -> None:
        """发一条用户通知;文案由前端按 (tool, key, params) 本地化。"""
        await self._notifier.add(self.tool_id, key, params)

    async def command(self, name: str) -> None:
        """令前端执行只有 Steam 前端能做的动作。"""
        assert name in COMMANDS, name
        await runtime.emit(EVENT, {"tool": "core", "type": "command", "data": {"name": name}})

    def start_task(
        self, kind: str, key: str, title: str,
        body: Callable[[TaskHandle], Awaitable[None]], meta: dict[str, Any] | None = None,
        on_change: OnChange | None = None,
    ) -> dict[str, Any]:
        return self._tasks.start(self.tool_id, kind, self._task_key(key), title, body, meta, on_change)

    def task_snapshot(self, key: str) -> dict[str, Any] | None:
        return self._tasks.snapshot(self._task_key(key))

    def _task_key(self, key: str) -> str:
        return f"{self.tool_id}:{key}"


class Tool:
    id = ""

    def __init__(self, ctx: Context):
        self.ctx = ctx

    async def start(self) -> None:
        """插件加载时调用;不要在这里做网络请求等慢操作。"""

    async def stop(self) -> None:
        """插件卸载时调用。"""

    def methods(self) -> dict[str, Callable[..., Awaitable[Any]]]:
        names = (n for n in dir(type(self)) if not n.startswith("_"))
        return {n: getattr(self, n) for n in names if getattr(getattr(type(self), n), "__rpc__", False)}

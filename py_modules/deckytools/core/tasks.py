"""通用后台任务:进度/阶段/取消/去重。下载、解压等耗时操作都走这里。
状态变化回调给发起任务的工具(on_change),由工具决定如何更新自己的界面快照。

任务体是 `async def body(handle)`;阻塞工作放线程里跑,线程内周期调用 `handle.check()`
响应取消、`handle.progress()` 报进度(线程安全,内部节流后切回事件循环发事件)。
"""

import asyncio
import itertools
import threading
import time
from dataclasses import asdict, dataclass, field
from typing import Any, Awaitable, Callable

from .errors import INTERNAL, Cancelled, ToolError
from .log import Logger

_log = Logger("tasks")

QUEUED, RUNNING, DONE, FAILED, CANCELLED = "queued", "running", "done", "failed", "cancelled"
FINISHED = (DONE, FAILED, CANCELLED)
_EMIT_INTERVAL = 0.4
_KEEP_FINISHED = 20


@dataclass
class Task:
    id: str
    tool: str
    kind: str
    key: str  # 去重键:同一 key 同时只能有一个未结束任务
    title: str
    state: str = QUEUED
    stage: str = ""
    done: int = 0
    total: int = 0
    error: str = ""
    meta: dict[str, Any] = field(default_factory=dict)
    updated: float = field(default_factory=time.time)


OnChange = Callable[[Task], None]


class TaskHandle:
    def __init__(self, task: Task, loop: asyncio.AbstractEventLoop, notify: Callable[[Task], None]):
        self.task = task
        self._loop = loop
        self._notify = notify
        self._cancel = threading.Event()
        self._last_emit = 0.0

    @property
    def cancelled(self) -> bool:
        return self._cancel.is_set()

    def check(self) -> None:
        if self._cancel.is_set():
            raise Cancelled()

    def stage(self, stage: str, total: int = 0) -> None:
        """切阶段并重置进度;可在任意线程调用。"""
        self.task.stage, self.task.done, self.task.total = stage, 0, total
        self._push(force=True)

    def progress(self, done: int, total: int | None = None) -> None:
        self.task.done = done
        if total is not None:
            self.task.total = total
        self._push(force=False)

    def _push(self, force: bool) -> None:
        now = time.monotonic()
        if not force and now - self._last_emit < _EMIT_INTERVAL:
            return
        self._last_emit = now
        self._loop.call_soon_threadsafe(self._notify, self.task)


class TaskManager:
    def __init__(self):
        self._listeners: dict[str, OnChange] = {}
        self._tasks: dict[str, Task] = {}
        self._handles: dict[str, TaskHandle] = {}
        self._runners: dict[str, asyncio.Task] = {}
        self._ids = itertools.count(1)

    def list(self, tool: str | None = None) -> list[dict[str, Any]]:
        return [asdict(t) for t in self._tasks.values() if tool is None or t.tool == tool]

    def snapshot(self, key: str) -> dict[str, Any] | None:
        """未结束任务的界面字段;无进行中任务返回 None。"""
        t = self.active(key)
        return t and {"id": t.id, "state": t.state, "stage": t.stage, "done": t.done, "total": t.total}

    def active(self, key: str) -> Task | None:
        return next((t for t in self._tasks.values() if t.key == key and t.state not in FINISHED), None)

    def start(
        self, tool: str, kind: str, key: str, title: str,
        body: Callable[[TaskHandle], Awaitable[None]], meta: dict[str, Any] | None = None,
        on_change: OnChange | None = None,
    ) -> dict[str, Any]:
        existing = self.active(key)
        if existing:
            return asdict(existing)
        task = Task(id=f"t{next(self._ids)}", tool=tool, kind=kind, key=key, title=title, meta=meta or {})
        handle = TaskHandle(task, asyncio.get_running_loop(), self._notify)
        self._tasks[task.id], self._handles[task.id] = task, handle
        if on_change:
            self._listeners[task.id] = on_change
        self._runners[task.id] = asyncio.create_task(self._run(handle, body))
        self._prune()
        self._notify(task)
        return asdict(task)

    def cancel(self, task_id: str) -> bool:
        handle = self._handles.get(task_id)
        if not handle or handle.task.state in FINISHED:
            return False
        handle._cancel.set()
        return True

    async def shutdown(self) -> None:
        for handle in self._handles.values():
            handle._cancel.set()
        runners = [r for r in self._runners.values() if not r.done()]
        if runners:
            await asyncio.wait(runners, timeout=5)

    async def _run(self, handle: TaskHandle, body: Callable[[TaskHandle], Awaitable[None]]) -> None:
        task = handle.task
        task.state = RUNNING
        self._notify(task)
        try:
            await body(handle)
            task.state = DONE
        except Cancelled:
            task.state = CANCELLED
        except ToolError as e:
            task.state, task.error = FAILED, e.code
            _log.warn(task.kind, f"task {task.id} failed: {e}")
        except Exception as e:  # noqa: BLE001 —— 任务体意外异常不能拖垮事件循环
            task.state, task.error = FAILED, INTERNAL
            _log.error(task.kind, f"task {task.id} crashed: {type(e).__name__}: {e}")
        finally:
            self._runners.pop(task.id, None)
            self._handles.pop(task.id, None)
        _log.info(task.kind, f"task {task.id} {task.state}")
        self._notify(task)

    def _notify(self, task: Task) -> None:
        task.updated = time.time()
        listener = self._listeners.get(task.id)
        if listener:
            try:
                listener(task)
            except Exception as e:  # noqa: BLE001 —— 监听者出错不影响任务本身
                _log.error(task.kind, f"task listener failed: {type(e).__name__}: {e}")

    def _prune(self) -> None:
        finished = sorted((t for t in self._tasks.values() if t.state in FINISHED), key=lambda t: t.updated)
        for t in finished[: max(0, len(finished) - _KEEP_FINISHED)]:
            self._tasks.pop(t.id, None)
            self._listeners.pop(t.id, None)

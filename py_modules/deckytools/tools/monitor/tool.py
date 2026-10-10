"""系统监控:CPU / GPU / 内存 / 功耗 / 电池实时读数、最近 30 分钟历史与系统信息(IP 等)。

采样由 Zig 写的 bin/dt-monitor 完成(源码 backend/):插件加载期间常驻,每秒采样并在
自身内存里保留 30 分钟历史(不落盘)。实时推送按需开启:前端面板打开期间周期性 watch()
续租,租约过期即通知子进程停止推送,Python 侧不再每秒被唤醒。
"""

import asyncio
import time
from typing import Any

from ...core.child import UNAVAILABLE, ChildProcess
from ...core.errors import INVALID_REQUEST, ToolError
from ...core.tool import Tool, rpc

BINARY = "dt-monitor"
LEASE_SECONDS = 15
_REPLY_TIMEOUT = 3
_SUPERVISE_INTERVAL = 2
_MAX_BACKOFF = 60
# 前端可选的历史视图:窗口秒数 → 分桶秒数(桶数 ≤ 360,见 backend/src/history.zig)
RANGES = {120: 1, 1800: 10}


class MonitorTool(Tool):
    id = "monitor"

    def __init__(self, ctx):
        super().__init__(ctx)
        self._child = ChildProcess(BINARY, ctx.log, self._on_message)
        self._lease_until = 0.0
        self._live = False
        self._sample: dict[str, Any] | None = None
        self._info: dict[str, Any] | None = None
        self._pending: dict[str, asyncio.Future] = {}  # 回复类型 → 共用的等待者
        self._lock = asyncio.Lock()
        self._next_start = 0.0
        self._backoff = 1.0
        self._supervisor: asyncio.Task | None = None

    async def start(self) -> None:
        self._supervisor = asyncio.create_task(self._supervise())

    async def stop(self) -> None:
        if self._supervisor:
            self._supervisor.cancel()
        await self._child.stop()

    @rpc
    async def watch(self) -> dict[str, Any]:
        """开始/续租实时推送,返回最近一次采样与已缓存的系统信息。"""
        self._lease_until = time.monotonic() + LEASE_SECONDS
        await self._ensure_running()
        await self._set_live(True)
        return {"sample": self._sample, "info": self._info, "lease": LEASE_SECONDS}

    @rpc
    async def unwatch(self) -> None:
        self._lease_until = 0
        await self._set_live(False)

    @rpc
    async def history(self, window: int) -> dict[str, Any]:
        """最近 window 秒的分桶均值:{step_ms, keys, points}。"""
        if window not in RANGES:
            raise ToolError(INVALID_REQUEST, "unsupported history window")
        await self._ensure_running()
        return await self._request(f"history {window} {RANGES[window]}", "history")

    @rpc
    async def info(self, refresh: bool = False) -> dict[str, Any]:
        if self._info and not refresh:
            return self._info
        await self._ensure_running()
        return await self._request("info", "info")

    async def _request(self, command: str, reply: str) -> dict[str, Any]:
        """发命令并等待对应类型的回复;同类并发请求共用一次查询。"""
        future = self._pending.get(reply)
        if future is None or future.done():
            future = self._pending[reply] = asyncio.get_running_loop().create_future()
            try:
                await self._child.send(command)
            except ToolError:
                self._pending.pop(reply, None)
                raise
        try:
            return await asyncio.wait_for(asyncio.shield(future), _REPLY_TIMEOUT)
        except asyncio.TimeoutError:
            if self._pending.get(reply) is future:
                self._pending.pop(reply)
            raise ToolError(UNAVAILABLE, f"{reply} request timed out") from None

    async def _set_live(self, on: bool) -> None:
        if self._live == on or not self._child.running:
            return
        await self._child.send("live on" if on else "live off")
        self._live = on

    async def _ensure_running(self) -> None:
        async with self._lock:
            if self._child.running:
                return
            # 崩溃后指数退避,避免拉起-崩溃循环;主动停止不会走到这里
            if time.monotonic() < self._next_start:
                raise ToolError(UNAVAILABLE, "monitor restarting")
            self._next_start = time.monotonic() + self._backoff
            self._backoff = min(self._backoff * 2, _MAX_BACKOFF)
            self._live, self._sample = False, None
            await self._child.start()

    async def _supervise(self) -> None:
        """常驻守护:保持子进程运行(历史才能连续),并在租约过期时关掉实时推送。"""
        started_at = 0.0
        while True:
            try:
                if not self._child.running:
                    await self._ensure_running()
                    started_at = time.monotonic()
                elif time.monotonic() - started_at > _MAX_BACKOFF:
                    self._backoff = 1.0  # 稳定运行一段时间后重置退避
                if self._live and time.monotonic() > self._lease_until:
                    await self._set_live(False)
            except ToolError:
                pass  # 二进制缺失或退避中:下一轮再试,错误已由 ChildProcess 记录
            await asyncio.sleep(_SUPERVISE_INTERVAL)

    async def _on_message(self, msg: dict[str, Any]) -> None:
        kind, data = msg.get("type"), msg.get("data")
        if kind == "sample" and isinstance(data, dict):
            self._sample = data
            await self.ctx.emit("sample", data)
        elif kind in ("info", "history") and isinstance(data, dict):
            if kind == "info":
                self._info = data
            future = self._pending.pop(kind, None)
            if future and not future.done():
                future.set_result(data)
        elif kind == "error":
            self.ctx.log.warn("monitor", f"child reported {str(msg.get('code'))[:40]}")

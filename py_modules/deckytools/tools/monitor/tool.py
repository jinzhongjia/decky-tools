"""系统监控:CPU / GPU / 内存 / 功耗 / 电池实时读数、最近 30 分钟历史与系统信息(IP 等)。

采样、历史与界面快照全部由 Zig 写的 bin/dt-monitor 完成(源码 backend/),插件加载期间常驻。
面板打开期间前端每 5 秒 watch() 续租,子进程每秒推送一帧完整快照;本工具把快照的 JSON 文本
原样转给前端,不解析也不重新序列化(实测逐层解析成对象曾让插件进程与 Decky loader 多花约 2.8 ms/s)。
租约到期即令子进程停止推送。子进程守护、租约都由事件驱动,空闲时没有任何定时唤醒。
"""

import asyncio
import time
from typing import Any

from ...core.child import UNAVAILABLE, ChildProcess
from ...core.errors import INVALID_REQUEST, ToolError
from ...core.tool import Tool, rpc

BINARY = "dt-monitor"
LEASE_SECONDS = 15
RANGES = (120, 1800)  # 秒;与 backend/src/history.zig 的 ranges 一致
DEFAULT_RANGE = 120
_REPLY_TIMEOUT = 3
_MAX_BACKOFF = 60
_STABLE_SECONDS = 60
# 快照行的固定开头,与 backend/src/view.zig 的 view_prefix 一致
VIEW_PREFIX = b'{"type":"view","data":'
_RANGE_PREFIX = VIEW_PREFIX + b'{"range":'


def parse_view_line(raw: bytes) -> tuple[int, str] | None:
    """快照行 → (时间范围, data 的 JSON 文本);其它行返回 None。只做切片,不解析 JSON。"""
    if not raw.startswith(_RANGE_PREFIX) or not raw.endswith(b"}\n"):
        return None
    comma = raw.find(b",", len(_RANGE_PREFIX))
    try:
        window = int(raw[len(_RANGE_PREFIX) : comma])
    except ValueError:
        return None
    return window, raw[len(VIEW_PREFIX) : -2].decode()


class MonitorTool(Tool):
    id = "monitor"

    def __init__(self, ctx):
        super().__init__(ctx)
        self._child = ChildProcess(BINARY, ctx.log, self._on_message, self._on_line)
        self._view: str | None = None  # 最近一帧快照(JSON 文本)
        self._view_range: int | None = None
        self._live: int | None = None  # 子进程正在推送的时间范围
        self._info: dict[str, Any] | None = None
        self._info_future: asyncio.Future | None = None
        self._view_waiters: list[tuple[int, asyncio.Future]] = []
        self._lease: asyncio.TimerHandle | None = None
        self._supervisor: asyncio.Task | None = None

    async def start(self) -> None:
        self._supervisor = asyncio.create_task(self._supervise())

    async def stop(self) -> None:
        if self._supervisor:
            self._supervisor.cancel()
        if self._lease:
            self._lease.cancel()
        await self._child.stop()

    # ---- 用户操作 ----

    @rpc
    async def watch(self, snapshot: bool = True) -> dict[str, Any]:
        """开始 / 续租实时推送(租约 LEASE_SECONDS 秒)。snapshot=True 时返回当前快照与系统信息;
        续租心跳传 False:快照已经每秒经 view 事件送达,不必每 5 秒再传一遍。"""
        self._renew_lease()
        if not self._child.running:
            raise ToolError(UNAVAILABLE, "monitor not running")
        if self._live != self._range():
            await self._go_live(self._range())
        if self._info is None:
            asyncio.create_task(self._load_info())
        return self._snapshot() if snapshot else {"view": None, "info": None}

    @rpc
    async def unwatch(self) -> None:
        if self._lease:
            self._lease.cancel()
        self._expire()

    @rpc
    async def set_range(self, window: int) -> dict[str, Any]:
        if window not in RANGES:
            raise ToolError(INVALID_REQUEST, "unsupported history window")
        self.ctx.settings.set("range", window)
        if self._live is not None and self._child.running:
            await self._go_live(window)
        return self._snapshot()

    @rpc
    async def refresh_info(self) -> dict[str, Any] | None:
        if not self._child.running:
            raise ToolError(UNAVAILABLE, "monitor not running")
        await self._load_info()
        return self._info

    # ---- 实时推送 ----

    def _range(self) -> int:
        window = self.ctx.settings.get("range", DEFAULT_RANGE)
        return window if window in RANGES else DEFAULT_RANGE

    def _snapshot(self) -> dict[str, Any]:
        view = self._view if self._view_range == self._range() else None
        return {"view": view, "info": self._info}

    async def _go_live(self, window: int) -> None:
        """令子进程推送该范围;它会立即回一帧,等到这一帧(最多 _REPLY_TIMEOUT 秒)再返回。"""
        future = asyncio.get_running_loop().create_future()
        self._view_waiters.append((window, future))
        self._live = window  # 先置位:子进程的即时回帧可能在 send 返回前就被读到
        try:
            await self._child.send(f"live {window}")
            await asyncio.wait_for(future, _REPLY_TIMEOUT)
        except asyncio.TimeoutError:
            pass
        except ToolError:
            self._live = None
            raise
        finally:
            self._view_waiters = [(w, f) for w, f in self._view_waiters if f is not future]

    def _renew_lease(self) -> None:
        if self._lease:
            self._lease.cancel()
        self._lease = asyncio.get_running_loop().call_later(LEASE_SECONDS, self._expire)

    def _expire(self) -> None:
        self._lease = None
        if self._live is None:
            return
        self._live = None
        asyncio.ensure_future(self._send_quietly("live off"))

    async def _send_quietly(self, line: str) -> None:
        try:
            await self._child.send(line)
        except ToolError:
            pass

    async def _on_line(self, raw: bytes) -> bool:
        parsed = parse_view_line(raw)
        if parsed is None:
            return False
        window, text = parsed
        self._view, self._view_range = text, window
        for w, future in self._view_waiters:
            if w == window and not future.done():
                future.set_result(None)
        if self._live == window:
            await self.ctx.emit("view", text)
        return True

    # ---- 系统信息 ----

    async def _load_info(self) -> None:
        """请求系统信息;同时到达的请求共用一次查询。结果经 info 事件推给前端。"""
        future = self._info_future
        if future is None or future.done():
            future = self._info_future = asyncio.get_running_loop().create_future()
            try:
                await self._child.send("info")
            except ToolError:
                self._info_future = None
                return
        try:
            await asyncio.wait_for(asyncio.shield(future), _REPLY_TIMEOUT)
        except asyncio.TimeoutError:
            if self._info_future is future:
                self._info_future = None

    async def _on_message(self, msg: dict[str, Any]) -> None:
        kind, data = msg.get("type"), msg.get("data")
        if kind == "info" and isinstance(data, dict):
            self._info = data
            if self._info_future and not self._info_future.done():
                self._info_future.set_result(None)
            await self.ctx.emit("info", data)
        elif kind == "error":
            self.ctx.log.warn("monitor", f"child reported {str(msg.get('code'))[:40]}")

    # ---- 子进程守护 ----

    async def _supervise(self) -> None:
        """保持子进程常驻(历史才能连续):等它退出再按指数退避重启,不轮询。"""
        backoff = 1.0
        while True:
            try:
                await self._child.start()
            except ToolError:  # 二进制缺失等:退避后重试,错误已由 ChildProcess 记录
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, _MAX_BACKOFF)
                continue
            started = time.monotonic()
            self._live = None
            if self._lease is not None:  # 有人正在看:新进程恢复推送
                asyncio.create_task(self._go_live(self._range()))
            await self._child.wait()
            backoff = 1.0 if time.monotonic() - started > _STABLE_SECONDS else min(backoff * 2, _MAX_BACKOFF)
            await asyncio.sleep(backoff)

"""常驻子进程:插件 bin/ 下的原生二进制,stdin 写命令行、stdout 读 NDJSON 消息。

供需要原生能力的工具复用(如 Zig 写的 dt-monitor)。子进程 stdin 关闭即应自行退出,
所以插件进程消失时子进程也会跟着结束,不会成为孤儿。
"""

import asyncio
import json
import os
from typing import Any, Awaitable, Callable

from . import runtime
from .errors import ToolError
from .log import Logger

UNAVAILABLE = "unavailable"
_STDERR_LINES = 20  # 每次运行最多记录的 stderr 行数,防刷屏
_LINE_LIMIT = 1 << 16

OnMessage = Callable[[dict[str, Any]], Awaitable[None] | None]
# 原始行钩子:返回 True 表示已处理,跳过 JSON 解析(高频消息透传用,见 tools/monitor)
OnLine = Callable[[bytes], Awaitable[bool] | bool]


def binary_path(name: str) -> str:
    return os.path.join(runtime.plugin_dir(), "bin", name)


def _child_env() -> dict[str, str]:
    # Decky 冻结的 Python 会注入自己的库路径,不能泄漏给子进程
    env = {k: v for k, v in os.environ.items() if k not in ("LD_LIBRARY_PATH", "LD_PRELOAD")}
    env["LANG"] = "C.UTF-8"
    return env


class ChildProcess:
    def __init__(self, name: str, log: Logger, on_message: OnMessage, on_line: OnLine | None = None):
        self.name = name
        self._log = log
        self._on_message = on_message
        self._on_line = on_line
        self._proc: asyncio.subprocess.Process | None = None
        self._tasks: list[asyncio.Task] = []
        self._warned_missing = False

    @property
    def running(self) -> bool:
        return self._proc is not None and self._proc.returncode is None

    async def start(self, *args: str) -> None:
        if self.running:
            return
        path = binary_path(self.name)
        if not os.access(path, os.X_OK):
            if not self._warned_missing:
                self._log.error("child", f"{self.name} binary missing")
                self._warned_missing = True
            raise ToolError(UNAVAILABLE, f"{self.name} binary missing")
        try:
            self._proc = await asyncio.create_subprocess_exec(
                path, *args, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, env=_child_env(), limit=_LINE_LIMIT,
            )
        except OSError as e:
            raise ToolError(UNAVAILABLE, f"spawn {self.name}: {type(e).__name__}") from None
        self._log.info("child", f"{self.name} started (pid {self._proc.pid})")
        self._tasks = [asyncio.create_task(self._read_stdout(self._proc)), asyncio.create_task(self._read_stderr(self._proc))]

    async def send(self, line: str) -> None:
        if not self.running or not self._proc or not self._proc.stdin:
            raise ToolError(UNAVAILABLE, f"{self.name} not running")
        try:
            self._proc.stdin.write(line.encode() + b"\n")
            await self._proc.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            raise ToolError(UNAVAILABLE, f"{self.name} pipe closed") from None

    async def wait(self) -> int | None:
        """等待当前子进程退出(崩溃或被停止),返回退出码;未运行时立即返回 None。"""
        proc = self._proc
        if proc is None:
            return None
        return await proc.wait()

    async def stop(self) -> None:
        proc, self._proc = self._proc, None
        if proc and proc.returncode is None:
            if proc.stdin:
                proc.stdin.close()  # 约定:stdin EOF 即退出
            try:
                await asyncio.wait_for(proc.wait(), 2)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
            self._log.info("child", f"{self.name} stopped")
        for task in self._tasks:
            task.cancel()
        self._tasks = []

    async def _read_stdout(self, proc: asyncio.subprocess.Process) -> None:
        assert proc.stdout
        while True:
            try:
                raw = await proc.stdout.readline()
            except ValueError:  # 超长行
                self._log.warn("child", f"{self.name} sent an oversized line")
                continue
            if not raw:
                break
            await self._dispatch(raw)
        code = await proc.wait()
        if proc is self._proc or self._proc is None:
            level = self._log.info if code == 0 else self._log.warn
            level("child", f"{self.name} exited with code {code}")

    async def _dispatch(self, raw: bytes) -> None:
        if self._on_line:
            try:
                handled = self._on_line(raw)
                if asyncio.iscoroutine(handled):
                    handled = await handled
                if handled:
                    return
            except Exception as e:  # noqa: BLE001 —— 钩子异常不能终止读循环
                self._log.error("child", f"{self.name} line hook failed: {type(e).__name__}: {e}")
                return
        try:
            msg = json.loads(raw)
        except ValueError:
            self._log.warn("child", f"{self.name} sent malformed output")
            return
        if not isinstance(msg, dict):
            return
        try:
            result = self._on_message(msg)
            if asyncio.iscoroutine(result):
                await result
        except Exception as e:  # noqa: BLE001 —— 回调异常不能终止读循环
            self._log.error("child", f"{self.name} handler failed: {type(e).__name__}: {e}")

    async def _read_stderr(self, proc: asyncio.subprocess.Process) -> None:
        assert proc.stderr
        logged = 0
        while raw := await proc.stderr.readline():
            if logged < _STDERR_LINES:
                self._log.warn("child", f"{self.name} stderr: {raw.decode(errors='replace').strip()[:200]}")
                logged += 1

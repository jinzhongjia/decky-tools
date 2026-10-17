"""通知队列:后端决定何时通知、每条只发一次。

工具调用 ctx.notify(key, params) 入队并推送 core/notify 事件;前端显示后 ack,后端才删除。
前端不在线(如切换桌面/游戏模式、Steam 重启中)时通知留在队列,前端重新加载后经
pending() 补发;已 ack 的通知永远不会再出现。
"""

import itertools
from typing import Any, Awaitable, Callable

_MAX_PENDING = 20

Emit = Callable[[dict[str, Any]], Awaitable[None]]


class Notifier:
    def __init__(self, emit: Emit):
        self._emit = emit
        self._pending: dict[str, dict[str, Any]] = {}
        self._ids = itertools.count(1)

    async def add(self, tool: str, key: str, params: dict[str, Any] | None = None) -> None:
        note = {"id": f"n{next(self._ids)}", "tool": tool, "key": key, "params": params or {}}
        self._pending[note["id"]] = note
        while len(self._pending) > _MAX_PENDING:  # 长期无人确认时丢弃最旧的
            self._pending.pop(next(iter(self._pending)))
        await self._emit(note)

    def pending(self) -> list[dict[str, Any]]:
        return list(self._pending.values())

    def ack(self, ids: list[str]) -> None:
        for i in ids:
            self._pending.pop(i, None)

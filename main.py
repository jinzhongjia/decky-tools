"""Decky 入口:只做转发。所有功能由 py_modules/deckytools 里注册的工具提供。

前端唯一的 RPC 是 `call(tool, method, params)`(见 src/core/api.ts),
返回 `{"ok": true, "data": ...}` 或 `{"ok": false, "error": code}`。
"""

from deckytools.core.app import App
from deckytools.tools import TOOLS


class Plugin:
    async def _main(self):
        self.app = App(TOOLS)
        await self.app.start()

    async def _unload(self):
        await self.app.stop()

    async def call(self, tool: str, method: str, params: dict | None = None):
        return await self.app.call(tool, method, params)

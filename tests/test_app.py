import asyncio
import os
import tempfile
import unittest

import _path  # noqa: F401
from deckytools.core.app import App
from deckytools.core.errors import ToolError
from deckytools.core.settings import SettingsStore
from deckytools.core.tool import Tool, rpc


class Echo(Tool):
    id = "echo"

    @rpc
    async def say(self, text: str) -> str:
        return text

    @rpc
    async def fail(self) -> None:
        raise ToolError("busy")

    @rpc
    async def crash(self) -> None:
        raise RuntimeError("secret detail")

    @rpc
    async def slow(self) -> dict:
        async def body(handle):
            for i in range(100):
                await asyncio.sleep(0.01)
                handle.check()

        return self.ctx.start_task("slow", "k", "Slow", body)

    async def not_exposed(self) -> None:
        pass


class AppTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.app = App([Echo], SettingsStore(os.path.join(self.tmp.name, "s.json")))

    async def asyncTearDown(self):
        await self.app.stop()
        self.tmp.cleanup()

    async def test_dispatch_and_envelope(self):
        self.assertEqual(await self.app.call("echo", "say", {"text": "hi"}), {"ok": True, "data": "hi"})
        self.assertEqual(await self.app.call("echo", "fail"), {"ok": False, "error": "busy"})
        self.assertEqual(await self.app.call("echo", "crash"), {"ok": False, "error": "internal"})
        self.assertEqual((await self.app.call("echo", "not_exposed"))["error"], "unknown_method")
        self.assertEqual((await self.app.call("nope", "say"))["error"], "unknown_tool")
        self.assertEqual((await self.app.call("echo", "say", {"x": 1}))["error"], "invalid_request")
        self.assertEqual((await self.app.call("echo", "say", ["x"]))["error"], "invalid_request")

    async def test_options_whitelist(self):
        ok = await self.app.call("core", "set_option", {"key": "github_mirror", "value": " https://m/ "})
        self.assertTrue(ok["ok"])
        opts = await self.app.call("core", "get_options")
        self.assertEqual(opts["data"]["github_mirror"], "https://m/")
        bad = await self.app.call("core", "set_option", {"key": "other", "value": 1})
        self.assertEqual(bad["error"], "invalid_request")
        bad = await self.app.call("core", "set_option", {"key": "github_mirror", "value": "ftp://x"})
        self.assertEqual(bad["error"], "invalid_request")
        ok = await self.app.call("core", "set_option", {"key": "github_mirror", "value": ""})
        self.assertTrue(ok["ok"])

    async def test_task_dedup_and_cancel(self):
        first = (await self.app.call("echo", "slow"))["data"]
        again = (await self.app.call("echo", "slow"))["data"]
        self.assertEqual(first["id"], again["id"])
        self.assertTrue((await self.app.call("core", "cancel_task", {"id": first["id"]}))["data"])
        for _ in range(100):
            await asyncio.sleep(0.01)
            states = {t["id"]: t["state"] for t in (await self.app.call("core", "tasks"))["data"]}
            if states[first["id"]] == "cancelled":
                break
        self.assertEqual(states[first["id"]], "cancelled")


if __name__ == "__main__":
    unittest.main()

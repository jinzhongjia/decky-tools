import asyncio
import os
import tempfile
import threading
import time
import unittest
from unittest import mock

import _path  # noqa: F401
from deckytools.core import net, runtime
from deckytools.core.app import App
from deckytools.core.errors import ToolError
from deckytools.core.settings import SettingsStore
from deckytools.tools.proton import ProtonTool, compat, installer, steam

PAYLOAD = [{"tag_name": "GE-Proton11-7", "assets": [
    {"name": "GE-Proton11-7-x86_64.tar.gz", "size": 5, "browser_download_url": "https://github.com/a"}]}]


class ProtonViewTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = mock.patch.dict(os.environ, {"DECKY_USER_HOME": self.tmp.name})
        self.env.start()
        self.events: list = []

        async def record(_event, payload):
            self.events.append(payload)

        self.emit = mock.patch.object(runtime, "emit", record)
        self.emit.start()
        self.app = App([ProtonTool], SettingsStore(os.path.join(self.tmp.name, "s.json")))
        self.tool = self.app.tools["proton"]
        self.calls = 0
        self.lock = threading.Lock()

    async def asyncTearDown(self):
        await self.app.stop()
        self.emit.stop()
        self.env.stop()
        self.tmp.cleanup()

    def fake_get_json(self, url, timeout=20):
        with self.lock:
            self.calls += 1
        time.sleep(0.05)
        return PAYLOAD

    def views(self):
        return [e["data"] for e in self.events if e["tool"] == "proton" and e["type"] == "view"]

    def notes(self):
        return [e["data"] for e in self.events if e["type"] == "notify"]

    async def settle(self):
        for _ in range(100):
            await asyncio.sleep(0.02)
            if not self.tool._fetching and (not self.tool._push_task or self.tool._push_task.done()):
                return

    async def test_view_fetches_in_background_once(self):
        with mock.patch.object(net, "get_json", self.fake_get_json):
            first = await asyncio.gather(*[self.app.call("proton", "view") for _ in range(3)])
            self.assertTrue(all(v["data"]["loading"] for v in first))
            await self.settle()
        self.assertEqual(self.calls, 1)
        last = self.views()[-1]
        self.assertFalse(last["loading"])
        rel = last["releases"][0]
        self.assertEqual((rel["tag"], rel["latest"], rel["installed"], rel["task"]), ("GE-Proton11-7", True, False, None))

    async def test_installed_flag_comes_from_backend(self):
        os.makedirs(os.path.join(compat.compat_dir(), "GE-Proton11-7-x86_64"))
        open(os.path.join(compat.compat_dir(), "GE-Proton11-7-x86_64", compat.MANIFEST), "w").close()
        with mock.patch.object(net, "get_json", self.fake_get_json):
            await self.app.call("proton", "view")
            await self.settle()
        self.assertTrue(self.views()[-1]["releases"][0]["installed"])

    async def test_network_error_keeps_stale_list(self):
        with mock.patch.object(net, "get_json", self.fake_get_json):
            await self.app.call("proton", "view")
            await self.settle()

        def offline(*_a, **_k):
            raise ToolError("network")

        with mock.patch.object(net, "get_json", offline):
            await self.app.call("proton", "refresh")
            await self.settle()
        last = self.views()[-1]
        self.assertEqual((last["stale"], last["error"], len(last["releases"])), (True, "network", 1))

    async def test_select_source_persists(self):
        with mock.patch.object(net, "get_json", self.fake_get_json):
            res = await self.app.call("proton", "select_source", {"source": "proton-cachyos"})
            await self.settle()
        self.assertEqual(res["data"]["source"], "proton-cachyos")
        self.assertEqual(self.tool.ctx.settings.get("source"), "proton-cachyos")
        bad = await self.app.call("proton", "select_source", {"source": "nope"})
        self.assertEqual(bad["error"], "invalid_request")

    async def run_install(self, fake):
        with mock.patch.object(net, "get_json", self.fake_get_json):
            await self.app.call("proton", "view")
            await self.settle()
        with mock.patch.object(installer, "install", fake), mock.patch.object(steam, "steam_started_at", return_value=0):
            await self.app.call("proton", "install", {"tag": "GE-Proton11-7"})
            for _ in range(100):
                await asyncio.sleep(0.02)
                if self.tool.ctx.task_snapshot("ge-proton:GE-Proton11-7") is None:
                    break
            await self.settle()
            return self.views()[-1]

    async def test_install_success_notifies_once_and_needs_restart(self):
        last = await self.run_install(lambda *a: "GE-Proton11-7-x86_64")
        self.assertEqual([n["key"] for n in self.notes()], ["install_done"])
        self.assertTrue(last["restart_needed"])
        self.assertIsNone(last["releases"][0]["task"])
        # Steam 之后重启过 → 自动清除
        self.tool._steam_checked = (0.0, None)
        with mock.patch.object(steam, "steam_started_at", return_value=time.time() + 1):
            self.assertFalse((await self.app.call("proton", "view"))["data"]["restart_needed"])

    async def test_install_failure_notifies_with_error_code(self):
        def boom(*_a):
            raise ToolError("checksum_mismatch")

        last = await self.run_install(boom)
        self.assertEqual([(n["key"], n["params"]["error"]) for n in self.notes()], [("install_failed", "checksum_mismatch")])
        self.assertFalse(last["restart_needed"])

    async def test_cancel_does_not_notify(self):
        def cancelled(*_a):
            from deckytools.core.errors import Cancelled
            raise Cancelled()

        await self.run_install(cancelled)
        self.assertEqual(self.notes(), [])

    async def test_installed_uses_user_home(self):
        res = await self.app.call("proton", "view")
        self.assertTrue(compat.compat_dir().startswith(self.tmp.name))
        self.assertTrue(res["data"]["installed_loaded"])


class SteamStartTest(unittest.TestCase):
    def test_parse_start_ticks_handles_spaces_in_name(self):
        stat = "123 (steam web helper) S " + " ".join(str(i) for i in range(4, 30))
        self.assertEqual(steam.parse_start_ticks(stat), 22)

    def test_newest_steam_process(self):
        with tempfile.TemporaryDirectory() as proc:
            with open(os.path.join(proc, "stat"), "w") as f:
                f.write("cpu 1 2\nbtime 1000\n")
            for pid, comm, ticks in (("10", "steam", 100), ("11", "steam", 500), ("12", "bash", 900)):
                os.makedirs(os.path.join(proc, pid))
                with open(os.path.join(proc, pid, "comm"), "w") as f:
                    f.write(comm + "\n")
                fields = ["0"] * 19 + [str(ticks)]
                with open(os.path.join(proc, pid, "stat"), "w") as f:
                    f.write(f"{pid} ({comm}) " + " ".join(fields))
            hz = os.sysconf("SC_CLK_TCK")
            self.assertAlmostEqual(steam.steam_started_at(proc), 1000 + 500 / hz)


if __name__ == "__main__":
    unittest.main()

import asyncio
import os
import tempfile
import threading
import time
import unittest
from unittest import mock

import _path  # noqa: F401
from deckytools.core import net
from deckytools.core.app import App
from deckytools.core.settings import SettingsStore
from deckytools.tools.proton import ProtonTool, compat

PAYLOAD = [{"tag_name": "GE-Proton11-7", "assets": [
    {"name": "GE-Proton11-7-x86_64.tar.gz", "size": 5, "browser_download_url": "https://github.com/a"}]}]


class ReleasesTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["DECKY_USER_HOME"] = self.tmp.name
        self.app = App([ProtonTool], SettingsStore(os.path.join(self.tmp.name, "s.json")))
        self.calls = 0
        self.lock = threading.Lock()

    async def asyncTearDown(self):
        self.tmp.cleanup()

    def fake_get_json(self, url, timeout=20):
        with self.lock:
            self.calls += 1
        time.sleep(0.05)
        return PAYLOAD

    async def test_concurrent_fetches_share_one_request(self):
        with mock.patch.object(net, "get_json", self.fake_get_json):
            results = await asyncio.gather(*[
                self.app.call("proton", "releases", {"source": "ge-proton", "refresh": True}) for _ in range(3)
            ])
        self.assertTrue(all(r["ok"] for r in results))
        self.assertEqual(self.calls, 1)
        self.assertEqual(results[0]["data"]["releases"][0]["name"], "GE-Proton11-7-x86_64")

    async def test_stale_cache_on_network_error(self):
        with mock.patch.object(net, "get_json", self.fake_get_json):
            await self.app.call("proton", "releases", {"source": "ge-proton"})

        def offline(*_a, **_k):
            raise net.ToolError("network")

        with mock.patch.object(net, "get_json", offline):
            res = await self.app.call("proton", "releases", {"source": "ge-proton", "refresh": True})
        self.assertTrue(res["data"]["stale"])
        with mock.patch.object(net, "get_json", offline):
            res = await self.app.call("proton", "releases", {"source": "proton-cachyos", "refresh": True})
        self.assertEqual(res, {"ok": False, "error": "network"})

    async def test_installed_uses_user_home(self):
        res = await self.app.call("proton", "installed")
        self.assertEqual(res["data"]["dir"], compat.compat_dir())
        self.assertTrue(res["data"]["dir"].startswith(self.tmp.name))


if __name__ == "__main__":
    unittest.main()

import asyncio
import os
import stat
import sys
import tempfile
import unittest
from unittest import mock

import _path  # noqa: F401
from deckytools.core import runtime
from deckytools.core.app import App
from deckytools.core.settings import SettingsStore
from deckytools.tools.monitor import MonitorTool

# 模拟 dt-monitor 协议的假子进程:stdin EOF 退出;live on 时推 sample;响应 info / history
FAKE = f"""#!{sys.executable}
import json, sys, select
def out(o):
    sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
n, live = 0, False
while True:
    r, _, _ = select.select([sys.stdin], [], [], 0.05)
    if r:
        line = sys.stdin.readline()
        if not line:
            break
        cmd = line.strip()
        if cmd in ("live on", "live off"):
            live = cmd == "live on"
        elif cmd == "info":
            out({{"type": "info", "data": {{"ip": "10.0.0.2", "hostname": "deck"}}}})
        elif cmd.startswith("history "):
            w, s = map(int, cmd.split()[1:])
            out({{"type": "history", "data": {{"step_ms": s * 1000, "keys": ["cpu_pct_x10"], "points": [[1]] * (w // s)}}}})
        else:
            out({{"type": "error", "code": "unknown_command"}})
    n += 1
    if live:
        out({{"type": "sample", "data": {{"cpu_pct_x10": n}}}})
"""


class MonitorTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.makedirs(os.path.join(self.tmp.name, "bin"))
        self.binary = os.path.join(self.tmp.name, "bin", "dt-monitor")
        self.env = mock.patch.dict(os.environ, {"DECKY_PLUGIN_DIR": self.tmp.name})
        self.env.start()
        self.events: list = []

        async def record(event, payload):
            self.events.append(payload)

        self.emit = mock.patch.object(runtime, "emit", record)
        self.emit.start()
        self.app = App([MonitorTool], SettingsStore(os.path.join(self.tmp.name, "s.json")))
        self.tool = self.app.tools["monitor"]

    async def asyncTearDown(self):
        await self.app.stop()
        self.emit.stop()
        self.env.stop()
        self.tmp.cleanup()

    def install_fake(self):
        with open(self.binary, "w") as f:
            f.write(FAKE)
        os.chmod(self.binary, os.stat(self.binary).st_mode | stat.S_IEXEC)

    def samples(self):
        return [e for e in self.events if e["type"] == "sample"]

    async def eventually(self, cond, what):
        for _ in range(150):
            if cond():
                return
            await asyncio.sleep(0.02)
        self.fail(what)

    async def test_missing_binary_is_unavailable(self):
        res = await self.app.call("monitor", "watch")
        self.assertEqual(res, {"ok": False, "error": "unavailable"})

    async def test_supervisor_keeps_child_running_without_live_push(self):
        self.install_fake()
        await self.app.start()
        await self.eventually(lambda: self.tool._child.running, "child not started")
        await asyncio.sleep(0.2)
        self.assertEqual(self.samples(), [])  # 没人看时不推送

    async def test_watch_streams_samples_and_info(self):
        self.install_fake()
        self.assertTrue((await self.app.call("monitor", "watch"))["ok"])
        await self.eventually(lambda: self.samples(), "no sample event")
        self.assertEqual(self.samples()[0]["tool"], "monitor")
        infos = await asyncio.gather(*[self.app.call("monitor", "info", {"refresh": True}) for _ in range(3)])
        self.assertTrue(all(i["data"]["ip"] == "10.0.0.2" for i in infos))
        again = await self.app.call("monitor", "watch")
        self.assertEqual(again["data"]["info"]["hostname"], "deck")

    async def test_history_ranges(self):
        self.install_fake()
        for window, buckets in ((120, 120), (1800, 180)):
            res = await self.app.call("monitor", "history", {"window": window})
            self.assertEqual(len(res["data"]["points"]), buckets)
        bad = await self.app.call("monitor", "history", {"window": 999})
        self.assertEqual(bad["error"], "invalid_request")

    async def test_lease_expiry_stops_live_push_but_keeps_child(self):
        self.install_fake()
        await self.app.call("monitor", "watch")
        await self.eventually(lambda: self.samples(), "no sample event")
        self.tool._lease_until = 0
        sleeps = iter([None, asyncio.CancelledError()])

        async def fake_sleep(_):
            item = next(sleeps)
            if item:
                raise item

        with mock.patch("deckytools.tools.monitor.tool.asyncio.sleep", fake_sleep):
            with self.assertRaises(asyncio.CancelledError):
                await self.tool._supervise()
        self.assertFalse(self.tool._live)
        self.assertTrue(self.tool._child.running)
        await asyncio.sleep(0.1)
        count = len(self.samples())
        await asyncio.sleep(0.2)
        self.assertEqual(len(self.samples()), count)

    async def test_crash_backoff(self):
        self.install_fake()
        await self.app.call("monitor", "watch")
        self.tool._child._proc.kill()
        await self.tool._child._proc.wait()
        res = await self.app.call("monitor", "watch")  # 刚崩溃,退避期内拒绝重启
        self.assertEqual(res["error"], "unavailable")


if __name__ == "__main__":
    unittest.main()

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
import json, os, sys, select
def out(o):
    sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
n, live, buf = 0, False, b""
while True:
    r, _, _ = select.select([0], [], [], 0.05)
    lines = []
    if r:
        chunk = os.read(0, 4096)  # 不用缓冲 readline:多条命令同时到达时 select 不会再次唤醒
        if not chunk:
            break
        buf += chunk
        *lines, buf = buf.split(b"\\n")
    for raw in lines:
        cmd = raw.decode().strip()
        if cmd in ("live on", "live off"):
            live = cmd == "live on"
        elif cmd == "info":
            out({{"type": "info", "data": {{"ip": "10.0.0.2", "hostname": "deck"}}}})
        elif cmd.startswith("history "):
            w, s = map(int, cmd.split()[1:])
            out({{"type": "history", "data": {{"step_ms": s * 1000, "keys": ["cpu_pct_x10", "apu_power_mw"], "points": [[n, 3000]] * (w // s)}}}})
        elif cmd:
            out({{"type": "error", "code": "unknown_command"}})
    n += 1
    if live:
        out({{"type": "sample", "data": {{"cpu_pct_x10": n, "apu_power_mw": 3000, "mem_used_mb": 4, "mem_total_mb": 16}}}})
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
        return [e for e in self.events if e["tool"] == "monitor" and e["type"] == "view"]

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

    async def test_watch_pushes_ready_to_render_view(self):
        self.install_fake()
        self.assertTrue((await self.app.call("monitor", "watch"))["ok"])
        await self.eventually(lambda: any(e["data"]["info"] for e in self.samples()), "no view with info")
        view = self.samples()[-1]["data"]
        self.assertEqual(view["range"], 120)
        self.assertEqual(view["capacity"], 120)
        self.assertEqual(view["current"]["mem_pct"], 25)
        self.assertEqual((view["current"]["power_mw"], view["current"]["power_source"]), (3000, "apu"))
        self.assertEqual(view["power_stats"], {"peak": 3000, "avg": 3000})
        self.assertEqual(view["info"]["ip"], "10.0.0.2")

    async def test_set_range(self):
        self.install_fake()
        await self.app.call("monitor", "watch")
        res = await self.app.call("monitor", "set_range", {"window": 1800})
        self.assertEqual((res["data"]["range"], res["data"]["capacity"]), (1800, 180))
        self.assertEqual(self.tool.ctx.settings.get("range"), 1800)
        bad = await self.app.call("monitor", "set_range", {"window": 999})
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

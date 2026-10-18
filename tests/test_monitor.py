import asyncio
import json
import os
import stat
import sys
import tempfile
import unittest
from unittest import mock

import _path  # noqa: F401
from deckytools.core import runtime
from deckytools.core.app import App
from deckytools.core.notify import Notifier
from deckytools.core.settings import SettingsStore
from deckytools.tools.monitor import MonitorTool
from deckytools.tools.monitor import tool as monitor_tool

# 模拟 dt-monitor 协议的假子进程:stdin EOF 退出;live <w> 时立即并每 50ms 推一帧快照
# (与 backend/src/view.zig 的输出格式一致);响应 info。
FAKE = f"""#!{sys.executable}
import json, os, sys, select
def out(line):
    sys.stdout.write(line + "\\n"); sys.stdout.flush()
def view(w, n):
    data = {{"range": w, "ranges": [120, 1800], "capacity": w // (1 if w == 120 else 10), "current": {{"cpu_pct": n}},
             "series": {{"cpu": [n]}}, "power_stats": None}}
    out('{{"type":"view","data":' + json.dumps(data, separators=(",", ":")) + "}}")
n, live, buf = 0, None, b""
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
        if cmd == "live off":
            live = None
        elif cmd.startswith("live "):
            live = int(cmd.split()[1])
            view(live, n)
        elif cmd == "info":
            out(json.dumps({{"type": "info", "data": {{"ip": "10.0.0.2", "hostname": "deck"}}}}))
        elif cmd:
            out(json.dumps({{"type": "error", "code": "unknown_command"}}))
    n += 1
    if live:
        view(live, n)
"""


class ParseViewLineTest(unittest.TestCase):
    def test_slices_without_parsing(self):
        line = b'{"type":"view","data":{"range":1800,"capacity":180}}\n'
        window, text = monitor_tool.parse_view_line(line)
        self.assertEqual(window, 1800)
        self.assertEqual(json.loads(text), {"range": 1800, "capacity": 180})

    def test_rejects_other_lines(self):
        for line in (b'{"type":"info","data":{}}\n', b'{"type":"view","data":{"range":x,"a":1}}\n',
                     b'{"type":"view","data":{"range":120,"a":1}}'):
            self.assertIsNone(monitor_tool.parse_view_line(line))


class MonitorTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.makedirs(os.path.join(self.tmp.name, "bin"))
        self.binary = os.path.join(self.tmp.name, "bin", "dt-monitor")
        self.env = mock.patch.dict(os.environ, {"DECKY_PLUGIN_DIR": self.tmp.name})
        self.env.start()
        self.events: list = []

        async def record(_event, payload):
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

    def views(self):
        return [e["data"] for e in self.events if e["tool"] == "monitor" and e["type"] == "view"]

    async def eventually(self, cond, what):
        for _ in range(150):
            if cond():
                return
            await asyncio.sleep(0.02)
        self.fail(what)

    async def start(self):
        self.install_fake()
        await self.app.start()
        await self.eventually(lambda: self.tool._child.running, "child not started")

    async def test_missing_binary_is_unavailable(self):
        res = await self.app.call("monitor", "watch")
        self.assertEqual(res, {"ok": False, "error": "unavailable"})

    async def test_no_push_until_watched(self):
        await self.start()
        await asyncio.sleep(0.2)
        self.assertEqual(self.views(), [])

    async def test_watch_returns_and_streams_raw_view_text(self):
        await self.start()
        res = (await self.app.call("monitor", "watch"))["data"]
        self.assertEqual(json.loads(res["view"])["range"], 120)  # 立即拿到一帧
        await self.eventually(lambda: len(self.views()) >= 3, "no streamed views")
        self.assertTrue(all(isinstance(v, str) for v in self.views()))  # 透传 JSON 文本
        await self.eventually(lambda: any(e["type"] == "info" for e in self.events), "no info event")
        info = next(e["data"] for e in self.events if e["type"] == "info")
        self.assertEqual(info["ip"], "10.0.0.2")
        self.assertEqual((await self.app.call("monitor", "watch"))["data"]["info"]["hostname"], "deck")
        heartbeat = (await self.app.call("monitor", "watch", {"snapshot": False}))["data"]
        self.assertEqual(heartbeat, {"view": None, "info": None})  # 续租不重复传快照

    async def test_set_range_waits_for_matching_view(self):
        await self.start()
        await self.app.call("monitor", "watch")
        res = (await self.app.call("monitor", "set_range", {"window": 1800}))["data"]
        self.assertEqual(json.loads(res["view"])["capacity"], 180)
        self.assertEqual(self.tool.ctx.settings.get("range"), 1800)
        bad = await self.app.call("monitor", "set_range", {"window": 999})
        self.assertEqual(bad["error"], "invalid_request")

    async def test_lease_expiry_stops_push_but_keeps_child(self):
        await self.start()
        with mock.patch.object(monitor_tool, "LEASE_SECONDS", 0.2):
            await self.app.call("monitor", "watch")
            await asyncio.sleep(0.5)
        count = len(self.views())
        await asyncio.sleep(0.3)
        self.assertEqual(len(self.views()), count)
        self.assertIsNone(self.tool._live)
        self.assertTrue(self.tool._child.running)

    async def test_supervisor_restarts_crashed_child_and_resumes_push(self):
        await self.start()
        await self.app.call("monitor", "watch")
        with mock.patch.object(monitor_tool, "_MAX_BACKOFF", 0.05):
            self.tool._child._proc.kill()
            await self.eventually(lambda: not self.tool._child.running, "child still alive")
            await self.eventually(lambda: self.tool._child.running, "child not restarted")
            before = len(self.views())
            await self.eventually(lambda: len(self.views()) > before + 2, "push not resumed")

    async def test_refresh_info(self):
        await self.start()
        res = await self.app.call("monitor", "refresh_info")
        self.assertEqual(res["data"]["hostname"], "deck")


class NotifierTest(unittest.IsolatedAsyncioTestCase):
    async def test_queue_and_ack(self):
        sent = []

        async def emit(note):
            sent.append(note)

        n = Notifier(emit)
        await n.add("proton", "install_done", {"name": "x"})
        await n.add("proton", "install_failed", {"name": "y", "error": "network"})
        self.assertEqual([x["id"] for x in sent], [x["id"] for x in n.pending()])
        n.ack([sent[0]["id"], "unknown"])
        self.assertEqual([x["key"] for x in n.pending()], ["install_failed"])
        for i in range(30):
            await n.add("t", f"k{i}")
        self.assertEqual(len(n.pending()), 20)


if __name__ == "__main__":
    unittest.main()

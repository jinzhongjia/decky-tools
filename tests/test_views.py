import unittest

import _path  # noqa: F401
from deckytools.core.notify import Notifier
from deckytools.tools.monitor import view


class MonitorViewTest(unittest.IsolatedAsyncioTestCase):
    def test_power_prefers_apu_and_ignores_charging(self):
        self.assertEqual(view.power_mw(3000, 9000), 3000)
        self.assertEqual(view.power_mw(None, 9000), 9000)
        self.assertIsNone(view.power_mw(None, -5000))
        self.assertIsNone(view.power_mw(None, None))

    def test_series_scales_and_keeps_gaps(self):
        h = {"keys": ["cpu_pct_x10", "mem_pct_x10", "apu_power_mw", "battery_power_mw"],
             "points": [[125, 500, None, 4000], [None, None, None, None]]}
        s = view.series(h)
        self.assertEqual(s["cpu"], [12.5, None])
        self.assertEqual(s["memory"], [50, None])
        self.assertEqual(s["power"], [4000, None])
        self.assertEqual(s["gpu"], [None, None])  # 缺失的键 → 全 None,长度一致

    def test_stats_need_two_points(self):
        self.assertIsNone(view.stats([None, 5]))
        self.assertEqual(view.stats([2, None, 4]), {"peak": 4, "avg": 3})

    def test_current_without_apu_uses_battery(self):
        c = view.current({"battery_power_mw": 6000, "mem_used_mb": 1, "mem_total_mb": 4})
        self.assertEqual((c["power_mw"], c["power_source"], c["mem_pct"]), (6000, "battery", 25))

    async def test_notifier_queue_and_ack(self):
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

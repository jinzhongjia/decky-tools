import unittest
from unittest import mock

import _path  # noqa: F401
from deckytools.tools.proton import cpu, sources


def asset(name, size=1):
    return {"name": name, "size": size, "browser_download_url": f"https://github.com/x/{name}"}


class PickAssetTest(unittest.TestCase):
    def pick(self, source_id, names, v3):
        with mock.patch.object(cpu, "supports_v3", return_value=v3):
            hit = sources.pick_asset(sources.BY_ID[source_id], [asset(n) for n in names])
        return hit and hit["name"]

    def test_ge_skips_aarch64(self):
        names = ["GE-Proton11-7-aarch64.tar.gz", "GE-Proton11-7-x86_64.tar.gz", "GE-Proton11-7-x86_64.sha512sum"]
        self.assertEqual(self.pick("ge-proton", names, True), "GE-Proton11-7-x86_64.tar.gz")

    def test_ge_legacy_name(self):
        self.assertEqual(self.pick("ge-proton", ["GE-Proton10-34.tar.gz"], False), "GE-Proton10-34.tar.gz")

    def test_cachyos_variant_by_cpu(self):
        names = ["proton-cachyos-11.0-1-slr-arm64.tar.xz", "proton-cachyos-11.0-1-slr-x86_64.tar.xz",
                 "proton-cachyos-11.0-1-slr-x86_64_v3.tar.xz"]
        self.assertEqual(self.pick("proton-cachyos", names, True), names[2])
        self.assertEqual(self.pick("proton-cachyos", names, False), names[1])


class ParseReleasesTest(unittest.TestCase):
    def test_parse(self):
        payload = [
            {"tag_name": "GE-Proton11-7", "assets": [asset("GE-Proton11-7-x86_64.tar.gz", 9),
                                                     asset("GE-Proton11-7-x86_64.sha512sum")]},
            {"tag_name": "draft", "draft": True, "assets": [asset("GE-Proton1-x86_64.tar.gz")]},
            {"tag_name": "noasset", "assets": []},
            "garbage",
        ]
        out = sources.parse_releases(sources.BY_ID["ge-proton"], payload)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["name"], "GE-Proton11-7-x86_64")
        self.assertEqual(out[0]["size"], 9)
        self.assertTrue(out[0]["checksum_url"].endswith(".sha512sum"))
        self.assertEqual(sources.parse_releases(sources.BY_ID["ge-proton"], {"message": "x"}), [])

    def test_cpu_flags(self):
        self.assertIn("avx2", cpu.parse_flags("processor: 0\nflags\t\t: fpu avx2 bmi2\n"))


if __name__ == "__main__":
    unittest.main()

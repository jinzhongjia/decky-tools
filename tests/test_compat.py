import io
import os
import tarfile
import tempfile
import unittest

import _path  # noqa: F401
from deckytools.core.errors import ToolError
from deckytools.tools.proton import compat

VDF = b'"compatibilitytools" { "compat_tools" { "X" { "display_name" "Fancy X" } } }'


def make_tar(path, entries):
    """entries: (name, kind, payload) kind ∈ file/dir/sym/lnk"""
    with tarfile.open(path, "w:gz") as tar:
        for name, kind, payload in entries:
            info = tarfile.TarInfo(name)
            if kind == "dir":
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tar.addfile(info)
            elif kind in ("sym", "lnk"):
                info.type = tarfile.SYMTYPE if kind == "sym" else tarfile.LNKTYPE
                info.linkname = payload
                tar.addfile(info)
            else:
                info.size = len(payload)
                tar.addfile(info, io.BytesIO(payload))


def noop(*_):
    pass


class ExtractTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = os.path.join(self.tmp.name, "compat")
        os.makedirs(self.base)
        self.archive = os.path.join(self.tmp.name, "a.tar.gz")

    def tearDown(self):
        self.tmp.cleanup()

    def extract(self, entries):
        make_tar(self.archive, entries)
        return compat.extract(self.archive, self.base, noop, noop)

    def leftovers(self):
        return [n for n in os.listdir(self.base) if n.startswith(compat.STAGING_PREFIX)]

    def test_installs_and_lists(self):
        name = self.extract([
            ("X/", "dir", None),
            ("X/compatibilitytool.vdf", "file", VDF),
            ("X/proton", "file", b"#!/bin/sh"),
            ("X/link", "sym", "proton"),
        ])
        self.assertEqual(name, "X")
        self.assertEqual(os.stat(os.path.join(self.base, "X")).st_mode & 0o777, 0o755)
        self.assertTrue(os.path.islink(os.path.join(self.base, "X", "link")))
        tools = compat.list_installed(self.base)
        self.assertEqual([(t["name"], t["display_name"]) for t in tools], [("X", "Fancy X")])
        self.assertEqual(self.leftovers(), [])

    def assertRejected(self, entries, code="extract_failed"):
        with self.assertRaises(ToolError) as cm:
            self.extract(entries)
        self.assertEqual(cm.exception.code, code)
        self.assertEqual(self.leftovers(), [])
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "evil")))

    def test_rejects_traversal(self):
        self.assertRejected([("X/compatibilitytool.vdf", "file", VDF), ("X/../../evil", "file", b"x")])

    def test_rejects_absolute_symlink(self):
        self.assertRejected([("X/compatibilitytool.vdf", "file", VDF), ("X/l", "sym", "/etc/passwd")])

    def test_rejects_escaping_symlink(self):
        self.assertRejected([("X/compatibilitytool.vdf", "file", VDF), ("X/l", "sym", "../../../evil")])

    def test_rejects_multiple_tops(self):
        self.assertRejected([("X/compatibilitytool.vdf", "file", VDF), ("Y/f", "file", b"")])

    def test_requires_manifest(self):
        self.assertRejected([("X/proton", "file", b"")])

    def test_already_installed(self):
        os.makedirs(os.path.join(self.base, "X"))
        self.assertRejected([("X/compatibilitytool.vdf", "file", VDF)], code="already_installed")

    def test_cancel_cleans_staging(self):
        make_tar(self.archive, [("X/compatibilitytool.vdf", "file", VDF)])

        def cancel():
            raise ToolError("cancelled")

        with self.assertRaises(ToolError):
            compat.extract(self.archive, self.base, noop, cancel)
        self.assertEqual(os.listdir(self.base), [])


class RemoveTest(unittest.TestCase):
    def test_remove_validates_name(self):
        with tempfile.TemporaryDirectory() as base:
            for bad in ("..", "../x", "a/b", "", ".hidden"):
                with self.assertRaises(ToolError):
                    compat.remove(base, bad)

    def test_skips_linux_runtimes(self):
        with tempfile.TemporaryDirectory() as base:
            os.makedirs(os.path.join(base, "LegacyRuntime"))
            with open(os.path.join(base, "LegacyRuntime", compat.MANIFEST), "w") as f:
                f.write('"display_name" "Legacy" "from_oslist" "linux" "to_oslist" "linux"')
            self.assertEqual(compat.list_installed(base), [])
            with self.assertRaises(ToolError):
                compat.remove(base, "LegacyRuntime")
            self.assertTrue(os.path.isdir(os.path.join(base, "LegacyRuntime")))

    def test_remove_only_tools(self):
        with tempfile.TemporaryDirectory() as base:
            os.makedirs(os.path.join(base, "notatool"))
            with self.assertRaises(ToolError):
                compat.remove(base, "notatool")
            os.makedirs(os.path.join(base, "T"))
            open(os.path.join(base, "T", compat.MANIFEST), "w").close()
            compat.remove(base, "T")
            self.assertFalse(os.path.exists(os.path.join(base, "T")))


if __name__ == "__main__":
    unittest.main()

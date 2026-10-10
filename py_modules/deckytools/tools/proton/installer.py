"""安装流水线(阻塞,在任务线程里跑):空间检查 → 下载(可续传)→ sha512 校验 → 安全解压。"""

import errno
import hashlib
import os
import re
import shutil
from typing import Any

from ...core import net
from ...core.errors import CHECKSUM_MISMATCH, DISK_FULL, Cancelled, ToolError
from ...core.tasks import TaskHandle
from . import compat

# 解压后体积约为压缩包的 3~4 倍,再加上压缩包本身
_SPACE_FACTOR = 5
_HEX = re.compile(r"\b([0-9a-fA-F]{128})\b")


def _ensure_space(path: str, need: int) -> None:
    if need and shutil.disk_usage(path).free < need:
        raise ToolError(DISK_FULL, f"need {need // (1 << 20)} MiB")


def _expected_sha512(url: str, mirror: str) -> str:
    if not url:
        return ""
    m = _HEX.search(net.get_text(net.mirror_url(url, mirror)))
    return m.group(1).lower() if m else ""


def _verify(handle: TaskHandle, archive: str, expected: str) -> None:
    total = os.path.getsize(archive)
    handle.stage("verify", total)
    digest, done = hashlib.sha512(), 0
    with open(archive, "rb") as f:
        while chunk := f.read(1 << 20):
            handle.check()
            digest.update(chunk)
            done += len(chunk)
            handle.progress(done)
    if digest.hexdigest() != expected:
        raise ToolError(CHECKSUM_MISMATCH)


def install(handle: TaskHandle, release: dict[str, Any], base: str, download_dir: str, mirror: str) -> str:
    os.makedirs(download_dir, exist_ok=True)
    archive = os.path.join(download_dir, os.path.basename(release["asset"]))
    _ensure_space(base, release["size"] * _SPACE_FACTOR)
    try:
        expected = _expected_sha512(release["checksum_url"], mirror)
        handle.stage("download", release["size"])
        net.download(net.mirror_url(release["url"], mirror), archive, handle.progress, handle.check)
        if expected:
            _verify(handle, archive, expected)
        handle.stage("extract", os.path.getsize(archive))
        return compat.extract(archive, base, handle.progress, handle.check)
    except OSError as e:
        if e.errno == errno.ENOSPC:
            raise ToolError(DISK_FULL) from None
        raise
    except Cancelled:
        _remove(archive + ".part")  # 主动取消不保留续传文件
        raise
    finally:
        _remove(archive)


def _remove(path: str) -> None:
    try:
        os.remove(path)
    except FileNotFoundError:
        pass

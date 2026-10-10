"""Steam compatibilitytools.d 目录操作:列出、安全解压安装、卸载。全部为阻塞函数,调用方放线程。"""

import errno
import os
import platform
import re
import shutil
import tarfile
import tempfile
from typing import Any, Callable

from ...core import runtime
from ...core.errors import ALREADY_INSTALLED, DISK_FULL, EXTRACT_FAILED, INVALID_REQUEST, NOT_FOUND, ToolError

MANIFEST = "compatibilitytool.vdf"
STAGING_PREFIX = ".decky-tools-"
_NAME_OK = re.compile(r"^[\w][\w.+-]*$")
_DISPLAY = re.compile(r'"display_name"\s+"([^"]*)"')
_FOREIGN_ARCH = re.compile(r"(aarch64|arm64)", re.I) if platform.machine() == "x86_64" else None
_FROM_OS = re.compile(r'"from_oslist"\s+"([^"]*)"')


def compat_dir() -> str:
    """优先 ~/.steam/root(指向实际 Steam 安装),不存在时退回默认路径;目录不存在则创建。"""
    home = runtime.user_home()
    root = os.path.join(home, ".steam", "root")
    base = os.path.realpath(root) if os.path.isdir(root) else os.path.join(home, ".local", "share", "Steam")
    path = os.path.join(base, "compatibilitytools.d")
    os.makedirs(path, exist_ok=True)
    return path


def _read_manifest(manifest: str) -> tuple[str, str]:
    """返回 (display_name, from_oslist);读不了时为空串。"""
    try:
        with open(manifest, encoding="utf-8", errors="replace") as f:
            text = f.read(64 * 1024)
    except OSError:
        return "", ""
    display, from_os = _DISPLAY.search(text), _FROM_OS.search(text)
    return (display.group(1) if display else ""), (from_os.group(1) if from_os else "")


def list_installed(base: str) -> list[dict[str, Any]]:
    """只列 Windows→Linux 的兼容层(Proton 类);Steam 自带的 LegacyRuntime 等 Linux 运行时不归本工具管。"""
    out = []
    for entry in sorted(os.scandir(base), key=lambda e: e.name.lower()):
        if entry.name.startswith(".") or not entry.is_dir():
            continue
        manifest = os.path.join(entry.path, MANIFEST)
        if not os.path.isfile(manifest):
            continue
        display, from_os = _read_manifest(manifest)
        if from_os and "windows" not in from_os:
            continue
        out.append({
            "name": entry.name,
            "display_name": display or entry.name,
            "symlink": entry.is_symlink(),
            # 名字带其它架构标记(如 x86 设备上的 aarch64 包):Steam 能列出但游戏跑不起来
            "foreign_arch": bool(_FOREIGN_ARCH and _FOREIGN_ARCH.search(entry.name)),
            "mtime": int(entry.stat().st_mtime),
        })
    return out


def _target(base: str, name: str) -> str:
    if not isinstance(name, str) or not _NAME_OK.match(name):
        raise ToolError(INVALID_REQUEST, "bad tool name")
    return os.path.join(base, name)


def remove(base: str, name: str) -> None:
    path = _target(base, name)
    if os.path.islink(path):  # 用户自建的软链只删链接本身,不碰目标
        os.unlink(path)
        return
    manifest = os.path.join(path, MANIFEST)
    if not os.path.isfile(manifest):
        raise ToolError(NOT_FOUND, "not a compatibility tool")
    _, from_os = _read_manifest(manifest)
    if from_os and "windows" not in from_os:
        raise ToolError(INVALID_REQUEST, "not a proton tool")
    shutil.rmtree(path)


def cleanup_staging(base: str) -> None:
    """清理上次中断(插件重启/断电)残留的暂存目录。"""
    for entry in os.scandir(base):
        if entry.name.startswith(STAGING_PREFIX) and entry.is_dir(follow_symlinks=False):
            shutil.rmtree(entry.path, ignore_errors=True)


def _inside(root: str, path: str) -> bool:
    return os.path.commonpath([root, os.path.realpath(path)]) == root


def _check_member(m: tarfile.TarInfo, stage: str) -> str:
    """校验成员不越界,返回其顶层目录名。"""
    parts = [p for p in m.name.split("/") if p not in ("", ".")]
    if not parts or m.name.startswith("/") or ".." in parts:
        raise ToolError(EXTRACT_FAILED, "unsafe path in archive")
    if not (m.isfile() or m.isdir() or m.issym() or m.islnk()):
        raise ToolError(EXTRACT_FAILED, "unsupported member type in archive")
    dest = os.path.join(stage, *parts)
    if m.issym():
        link = os.path.join(os.path.dirname(dest), m.linkname)
        if os.path.isabs(m.linkname) or not _inside(stage, link):
            raise ToolError(EXTRACT_FAILED, "symlink escapes archive")
    if m.islnk() and not _inside(stage, os.path.join(stage, m.linkname)):
        raise ToolError(EXTRACT_FAILED, "hardlink escapes archive")
    return parts[0]


def extract(
    archive: str, base: str, on_progress: Callable[[int, int], None], check_cancel: Callable[[], None]
) -> str:
    """解压到 base 下的暂存目录,校验后原子改名到 base/<顶层目录>;返回安装名。"""
    stage = tempfile.mkdtemp(prefix=STAGING_PREFIX, dir=base)
    stage = os.path.realpath(stage)
    total = os.path.getsize(archive)
    try:
        top = _extract_into(archive, stage, total, on_progress, check_cancel)
        target = _target(base, top)
        if os.path.lexists(target):
            raise ToolError(ALREADY_INSTALLED, top)
        if not os.path.isfile(os.path.join(stage, top, MANIFEST)):
            raise ToolError(EXTRACT_FAILED, "archive has no compatibilitytool.vdf")
        os.rename(os.path.join(stage, top), target)
        return top
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def _extract_into(archive, stage, total, on_progress, check_cancel) -> str:
    tops: set[str] = set()
    dirs: list[tarfile.TarInfo] = []
    try:
        with open(archive, "rb") as raw, tarfile.open(fileobj=raw, mode="r:*") as tar:
            for member in tar:
                check_cancel()
                tops.add(_check_member(member, stage))
                if len(tops) > 1:
                    raise ToolError(EXTRACT_FAILED, "archive has multiple top-level entries")
                _extract_member(tar, member, stage)
                if member.isdir():
                    dirs.append(member)
                on_progress(raw.tell(), total)
        _apply_dir_modes(dirs, stage)
    except (tarfile.TarError, EOFError, OSError) as e:
        if isinstance(e, OSError) and e.errno == errno.ENOSPC:
            raise ToolError(DISK_FULL) from None
        raise ToolError(EXTRACT_FAILED, type(e).__name__) from None
    if not tops:
        raise ToolError(EXTRACT_FAILED, "empty archive")
    return tops.pop()


def _apply_dir_modes(dirs: list[tarfile.TarInfo], stage: str) -> None:
    """补上推迟的目录权限(tarfile 建目录时用 0700);去掉组/其他写位,保证属主可写。"""
    for member in reversed(dirs):
        os.chmod(os.path.join(stage, member.name), (member.mode & 0o755) | 0o700)


def _extract_member(tar: tarfile.TarFile, member: tarfile.TarInfo, stage: str) -> None:
    # 成员已由 _check_member 校验;Python 3.12+ 需显式指定 filter,"tar" 保留可执行位与相对软链。
    # 目录不立即套用归档权限(extractall 会推迟到最后),否则只读目录会挡住后续成员写入。
    kwargs = {"filter": "tar"} if hasattr(tarfile, "tar_filter") else {}
    tar.extract(member, stage, set_attrs=not member.isdir(), **kwargs)

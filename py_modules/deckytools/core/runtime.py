"""对 Decky 注入的 `decky` 模块做一层隔离:插件内运行时用真模块,单测/本机时退化为 stdlib。"""

import logging
import os
import tempfile
from typing import Any

try:
    import decky  # type: ignore[import-not-found]
except ImportError:  # 单测环境
    decky = None


def _env_dir(name: str, fallback: str) -> str:
    value = getattr(decky, name, None) if decky else None
    value = value or os.environ.get(name) or os.path.join(tempfile.gettempdir(), "decky-tools", fallback)
    os.makedirs(value, exist_ok=True)
    return value


def settings_dir() -> str:
    return _env_dir("DECKY_PLUGIN_SETTINGS_DIR", "settings")


def runtime_dir() -> str:
    return _env_dir("DECKY_PLUGIN_RUNTIME_DIR", "data")


def plugin_dir() -> str:
    value = getattr(decky, "DECKY_PLUGIN_DIR", "") if decky else ""
    return value or os.environ.get("DECKY_PLUGIN_DIR") or os.getcwd()


def user_home() -> str:
    """Steam 所在用户的 home;插件不带 root flag 时与 HOME 相同。"""
    home = getattr(decky, "DECKY_USER_HOME", "") if decky else ""
    return home or os.environ.get("DECKY_USER_HOME") or os.path.expanduser("~")


def logger() -> logging.Logger:
    return decky.logger if decky else logging.getLogger("decky-tools")


async def emit(event: str, *args: Any) -> None:
    if decky:
        await decky.emit(event, *args)

"""插件配置:单个 JSON 文件,按工具 id 分命名空间,原子写。"""

import json
import os
import threading
from typing import Any

from . import runtime
from .log import Logger

_log = Logger("core")


class SettingsStore:
    def __init__(self, path: str | None = None):
        self.path = path or os.path.join(runtime.settings_dir(), "settings.json")
        self._lock = threading.Lock()
        self._data: dict[str, dict[str, Any]] = self._load()

    def _load(self) -> dict[str, dict[str, Any]]:
        try:
            with open(self.path, encoding="utf-8") as f:
                data = json.load(f)
            return {k: v for k, v in data.items() if isinstance(v, dict)} if isinstance(data, dict) else {}
        except FileNotFoundError:
            return {}
        except (OSError, ValueError) as e:
            _log.warn("settings", f"unreadable settings file, starting fresh ({type(e).__name__})")
            return {}

    def _save(self) -> None:
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self._data, f, ensure_ascii=False, indent=2)
        os.replace(tmp, self.path)

    def get(self, ns: str, key: str, default: Any = None) -> Any:
        with self._lock:
            return self._data.get(ns, {}).get(key, default)

    def all(self, ns: str) -> dict[str, Any]:
        with self._lock:
            return dict(self._data.get(ns, {}))

    def set(self, ns: str, key: str, value: Any) -> None:
        with self._lock:
            self._data.setdefault(ns, {})[key] = value
            self._save()

    def scoped(self, ns: str) -> "ScopedSettings":
        return ScopedSettings(self, ns)


class ScopedSettings:
    """工具拿到的配置视图,只能读写自己的命名空间。"""

    def __init__(self, store: SettingsStore, ns: str):
        self._store, self._ns = store, ns

    def get(self, key: str, default: Any = None) -> Any:
        return self._store.get(self._ns, key, default)

    def set(self, key: str, value: Any) -> None:
        self._store.set(self._ns, key, value)

    def all(self) -> dict[str, Any]:
        return self._store.all(self._ns)

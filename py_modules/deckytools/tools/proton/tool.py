"""Proton 运行时管理:浏览各源发布、下载安装到 compatibilitytools.d、卸载。

本工具持有全部界面状态并推送完整快照(view 事件),前端只渲染、只回传用户操作。
"""

import asyncio
import os
import time
from typing import Any

from ...core import net
from ...core.errors import INTERNAL, INVALID_REQUEST, NOT_FOUND, Cancelled, ToolError
from ...core.tasks import TaskHandle
from ...core.tool import Tool, rpc
from . import compat, cpu, installer, steam
from .sources import BY_ID, SOURCES, Source, parse_releases

_CACHE_TTL = 15 * 60
_STEAM_CHECK_TTL = 5  # 快照推送很频繁(下载进度),/proc 扫描结果短暂缓存
_PER_PAGE = 30


class ProtonTool(Tool):
    id = "proton"

    def __init__(self, ctx):
        super().__init__(ctx)
        self._cache: dict[str, tuple[float, list[dict[str, Any]]]] = {}
        self._fetching: dict[str, asyncio.Task] = {}
        self._errors: dict[str, str] = {}  # 源 → 最近一次拉取失败的错误码
        self._stale: set[str] = set()
        self._installed: list[dict[str, Any]] | None = None
        self._push_task: asyncio.Task | None = None
        self._dirty = False
        self._steam_checked: tuple[float, float | None] = (0.0, None)

    async def start(self) -> None:
        await asyncio.to_thread(compat.cleanup_staging, compat.compat_dir())

    # ---- 用户操作 ----

    @rpc
    async def view(self) -> dict[str, Any]:
        """当前完整快照;发布列表缺失或过期时顺带在后台拉取(完成后推送 view 事件)。"""
        if self._installed is None:
            await self._reload_installed()
        self._ensure_releases(self._source(), force=False)
        return self._snapshot()

    @rpc
    async def select_source(self, source: str) -> dict[str, Any]:
        if source not in BY_ID:
            raise ToolError(INVALID_REQUEST, "unknown source")
        self.ctx.settings.set("source", source)
        self._ensure_releases(BY_ID[source], force=False)
        return self._snapshot()

    @rpc
    async def refresh(self) -> dict[str, Any]:
        self._ensure_releases(self._source(), force=True)
        return self._snapshot()

    @rpc
    async def install(self, tag: str) -> dict[str, Any]:
        src = self._source()
        release = next((r for r in self._releases(src) if r["tag"] == tag), None)
        if not release:
            raise ToolError(NOT_FOUND, "release not found")
        self.ctx.start_task(
            "install", f"{src.id}:{tag}", release["name"], self._install_body(release),
            {"source": src.id, "tag": tag, "name": release["name"]}, lambda _t: self._schedule_push(),
        )
        return self._snapshot()

    @rpc
    async def uninstall(self, name: str) -> dict[str, Any]:
        await asyncio.to_thread(compat.remove, compat.compat_dir(), name)
        self.ctx.log.info("uninstall", f"removed {name}")
        self._mark_restart()
        await self._reload_installed()
        return self._snapshot()

    @rpc
    async def restart_steam(self) -> None:
        await self.ctx.command("restart_steam")

    # ---- 安装 ----

    def _install_body(self, release: dict[str, Any]):
        mirror = self.ctx.core_settings.get("github_mirror", "")
        base = compat.compat_dir()
        download_dir = os.path.join(self.ctx.data_dir, "downloads")
        name = release["name"]

        async def body(handle: TaskHandle) -> None:
            try:
                installed = await asyncio.to_thread(installer.install, handle, release, base, download_dir, mirror)
            except Cancelled:
                raise
            except ToolError as e:
                await self.ctx.notify("install_failed", {"name": name, "error": e.code})
                raise
            except Exception:
                await self.ctx.notify("install_failed", {"name": name, "error": INTERNAL})
                raise
            self.ctx.log.info("install", f"installed {installed}")
            self._mark_restart()
            await self._reload_installed()
            await self.ctx.notify("install_done", {"name": name})

        return body

    # ---- 发布列表 ----

    def _source(self) -> Source:
        return BY_ID.get(self.ctx.settings.get("source", ""), SOURCES[0])

    def _releases(self, src: Source) -> list[dict[str, Any]]:
        cached = self._cache.get(src.id)
        return cached[1] if cached else []

    def _ensure_releases(self, src: Source, force: bool) -> None:
        cached = self._cache.get(src.id)
        fresh = cached and time.time() - cached[0] < _CACHE_TTL
        if (fresh and not force) or src.id in self._fetching:
            return
        self._fetching[src.id] = asyncio.create_task(self._fetch(src))

    async def _fetch(self, src: Source) -> None:
        self._schedule_push()  # 推送 loading 状态
        url = f"https://api.github.com/repos/{src.repo}/releases?per_page={_PER_PAGE}"
        try:
            payload = await asyncio.to_thread(net.get_json, url)
            self._cache[src.id] = (time.time(), parse_releases(src, payload))
            self._errors.pop(src.id, None)
            self._stale.discard(src.id)
            self.ctx.log.info("releases", f"{src.id}: {len(self._cache[src.id][1])} releases")
        except ToolError as e:
            self._errors[src.id] = e.code
            if src.id in self._cache:
                self._stale.add(src.id)  # 网络失败但有旧缓存:继续展示并提示
        finally:
            self._fetching.pop(src.id, None)
            self._schedule_push()

    # ---- 已安装 / 重启 ----

    async def _reload_installed(self) -> None:
        self._installed = await asyncio.to_thread(compat.list_installed, compat.compat_dir())
        self._schedule_push()

    def _mark_restart(self) -> None:
        self.ctx.settings.set("restart_marked_at", time.time())

    def _restart_needed(self) -> bool:
        """兼容层变化之后 Steam 还没重启过 → 需要重启;重启过就自动清除标记。"""
        marked = self.ctx.settings.get("restart_marked_at")
        if not marked:
            return False
        checked_at, started = self._steam_checked
        if time.monotonic() - checked_at > _STEAM_CHECK_TTL:
            started = steam.steam_started_at()
            self._steam_checked = (time.monotonic(), started)
        if started is not None and started > marked:
            self.ctx.settings.set("restart_marked_at", None)
            return False
        return True

    # ---- 快照 ----

    def _snapshot(self) -> dict[str, Any]:
        src = self._source()
        installed = self._installed or []
        names = {t["name"] for t in installed}
        releases = [
            {
                "tag": r["tag"], "published": r["published"], "size": r["size"], "prerelease": r["prerelease"],
                "latest": i == 0 and not r["prerelease"], "installed": r["name"] in names,
                "task": self.ctx.task_snapshot(f"{src.id}:{r['tag']}"),
            }
            for i, r in enumerate(self._releases(src))
        ]
        return {
            "sources": [{"id": s.id, "name": s.name, "v3": bool(s.v3_patterns) and cpu.supports_v3()} for s in SOURCES],
            "source": src.id,
            "releases": releases,
            "releases_loaded": src.id in self._cache,
            "loading": src.id in self._fetching,
            "stale": src.id in self._stale,
            "error": self._errors.get(src.id),
            "installed": installed,
            "installed_loaded": self._installed is not None,
            "restart_needed": self._restart_needed(),
        }

    def _schedule_push(self) -> None:
        """合并短时间内的多次变化,串行推送最新快照。"""
        self._dirty = True
        if self._push_task is None or self._push_task.done():
            self._push_task = asyncio.create_task(self._push_loop())

    async def _push_loop(self) -> None:
        while self._dirty:
            self._dirty = False
            await self.ctx.emit("view", self._snapshot())
            await asyncio.sleep(0)

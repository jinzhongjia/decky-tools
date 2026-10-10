"""Proton 运行时管理:浏览各源发布、下载安装到 compatibilitytools.d、卸载。"""

import asyncio
import os
import time
from typing import Any

from ...core import net
from ...core.errors import INVALID_REQUEST, NOT_FOUND, ToolError
from ...core.tasks import TaskHandle
from ...core.tool import Tool, rpc
from . import compat, cpu, installer
from .sources import BY_ID, SOURCES, Source, parse_releases

_CACHE_TTL = 15 * 60
_PER_PAGE = 30


class ProtonTool(Tool):
    id = "proton"

    def __init__(self, ctx):
        super().__init__(ctx)
        self._cache: dict[str, tuple[float, list[dict[str, Any]]]] = {}
        self._fetch_locks: dict[str, asyncio.Lock] = {}

    async def start(self) -> None:
        await asyncio.to_thread(compat.cleanup_staging, compat.compat_dir())

    def _source(self, source: str) -> Source:
        if source not in BY_ID:
            raise ToolError(INVALID_REQUEST, "unknown source")
        return BY_ID[source]

    @rpc
    async def sources(self) -> dict[str, Any]:
        return {"sources": [s.to_dict() for s in SOURCES], "x86_64_v3": cpu.supports_v3()}

    @rpc
    async def releases(self, source: str, refresh: bool = False) -> dict[str, Any]:
        src = self._source(source)
        requested = time.time()
        # 同一源的并发请求串行化:后到者直接复用前者刚拉到的结果,省 GitHub API 配额
        async with self._fetch_locks.setdefault(src.id, asyncio.Lock()):
            cached = self._cache.get(src.id)
            if cached and (cached[0] >= requested or (not refresh and requested - cached[0] < _CACHE_TTL)):
                return {"releases": cached[1], "fetched": cached[0]}
            return await self._fetch_releases(src, cached)

    async def _fetch_releases(self, src: Source, cached: tuple[float, list[dict[str, Any]]] | None) -> dict[str, Any]:
        url = f"https://api.github.com/repos/{src.repo}/releases?per_page={_PER_PAGE}"
        try:
            payload = await asyncio.to_thread(net.get_json, url)
        except ToolError:
            if cached:  # 网络失败时回退到旧缓存,前端据 stale 提示
                return {"releases": cached[1], "fetched": cached[0], "stale": True}
            raise
        releases = parse_releases(src, payload)
        self._cache[src.id] = (time.time(), releases)
        self.ctx.log.info("releases", f"{src.id}: {len(releases)} releases")
        return {"releases": releases, "fetched": time.time()}

    @rpc
    async def installed(self) -> dict[str, Any]:
        base = compat.compat_dir()
        return {"dir": base, "tools": await asyncio.to_thread(compat.list_installed, base)}

    @rpc
    async def tasks(self) -> list[dict[str, Any]]:
        return self.ctx.tasks()

    @rpc
    async def install(self, source: str, tag: str) -> dict[str, Any]:
        src = self._source(source)
        release = await self._find_release(src, tag)
        mirror = self.ctx.core_settings.get("github_mirror", "")
        base = compat.compat_dir()
        download_dir = os.path.join(self.ctx.data_dir, "downloads")

        async def body(handle: TaskHandle) -> None:
            name = await asyncio.to_thread(installer.install, handle, release, base, download_dir, mirror)
            handle.task.meta["installed"] = name
            self.ctx.log.info("install", f"installed {name}")
            await self._push_installed()

        meta = {"source": src.id, "tag": release["tag"], "name": release["name"]}
        return self.ctx.start_task("install", f"{src.id}:{release['tag']}", release["name"], body, meta)

    @rpc
    async def uninstall(self, name: str) -> dict[str, Any]:
        base = compat.compat_dir()
        await asyncio.to_thread(compat.remove, base, name)
        self.ctx.log.info("uninstall", f"removed {name}")
        return await self._push_installed()

    async def _find_release(self, src: Source, tag: str) -> dict[str, Any]:
        for refresh in (False, True):
            listing = await self.releases(src.id, refresh)
            hit = next((r for r in listing["releases"] if r["tag"] == tag), None)
            if hit:
                return hit
        raise ToolError(NOT_FOUND, "release not found")

    async def _push_installed(self) -> dict[str, Any]:
        state = await self.installed()
        await self.ctx.emit("installed", state)
        return state

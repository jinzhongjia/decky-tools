"""Proton 发行源:数据驱动,新增一个 GitHub Release 源只需在 SOURCES 加一项。"""

import re
from dataclasses import dataclass
from typing import Any

from . import cpu

_ARCHIVE = re.compile(r"\.tar\.(gz|xz|zst)$")


@dataclass(frozen=True)
class Source:
    id: str
    name: str
    repo: str  # owner/name
    # 候选资源按优先级排列;CPU 支持 x86-64-v3 时 v3 变体优先(仅对提供该变体的源生效)
    patterns: tuple[str, ...]
    v3_patterns: tuple[str, ...] = ()
    homepage: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "repo": self.repo,
            "homepage": self.homepage or f"https://github.com/{self.repo}",
            "has_v3": bool(self.v3_patterns),
        }


SOURCES: tuple[Source, ...] = (
    Source(
        id="ge-proton",
        name="GE-Proton",
        repo="GloriousEggroll/proton-ge-custom",
        # 新版同时发 x86_64/aarch64 两个包;老版只有不带架构后缀的包
        patterns=(r"^GE-Proton[\w.-]*-x86_64\.tar\.gz$", r"^GE-Proton[\d.-]+(rc\d+)?\.tar\.gz$"),
    ),
    Source(
        id="proton-cachyos",
        name="Proton-CachyOS",
        repo="CachyOS/proton-cachyos",
        patterns=(r"^proton-cachyos-[\w.-]*-x86_64\.tar\.xz$",),
        v3_patterns=(r"^proton-cachyos-[\w.-]*-x86_64_v3\.tar\.xz$",),
    ),
)

BY_ID = {s.id: s for s in SOURCES}


def archive_stem(name: str) -> str:
    return _ARCHIVE.sub("", name)


def pick_asset(source: Source, assets: list[dict[str, Any]]) -> dict[str, Any] | None:
    patterns = (source.v3_patterns if cpu.supports_v3() else ()) + source.patterns
    for pattern in patterns:
        rx = re.compile(pattern)
        for asset in assets:
            if rx.match(asset.get("name", "")):
                return asset
    return None


def _checksum_url(assets: list[dict[str, Any]], archive: str) -> str:
    want = archive_stem(archive) + ".sha512sum"
    hit = next((a for a in assets if a.get("name") == want), None)
    return hit.get("browser_download_url", "") if hit else ""


def parse_releases(source: Source, payload: Any) -> list[dict[str, Any]]:
    """GitHub releases API → 前端用的精简列表;跳过草稿和没有适用资源的发布。"""
    out = []
    for rel in payload if isinstance(payload, list) else []:
        if not isinstance(rel, dict) or rel.get("draft"):
            continue
        assets = [a for a in rel.get("assets") or [] if isinstance(a, dict)]
        asset = pick_asset(source, assets)
        if not asset:
            continue
        out.append({
            "tag": str(rel.get("tag_name", "")),
            "published": str(rel.get("published_at") or ""),
            "prerelease": bool(rel.get("prerelease")),
            "asset": asset["name"],
            "name": archive_stem(asset["name"]),
            "size": int(asset.get("size") or 0),
            "url": str(asset.get("browser_download_url", "")),
            "checksum_url": _checksum_url(assets, asset["name"]),
        })
    return out

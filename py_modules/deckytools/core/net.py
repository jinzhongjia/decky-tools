"""HTTP 工具(stdlib urllib,同步;调用方放线程里跑)。

证书:优先 Decky 冻结运行时自带的 certifi,其次系统 CA。
镜像:可选的 GitHub 下载加速前缀,只作用于 github.com 的 release 资源,不作用于 API。
"""

import json
import os
import socket
import ssl
import urllib.error
import urllib.request
from typing import Any, Callable

from .errors import HTTP_ERROR, NETWORK, NOT_FOUND, RATE_LIMITED, ToolError

USER_AGENT = "decky-tools (+https://github.com/jinzhongjia/decky-tools)"
_CHUNK = 256 * 1024
_SYSTEM_CA = "/etc/ssl/certs/ca-certificates.crt"


def _ssl_context() -> ssl.SSLContext:
    try:
        import certifi  # type: ignore[import-not-found]

        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        pass
    if os.path.exists(_SYSTEM_CA):
        return ssl.create_default_context(cafile=_SYSTEM_CA)
    return ssl.create_default_context()


_ctx = _ssl_context()


def mirror_url(url: str, prefix: str) -> str:
    prefix = (prefix or "").strip()
    if not prefix or not url.startswith("https://github.com/"):
        return url
    return prefix.rstrip("/") + "/" + url


def _open(url: str, timeout: float, headers: dict[str, str] | None = None):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **(headers or {})})
    try:
        return urllib.request.urlopen(req, timeout=timeout, context=_ctx)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise ToolError(NOT_FOUND, f"http 404 for {_host(url)}") from None
        if e.code in (403, 429) and e.headers.get("X-RateLimit-Remaining") == "0":
            raise ToolError(RATE_LIMITED, "github api rate limit") from None
        raise ToolError(HTTP_ERROR, f"http {e.code} from {_host(url)}") from None
    except (urllib.error.URLError, socket.timeout, ConnectionError, ssl.SSLError) as e:
        raise ToolError(NETWORK, f"{type(e).__name__} reaching {_host(url)}") from None


def _host(url: str) -> str:
    """日志只记主机名,不记完整 URL(可能带签名参数)。"""
    return urllib.request.urlparse(url).netloc


def get_json(url: str, timeout: float = 20) -> Any:
    with _open(url, timeout, {"Accept": "application/vnd.github+json"}) as resp:
        return json.loads(resp.read().decode("utf-8"))


def get_text(url: str, timeout: float = 20, limit: int = 1 << 20) -> str:
    with _open(url, timeout) as resp:
        return resp.read(limit).decode("utf-8", "replace")


def download(
    url: str,
    dest: str,
    on_progress: Callable[[int, int], None],
    check_cancel: Callable[[], None],
    timeout: float = 30,
) -> None:
    """流式下载到 dest;存在 dest.part 时尝试 Range 续传。"""
    part = dest + ".part"
    offset = os.path.getsize(part) if os.path.exists(part) else 0
    headers = {"Range": f"bytes={offset}-"} if offset else {}
    with _open(url, timeout, headers) as resp:
        if offset and resp.status != 206:  # 服务端不支持续传 → 从头来
            offset = 0
        length = int(resp.headers.get("Content-Length") or 0)
        total = offset + length if length else 0
        done = offset
        with open(part, "ab" if offset else "wb") as f:
            while True:
                check_cancel()
                try:
                    chunk = resp.read(_CHUNK)
                except (socket.timeout, ConnectionError, ssl.SSLError) as e:
                    raise ToolError(NETWORK, f"{type(e).__name__} while downloading") from None
                if not chunk:
                    break
                f.write(chunk)
                done += len(chunk)
                on_progress(done, total)
    if total and done < total:
        raise ToolError(NETWORK, "download truncated")
    os.replace(part, dest)

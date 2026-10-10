"""统一日志:`[scope] where: msg`,英文、不含敏感信息。dev_mode 标记存在时开 DEBUG。"""

import logging
import os

from . import runtime

_log = runtime.logger()
_log.setLevel(
    logging.DEBUG if os.path.exists(os.path.join(runtime.plugin_dir(), "dev_mode")) else logging.INFO
)


class Logger:
    def __init__(self, scope: str):
        self.scope = scope

    def _fmt(self, where: str, msg: str) -> str:
        return f"[{self.scope}] {where}: {msg}"

    def debug(self, where: str, msg: str) -> None:
        _log.debug(self._fmt(where, msg))

    def info(self, where: str, msg: str) -> None:
        _log.info(self._fmt(where, msg))

    def warn(self, where: str, msg: str) -> None:
        _log.warning(self._fmt(where, msg))

    def error(self, where: str, msg: str) -> None:
        _log.error(self._fmt(where, msg))

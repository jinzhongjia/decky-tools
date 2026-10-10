"""稳定错误码:前端按 code 做 i18n,message 只作日志/兜底,不得含 URL token 等敏感信息。"""


class ToolError(Exception):
    def __init__(self, code: str, detail: str = ""):
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail


class Cancelled(ToolError):
    def __init__(self):
        super().__init__("cancelled")


# 通用
INVALID_REQUEST = "invalid_request"
UNKNOWN_TOOL = "unknown_tool"
UNKNOWN_METHOD = "unknown_method"
INTERNAL = "internal"
BUSY = "busy"
NOT_FOUND = "not_found"
# 网络
NETWORK = "network"
HTTP_ERROR = "http_error"
RATE_LIMITED = "rate_limited"
# 文件
DISK_FULL = "disk_full"
CHECKSUM_MISMATCH = "checksum_mismatch"
EXTRACT_FAILED = "extract_failed"
ALREADY_INSTALLED = "already_installed"

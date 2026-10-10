"""CPU 特性探测:判断是否支持 x86-64-v3 微架构级别(Steam Deck 的 Zen 2 APU 支持)。"""

from functools import lru_cache

_V3_FLAGS = {"avx", "avx2", "bmi1", "bmi2", "f16c", "fma", "abm", "movbe", "xsave"}


def parse_flags(cpuinfo: str) -> set[str]:
    for line in cpuinfo.splitlines():
        if line.startswith("flags"):
            return set(line.split(":", 1)[1].split())
    return set()


@lru_cache(maxsize=1)
def supports_v3() -> bool:
    try:
        with open("/proc/cpuinfo", encoding="utf-8") as f:
            return _V3_FLAGS <= parse_flags(f.read())
    except OSError:
        return False

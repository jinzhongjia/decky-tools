"""把 dt-monitor 的原始采样与历史分桶整理成界面直接渲染的快照。纯函数,便于单测。

单位约定:百分比 0~100(可为小数)、温度 °C、频率 MHz、功率 mW、内存 MB。
"""

from typing import Any

Point = list[float | None]


def power_mw(apu: float | None, battery: float | None) -> float | None:
    """功耗:有 APU 读数(Steam Deck)用 APU;否则退回电池放电功率,充电时无意义。"""
    if apu is not None:
        return apu
    return battery if battery is not None and battery > 0 else None


def _div(v: float | None, d: float) -> float | None:
    return None if v is None else v / d


def _column(history: dict[str, Any], key: str) -> Point:
    keys = history.get("keys") or []
    if key not in keys:
        return [None] * len(history.get("points") or [])
    i = keys.index(key)
    out: Point = []
    for p in history.get("points") or []:
        v = p[i] if isinstance(p, list) and i < len(p) else None
        out.append(v if isinstance(v, (int, float)) else None)
    return out


def series(history: dict[str, Any]) -> dict[str, Point]:
    apu, battery = _column(history, "apu_power_mw"), _column(history, "battery_power_mw")
    return {
        "cpu": [_div(v, 10) for v in _column(history, "cpu_pct_x10")],
        "gpu": _column(history, "gpu_pct"),
        "memory": [_div(v, 10) for v in _column(history, "mem_pct_x10")],
        "power": [power_mw(a, b) for a, b in zip(apu, battery)],
        "battery": _column(history, "battery_pct"),
    }


def stats(values: Point) -> dict[str, float] | None:
    nums = [v for v in values if v is not None]
    if len(nums) < 2:
        return None
    return {"peak": max(nums), "avg": sum(nums) / len(nums)}


def current(sample: dict[str, Any]) -> dict[str, Any]:
    g = sample.get
    used, total = g("mem_used_mb"), g("mem_total_mb")
    apu = g("apu_power_mw")
    return {
        "cpu_pct": _div(g("cpu_pct_x10"), 10),
        "cpu_mhz": g("cpu_mhz"),
        "cpu_temp_c": _div(g("cpu_temp_mc"), 1000),
        "gpu_pct": g("gpu_pct"),
        "gpu_mhz": g("gpu_mhz"),
        "gpu_temp_c": _div(g("gpu_temp_mc"), 1000),
        "mem_pct": used / total * 100 if used is not None and total else None,
        "mem_used_mb": used,
        "mem_total_mb": total,
        "power_mw": power_mw(apu, g("battery_power_mw")),
        "power_source": "apu" if apu is not None else "battery",
        "battery_pct": g("battery_pct"),
        "battery_status": g("battery_status"),
        "battery_power_mw": g("battery_power_mw"),
    }


def build(sample: dict[str, Any] | None, history: dict[str, Any] | None,
          info: dict[str, Any] | None, window: int, ranges: list[int]) -> dict[str, Any]:
    s = series(history) if history else {}
    return {
        "range": window,
        "ranges": ranges,
        "capacity": len((history or {}).get("points") or []),
        "current": current(sample) if sample else None,
        "series": s,
        "power_stats": stats(s.get("power", [])),
        "info": info,
    }

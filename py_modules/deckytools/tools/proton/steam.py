"""判断 Steam 客户端是否在某时刻之后重启过:新兼容层只有 Steam 重启后才会被扫描到。

读 /proc 中 steam 主进程的启动时间(插件以同一用户运行,无需特权)。
"""

import os

_COMM = "steam"


def boot_time(proc: str = "/proc") -> float | None:
    try:
        with open(os.path.join(proc, "stat"), encoding="ascii") as f:
            for line in f:
                if line.startswith("btime "):
                    return float(line.split()[1])
    except (OSError, ValueError):
        pass
    return None


def parse_start_ticks(stat: str) -> int | None:
    """/proc/<pid>/stat 第 22 列 starttime;进程名可含空格,从最后一个 ')' 之后数。"""
    fields = stat[stat.rfind(")") + 2 :].split()
    try:
        return int(fields[19])  # 第 3 列起算,22 - 3 = 19
    except (IndexError, ValueError):
        return None


def steam_started_at(proc: str = "/proc") -> float | None:
    """最新的 steam 主进程启动时刻(epoch 秒);没在运行返回 None。"""
    btime = boot_time(proc)
    if btime is None:
        return None
    ticks_per_s = os.sysconf("SC_CLK_TCK")
    newest = None
    for pid in os.listdir(proc):
        if not pid.isdigit():
            continue
        try:
            with open(os.path.join(proc, pid, "comm"), encoding="utf-8", errors="replace") as f:
                if f.read().strip() != _COMM:
                    continue
            with open(os.path.join(proc, pid, "stat"), encoding="utf-8", errors="replace") as f:
                ticks = parse_start_ticks(f.read())
        except OSError:
            continue
        if ticks is not None:
            started = btime + ticks / ticks_per_s
            newest = started if newest is None else max(newest, started)
    return newest

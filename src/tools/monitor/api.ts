import { invoke } from "../../core/api";

// monitor 工具的后端接口与界面快照。快照由 Zig 子进程生成(backend/src/view.zig),
// 经 py_modules/deckytools/tools/monitor/tool.py 以 JSON 文本原样透传,在这里解析一次。
// 数值已由后端换算好:百分比 0~100、温度 °C、频率 MHz、功率 mW、内存 MB;null = 本机不可用。
export const TOOL = "monitor";

export type BatteryStatus = "charging" | "discharging" | "full" | "not_charging" | "unknown";

export interface Current {
  cpu_pct: number | null;
  cpu_mhz: number | null;
  cpu_temp_c: number | null;
  gpu_pct: number | null;
  gpu_mhz: number | null;
  gpu_temp_c: number | null;
  mem_pct: number | null;
  mem_used_mb: number | null;
  mem_total_mb: number | null;
  power_mw: number | null;
  power_source: "apu" | "battery";
  battery_pct: number | null;
  battery_status: BatteryStatus | null;
  battery_power_mw: number | null;
}

export interface SystemInfo {
  hostname?: string;
  kernel?: string;
  product?: string;
  os?: string;
  os_build?: string;
  cpu_model?: string;
  ip?: string;
  interface?: string;
}

export type Series = Partial<
  Record<"cpu" | "gpu" | "memory" | "power" | "battery", (number | null)[]>
>;

export interface MonitorView {
  range: number;
  ranges: number[];
  capacity: number;
  current: Current | null;
  series: Series;
  power_stats: { peak: number; avg: number } | null;
}

/** 后端 watch / set_range 的返回:view 是快照的 JSON 文本(可能为 null),info 为系统信息。 */
export interface Snapshot {
  view: string | null;
  info: SystemInfo | null;
}

/** 解析快照文本;格式不对返回 null(当作没有快照)。 */
export function parseView(text: unknown): MonitorView | null {
  if (typeof text !== "string") return null;
  try {
    const v = JSON.parse(text) as MonitorView;
    const ok =
      typeof v.range === "number" && Array.isArray(v.ranges) && typeof v.series === "object";
    return ok ? v : null;
  } catch {
    return null;
  }
}

export function isInfo(v: unknown): v is SystemInfo {
  return !!v && typeof v === "object" && !Array.isArray(v);
}

export const monitorApi = {
  watch: (snapshot = true) => invoke<Snapshot>(TOOL, "watch", { snapshot }),
  setRange: (window: number) => invoke<Snapshot>(TOOL, "set_range", { window }),
  refreshInfo: () => invoke<SystemInfo | null>(TOOL, "refresh_info"),
};

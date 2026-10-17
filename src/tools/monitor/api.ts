import { invoke } from "../../core/api";

// monitor 工具的后端接口与界面快照,对应 py_modules/deckytools/tools/monitor/tool.py 与 view.py。
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
  info: SystemInfo | null;
}

export function isView(v: unknown): v is MonitorView {
  const s = v as MonitorView;
  return (
    !!s && typeof s.range === "number" && Array.isArray(s.ranges) && typeof s.series === "object"
  );
}

export const monitorApi = {
  watch: () => invoke<MonitorView>(TOOL, "watch"),
  setRange: (window: number) => invoke<MonitorView>(TOOL, "set_range", { window }),
  refreshInfo: () => invoke<null>(TOOL, "refresh_info"),
};

import { invoke } from "../../core/api";

// monitor 工具的后端接口,对应 py_modules/deckytools/tools/monitor/tool.py;
// 字段来自 Zig 子进程 backend/src/sampler.zig 与 sysinfo.zig。缺失字段 = 本机不可用,不是 0。
export const TOOL = "monitor";

export type BatteryStatus = "charging" | "discharging" | "full" | "not_charging" | "unknown";

export interface Sample {
  cpu_pct_x10?: number;
  cpu_mhz?: number;
  cpu_temp_mc?: number;
  mem_used_mb?: number;
  mem_total_mb?: number;
  gpu_pct?: number;
  gpu_mhz?: number;
  gpu_temp_mc?: number;
  apu_power_mw?: number;
  battery_pct?: number;
  /** 正 = 放电,负 = 充电 */
  battery_power_mw?: number;
  battery_status?: BatteryStatus;
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

const NUMERIC: (keyof Sample)[] = [
  "cpu_pct_x10",
  "cpu_mhz",
  "cpu_temp_mc",
  "mem_used_mb",
  "mem_total_mb",
  "gpu_pct",
  "gpu_mhz",
  "gpu_temp_mc",
  "apu_power_mw",
  "battery_pct",
  "battery_power_mw",
];
const STATUSES: BatteryStatus[] = ["charging", "discharging", "full", "not_charging", "unknown"];

/** 只保留类型正确的字段,畸形值丢弃(当作不可用)。 */
export function toSample(v: unknown): Sample | null {
  if (!v || typeof v !== "object") return null;
  const raw = v as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const k of NUMERIC) if (Number.isFinite(raw[k])) out[k] = raw[k];
  if (STATUSES.includes(raw.battery_status as BatteryStatus))
    out.battery_status = raw.battery_status;
  return out as Sample;
}

/** 历史分桶均值,字段与 backend/src/history.zig 的 KEYS 对应;null = 该时段无数据。 */
export interface HistoryData {
  step_ms: number;
  keys: string[];
  points: (number | null)[][];
}

export type Series = Record<string, (number | null)[]>;

export function toSeries(h: unknown): Series | null {
  if (!h || typeof h !== "object") return null;
  const { keys, points } = h as HistoryData;
  if (!Array.isArray(keys) || !Array.isArray(points)) return null;
  const out: Series = {};
  keys.forEach((key, i) => {
    out[key] = points.map((p) => (Array.isArray(p) && Number.isFinite(p[i]) ? p[i] : null));
  });
  return out;
}

/** 把一次实时采样换算成与历史相同的字段,用于 2 分钟视图逐秒追加。 */
export function sampleToPoint(s: Sample): Record<string, number | null> {
  const mem =
    s.mem_used_mb != null && s.mem_total_mb
      ? Math.trunc((s.mem_used_mb * 1000) / s.mem_total_mb)
      : null;
  return {
    cpu_pct_x10: s.cpu_pct_x10 ?? null,
    gpu_pct: s.gpu_pct ?? null,
    mem_pct_x10: mem,
    apu_power_mw: s.apu_power_mw ?? null,
    battery_power_mw: s.battery_power_mw ?? null,
    battery_pct: s.battery_pct ?? null,
  };
}

export const monitorApi = {
  watch: () => invoke<{ sample: unknown; info: SystemInfo | null; lease: number }>(TOOL, "watch"),
  history: (window: number) => invoke<HistoryData>(TOOL, "history", { window }),
  info: (refresh = false) => invoke<SystemInfo>(TOOL, "info", { refresh }),
};

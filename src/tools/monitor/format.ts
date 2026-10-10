// 指标单位换算:后端给整数原始单位(千分比、MHz、毫摄氏度、毫瓦)。
export const pct = (x10?: number) => (x10 == null ? null : `${Math.round(x10 / 10)}%`);

export const freq = (mhz?: number) =>
  mhz == null ? null : mhz >= 1000 ? `${(mhz / 1000).toFixed(2)} GHz` : `${mhz} MHz`;

export const temp = (mc?: number) => (mc == null ? null : `${Math.round(mc / 1000)}°C`);

export const watts = (mw?: number) => (mw == null ? null : `${(Math.abs(mw) / 1000).toFixed(1)} W`);

/** 多个可空片段用 " · " 连接;全空返回 null。 */
export function join(...parts: (string | null)[]): string | null {
  const shown = parts.filter((p): p is string => !!p);
  return shown.length ? shown.join(" · ") : null;
}

export const gb = (mb?: number) => (mb == null ? null : `${(mb / 1024).toFixed(1)} GB`);

/** 已用占总量的百分比;任一缺失或总量为 0 时返回 null。 */
export function ratio(used?: number, total?: number): number | null {
  return used == null || !total ? null : Math.min(100, (used / total) * 100);
}

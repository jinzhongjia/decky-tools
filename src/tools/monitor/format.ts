// 纯显示格式化:后端已给出换算好的数值,这里只负责转成带单位的文字。
export const pct = (v: number | null) => (v == null ? null : `${Math.round(v)}%`);

export const freq = (mhz: number | null) =>
  mhz == null ? null : mhz >= 1000 ? `${(mhz / 1000).toFixed(2)} GHz` : `${mhz} MHz`;

export const temp = (c: number | null) => (c == null ? null : `${Math.round(c)}°C`);

export const watts = (mw: number | null) =>
  mw == null ? null : `${(Math.abs(mw) / 1000).toFixed(1)} W`;

export const gb = (mb: number | null) => (mb == null ? null : `${(mb / 1024).toFixed(1)} GB`);

/** 多个可空片段用 " · " 连接;全空返回 null。 */
export function join(...parts: (string | null | undefined)[]): string | null {
  const shown = parts.filter((p): p is string => !!p);
  return shown.length ? shown.join(" · ") : null;
}

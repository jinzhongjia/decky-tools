// 轻量 SVG 折线图(无依赖):固定容量的时间窗,最新点在最右;null 表示该点缺失,折线在此断开。
const W = 300;

export interface LineChartProps {
  values: (number | null)[];
  capacity: number;
  color: string;
  /** 纵轴上限;不给则按数据自适应(至少 minMax)。纵轴下限固定为 0。 */
  max?: number;
  minMax?: number;
  height?: number;
}

function scaleMax(values: (number | null)[], max?: number, minMax = 1): number {
  if (max != null) return max;
  const peak = Math.max(minMax, ...values.filter((v): v is number => v != null));
  return peak * 1.15;
}

/** 按 null 切分成若干连续线段,每段生成 SVG points 字符串。 */
function segments(values: (number | null)[], capacity: number, top: number, h: number): string[] {
  const step = W / Math.max(1, capacity - 1);
  const offset = capacity - values.length; // 数据不满一屏时靠右对齐
  const out: string[] = [];
  let cur: string[] = [];
  values.forEach((v, i) => {
    if (v == null) {
      if (cur.length) out.push(cur.join(" "));
      cur = [];
      return;
    }
    const y = h - (Math.min(v, top) / top) * (h - 2) - 1;
    cur.push(`${((offset + i) * step).toFixed(1)},${y.toFixed(1)}`);
  });
  if (cur.length) out.push(cur.join(" "));
  return out;
}

/** 折线下方的填充区域:首尾各补一个落到底边的点。 */
function area(points: string, height: number): string {
  const xs = points.split(" ").map((p) => p.split(",")[0]);
  return `${xs[0]},${height} ${points} ${xs[xs.length - 1]},${height}`;
}

export function LineChart({ values, capacity, color, max, minMax, height = 48 }: LineChartProps) {
  const top = scaleMax(values, max, minMax);
  const lines = segments(values.slice(-capacity), capacity, top, height);
  return (
    <svg
      viewBox={`0 0 ${W} ${height}`}
      preserveAspectRatio="none"
      style={{ width: "100%", height, display: "block" }}
    >
      <rect x={0} y={0} width={W} height={height} fill="rgba(255,255,255,0.04)" rx={3} />
      <line
        x1={0}
        x2={W}
        y1={height / 2}
        y2={height / 2}
        stroke="rgba(255,255,255,0.08)"
        strokeDasharray="4 4"
        vectorEffect="non-scaling-stroke"
      />
      {lines.map((points, i) => (
        <g key={i}>
          {points.includes(" ") && (
            <polygon points={area(points, height)} fill={color} opacity={0.15} />
          )}
          <polyline
            points={points}
            fill="none"
            stroke={color}
            strokeWidth={1.5}
            vectorEffect="non-scaling-stroke"
            strokeLinejoin="round"
          />
        </g>
      ))}
    </svg>
  );
}

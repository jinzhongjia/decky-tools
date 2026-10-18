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
  let peak = minMax;
  for (const v of values) if (v != null && v > peak) peak = v;
  return peak * 1.15;
}

interface Segment {
  points: string; // 折线
  area: string; // 折线下方的填充区域:首尾各补一个落到底边的点
}

/** 一次遍历按 null 切分成连续线段,直接生成折线与填充区域的 points 字符串。 */
function segments(values: (number | null)[], capacity: number, top: number, h: number): Segment[] {
  const step = W / Math.max(1, capacity - 1);
  const offset = capacity - values.length; // 数据不满一屏时靠右对齐
  const out: Segment[] = [];
  let points = "";
  let firstX = "";
  let lastX = "";
  const close = () => {
    if (points) out.push({ points, area: `${firstX},${h} ${points} ${lastX},${h}` });
    points = "";
  };
  for (let i = 0; i < values.length; i++) {
    const v = values[i];
    if (v == null) {
      close();
      continue;
    }
    const x = ((offset + i) * step).toFixed(1);
    const y = (h - (Math.min(v, top) / top) * (h - 2) - 1).toFixed(1);
    if (!points) firstX = x;
    points += points ? ` ${x},${y}` : `${x},${y}`;
    lastX = x;
  }
  close();
  return out;
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
      {lines.map((seg, i) => (
        <g key={i}>
          {seg.points.includes(" ") && <polygon points={seg.area} fill={color} opacity={0.15} />}
          <polyline
            points={seg.points}
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

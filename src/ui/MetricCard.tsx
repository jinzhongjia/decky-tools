import { Focusable } from "@decky/ui";
import { useState, type ReactNode } from "react";

const FOCUS_BG = "rgba(255, 255, 255, 0.12)";

// 可用十字键聚焦的指标卡片:标题 + 当前值一行,下方图表与补充信息。
// 聚焦时高亮,QAM 会自动把聚焦项滚动到可见区域。
export function MetricCard(props: {
  label: ReactNode;
  value: ReactNode | null;
  chart?: ReactNode;
  detail?: ReactNode;
  onActivate?: () => void;
}) {
  const [focused, setFocused] = useState(false);
  return (
    <Focusable
      onActivate={props.onActivate ?? (() => {})}
      onGamepadFocus={() => setFocused(true)}
      onGamepadBlur={() => setFocused(false)}
      style={{
        padding: "0.45rem 0",
        borderRadius: 2,
        background: focused ? FOCUS_BG : "transparent",
        borderBottom: "1px solid rgba(255,255,255,0.08)",
      }}
    >
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
        <span>{props.label}</span>
        <span style={{ opacity: props.value === null ? 0.45 : 0.9, whiteSpace: "nowrap" }}>
          {props.value === null ? "—" : props.value}
        </span>
      </div>
      {props.chart && <div style={{ marginTop: "0.3rem" }}>{props.chart}</div>}
      {props.detail && (
        <div style={{ marginTop: "0.2rem", fontSize: "0.8em", opacity: 0.6 }}>{props.detail}</div>
      )}
    </Focusable>
  );
}

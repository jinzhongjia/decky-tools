import type { ReactNode } from "react";

const COLORS = {
  green: { color: "#d2f5c4", background: "rgba(89, 191, 64, 0.35)" },
  amber: { color: "#ffe7b0", background: "rgba(230, 160, 30, 0.35)" },
} as const;

export function Badge({
  children,
  tone = "green",
}: {
  children: ReactNode;
  tone?: keyof typeof COLORS;
}) {
  return (
    <span
      style={{
        ...COLORS[tone],
        fontSize: "0.7em",
        padding: "0.05rem 0.4rem",
        borderRadius: "0.6rem",
        marginLeft: "0.4rem",
        verticalAlign: "middle",
        whiteSpace: "nowrap",
      }}
    >
      {children}
    </span>
  );
}

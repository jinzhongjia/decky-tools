import { Field } from "@decky/ui";
import type { ReactNode } from "react";

const DIM = 0.45;

// 只读信息行:标题在上、值在下(可换行),用于 IP、内核版本等较长的文本。可用十字键聚焦。
export function InfoRow({ label, value }: { label: ReactNode; value: string | null }) {
  return (
    <Field
      focusable
      highlightOnFocus
      label={label}
      description={
        <span style={{ wordBreak: "break-all", opacity: value === null ? DIM : 1 }}>
          {value ?? "—"}
        </span>
      }
      bottomSeparator="standard"
    />
  );
}

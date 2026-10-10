import { DialogButton } from "@decky/ui";

import { useError } from "../core/errors";

// 面板内错误横幅(Steam toast 太短):有错才显示,可关闭。
export function ErrorBanner({ scope }: { scope: string }) {
  const [msg, clear] = useError(scope);
  if (!msg) return null;
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: "0.5rem",
        margin: "0.5rem 0",
        padding: "0.4rem 0.6rem",
        borderRadius: 4,
        background: "rgba(220, 60, 60, 0.15)",
        border: "1px solid rgba(220, 60, 60, 0.5)",
      }}
    >
      <div style={{ flexGrow: 1, whiteSpace: "pre-wrap", fontSize: "0.85em" }}>{msg}</div>
      <DialogButton style={{ minWidth: 0, width: 40, padding: "0.2rem" }} onClick={clear}>
        ×
      </DialogButton>
    </div>
  );
}

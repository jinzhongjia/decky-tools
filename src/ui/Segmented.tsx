import { DialogButton, Focusable } from "@decky/ui";

// 分段选择器:一行等宽按钮,十字键左右切换焦点,A 键选中。
export function Segmented<T extends string | number>(props: {
  options: { value: T; label: string }[];
  value: T;
  onChange: (value: T) => void;
}) {
  return (
    <Focusable
      flow-children="horizontal"
      style={{ display: "flex", gap: "0.4rem", padding: "0.3rem 0" }}
    >
      {props.options.map((o) => {
        const active = o.value === props.value;
        return (
          <DialogButton
            key={String(o.value)}
            style={{
              flex: 1,
              minWidth: 0,
              padding: "0.3rem",
              opacity: active ? 1 : 0.6,
              boxShadow: active ? "inset 0 -2px 0 #1a9fff" : undefined,
            }}
            onClick={() => props.onChange(o.value)}
          >
            {o.label}
          </DialogButton>
        );
      })}
    </Focusable>
  );
}

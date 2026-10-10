import { DialogButton, Field } from "@decky/ui";
import type { ReactNode } from "react";

// 列表行:左侧标题/说明,右侧紧凑按钮。ButtonItem 的按钮有固定最小宽度,长标题时会撑出 QAM。
export function ActionRow(props: {
  label: ReactNode;
  description?: ReactNode;
  action: ReactNode;
  disabled?: boolean;
  onClick: () => void;
}) {
  return (
    <Field
      label={props.label}
      description={props.description}
      childrenContainerWidth="min"
      inlineWrap="keep-inline"
      bottomSeparator="standard"
      focusable={false}
    >
      <DialogButton
        style={{ minWidth: "4.5em", width: "auto", padding: "0.4rem 0.9rem" }}
        disabled={props.disabled}
        onClick={props.onClick}
      >
        {props.action}
      </DialogButton>
    </Field>
  );
}

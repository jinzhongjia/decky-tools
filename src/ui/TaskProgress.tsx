import { ProgressBar } from "@decky/ui";
import type { ReactNode } from "react";

import { invoke } from "../core/api";
import { guard } from "../core/errors";
import { ActionRow } from "./ActionRow";
import { fmtBytes } from "./format";
import { t } from "./strings";

/** 后端快照里进行中任务的字段(py_modules/deckytools/core/tasks.py 的 TaskManager.snapshot)。 */
export interface TaskView {
  id: string;
  state: "queued" | "running";
  stage: string;
  done: number;
  total: number;
}

function stageText(task: TaskView): string {
  if (task.state === "queued") return t("queued");
  const key = `stage_${task.stage}` as Parameters<typeof t>[0];
  return t(key) === key ? task.stage : t(key);
}

function ProgressInfo({ task }: { task: TaskView }) {
  const known = task.total > 0;
  const pct = known ? Math.min(100, (task.done / task.total) * 100) : 0;
  const detail = !known
    ? ""
    : task.stage === "download"
      ? `${fmtBytes(task.done)} / ${fmtBytes(task.total)}`
      : `${Math.round(pct)}%`;
  return (
    <div style={{ marginTop: "0.3rem" }}>
      <ProgressBar nProgress={pct} indeterminate={!known} focusable={false} />
      <div style={{ display: "flex", justifyContent: "space-between", marginTop: "0.2rem" }}>
        <span>{stageText(task)}</span>
        <span>{detail}</span>
      </div>
    </div>
  );
}

/** 通用进行中任务行:标题 + 进度条/阶段/字节数 + 取消按钮。 */
export function TaskRow(props: { label: ReactNode; task: TaskView; errorScope: string }) {
  return (
    <ActionRow
      label={props.label}
      description={<ProgressInfo task={props.task} />}
      action={t("cancel")}
      onClick={() =>
        guard(props.errorScope, () => invoke("core", "cancel_task", { id: props.task.id }))
      }
    />
  );
}

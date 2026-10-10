import { ProgressBar } from "@decky/ui";
import type { ReactNode } from "react";

import { guard } from "../core/errors";
import { Task, cancelTask } from "../core/tasks";
import { ActionRow } from "./ActionRow";
import { fmtBytes } from "./format";
import { t } from "./strings";

function stageText(task: Task): string {
  if (task.state === "queued") return t("queued");
  const key = `stage_${task.stage}` as Parameters<typeof t>[0];
  return t(key) === key ? task.stage : t(key);
}

function ProgressInfo({ task }: { task: Task }) {
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
export function TaskRow({
  label,
  task,
  errorScope,
}: {
  label: ReactNode;
  task: Task;
  errorScope: string;
}) {
  return (
    <ActionRow
      label={label}
      description={<ProgressInfo task={task} />}
      action={t("cancel")}
      onClick={() => guard(errorScope, () => cancelTask(task.id))}
    />
  );
}

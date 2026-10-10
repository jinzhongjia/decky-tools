import { invoke, onToolEvent } from "./api";
import { createStore, useStore } from "./store";

// 后台任务镜像:启动时拉一次全量,之后靠 core/task 事件增量更新。
// 字段与 py_modules/deckytools/core/tasks.py 的 Task 一一对应。
export type TaskState = "queued" | "running" | "done" | "failed" | "cancelled";

export interface Task {
  id: string;
  tool: string;
  kind: string;
  key: string;
  title: string;
  state: TaskState;
  stage: string;
  done: number;
  total: number;
  error: string;
  meta: Record<string, unknown>;
  updated: number;
}

const STATES: TaskState[] = ["queued", "running", "done", "failed", "cancelled"];

function isTask(v: unknown): v is Task {
  if (!v || typeof v !== "object") return false;
  const t = v as Record<string, unknown>;
  return (
    typeof t.id === "string" &&
    typeof t.tool === "string" &&
    typeof t.key === "string" &&
    STATES.includes(t.state as TaskState) &&
    Number.isFinite(t.done) &&
    Number.isFinite(t.total)
  );
}

export const taskStore = createStore<{ tasks: Record<string, Task> }>({ tasks: {} });

type Listener = (task: Task, prev: Task | undefined) => void;
const listeners = new Set<Listener>();

function upsert(task: Task) {
  const prev = taskStore.get().tasks[task.id];
  taskStore.set((s) => ({ tasks: { ...s.tasks, [task.id]: task } }));
  listeners.forEach((l) => l(task, prev));
}

export function isActive(task: Task | undefined): task is Task {
  return !!task && (task.state === "queued" || task.state === "running");
}

/** 任务状态变化回调(含首次出现);工具用它做完成提示、刷新列表等。 */
export function onTaskChange(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function startTaskSync(): () => void {
  const off = onToolEvent("core", "task", (data) => isTask(data) && upsert(data));
  invoke<unknown[]>("core", "tasks")
    .then((list) => list.filter(isTask).forEach(upsert))
    .catch((e) => console.error("[decky-tools] task hydrate failed", e));
  return off;
}

export function cancelTask(id: string) {
  return invoke<boolean>("core", "cancel_task", { id });
}

/** 按 key 取最近一个任务(同 key 同时只会有一个进行中)。 */
export function useTaskByKey(key: string): Task | undefined {
  const { tasks } = useStore(taskStore);
  let latest: Task | undefined;
  for (const t of Object.values(tasks)) {
    if (t.key === key && (!latest || t.updated >= latest.updated)) latest = t;
  }
  return latest;
}

import { toaster } from "@decky/api";

import { invoke, onToolEvent } from "../core/api";
import { TOOLS } from "../tools";

// 后端通知的显示端:收到即用 Steam toast 显示并 ack。后端负责去重与补发
// (前端重新加载后经 core.notifications 取回未确认的),前端不判断"该不该通知"。
interface Note {
  id: string;
  tool: string;
  key: string;
  params: Record<string, unknown>;
}

const shown = new Set<string>(); // 本次加载内事件与补发可能撞上同一条

function isNote(v: unknown): v is Note {
  const n = v as Note;
  return !!n && typeof n.id === "string" && typeof n.tool === "string" && typeof n.key === "string";
}

function show(note: Note) {
  if (shown.has(note.id)) return;
  shown.add(note.id);
  const tool = TOOLS.find((x) => x.id === note.tool);
  const body = tool?.message?.(note.key, note.params ?? {});
  if (tool && body) toaster.toast({ title: tool.title(), body });
  invoke("core", "ack", { ids: [note.id] }).catch(() => {});
}

export function startNotifications(): () => void {
  const off = onToolEvent("core", "notify", (data) => isNote(data) && show(data));
  invoke<unknown[]>("core", "notifications")
    .then((list) => list.filter(isNote).forEach(show))
    .catch((e) => console.error("[decky-tools] notification sync failed", e));
  return off;
}

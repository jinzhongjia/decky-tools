import { onToolEvent } from "../../core/api";
import { guard } from "../../core/errors";
import { createStore } from "../../core/store";
import { MonitorView, TOOL, isView, monitorApi } from "./api";

// 只保存后端推来的快照。前端唯一的主动行为是"面板开着"的心跳续租。
export const SCOPE = "monitor";
const RENEW_MS = 5000; // 后端租约 15s,每 5s 续一次

export const store = createStore<{ view: MonitorView | null }>({ view: null });

async function renew() {
  const view = await guard(SCOPE, monitorApi.watch);
  if (view) store.set({ view });
}

export async function selectRange(window: number) {
  const view = await guard(SCOPE, () => monitorApi.setRange(window));
  if (view) store.set({ view });
}

export function refreshInfo() {
  return guard(SCOPE, monitorApi.refreshInfo);
}

/** 面板挂载期间:订阅快照推送 + 定时续租。返回清理函数。 */
export function startLive(): () => void {
  const off = onToolEvent(TOOL, "view", (data) => isView(data) && store.set({ view: data }));
  renew();
  const timer = setInterval(renew, RENEW_MS);
  // 不主动 unwatch:QAM 会频繁重挂,交给后端租约过期关闭推送
  return () => {
    clearInterval(timer);
    off();
  };
}

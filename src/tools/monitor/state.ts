import { onToolEvent } from "../../core/api";
import { guard } from "../../core/errors";
import { createStore } from "../../core/store";
import { MonitorView, Snapshot, SystemInfo, TOOL, isInfo, monitorApi, parseView } from "./api";

// 只保存后端推来的快照。前端唯一的主动行为是"面板开着"的心跳续租。
// view 每秒更新;info 只在刷新时更新,单独存放,系统信息区不随每秒的快照重渲染。
export const SCOPE = "monitor";
const RENEW_MS = 5000; // 后端租约 15s,每 5s 续一次

export const store = createStore<{ view: MonitorView | null; info: SystemInfo | null }>({
  view: null,
  info: null,
});

function apply(snapshot: Snapshot | undefined) {
  if (!snapshot) return;
  const view = parseView(snapshot.view);
  store.set((s) => ({ view: view ?? s.view, info: snapshot.info ?? s.info }));
}

/** 首次挂载取完整快照;之后的心跳只续租(快照每秒经 view 事件送达)。 */
async function renew(snapshot: boolean) {
  apply(await guard(SCOPE, () => monitorApi.watch(snapshot)));
}

export async function selectRange(window: number) {
  apply(await guard(SCOPE, () => monitorApi.setRange(window)));
}

export async function refreshInfo() {
  const info = await guard(SCOPE, monitorApi.refreshInfo);
  if (info) store.set({ info });
}

/** 面板挂载期间:订阅快照与系统信息推送 + 定时续租。返回清理函数。 */
export function startLive(): () => void {
  const offView = onToolEvent(TOOL, "view", (data) => {
    const view = parseView(data);
    if (view) store.set({ view });
  });
  const offInfo = onToolEvent(TOOL, "info", (data) => isInfo(data) && store.set({ info: data }));
  renew(true);
  const timer = setInterval(() => renew(false), RENEW_MS);
  // 不主动 unwatch:QAM 会频繁重挂,交给后端租约过期关闭推送
  return () => {
    clearInterval(timer);
    offView();
    offInfo();
  };
}

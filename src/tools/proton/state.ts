import { onToolEvent } from "../../core/api";
import { guard } from "../../core/errors";
import { createStore } from "../../core/store";
import { ProtonView, TOOL, isView, protonApi } from "./api";

// 只保存后端推来的快照;唯一的本地状态 expanded 是纯展示用的列表折叠。
export const SCOPE = "proton";

export const store = createStore<{ view: ProtonView | null; expanded: boolean }>({
  view: null,
  expanded: false,
});

/** 发一个操作给后端,用它返回的最新快照覆盖本地。 */
async function act(fn: () => Promise<ProtonView>) {
  const view = await guard(SCOPE, fn);
  if (view) store.set({ view });
}

export const actions = {
  selectSource: (id: string) => (
    store.set({ expanded: false }),
    act(() => protonApi.selectSource(id))
  ),
  refresh: () => act(protonApi.refresh),
  install: (tag: string) => act(() => protonApi.install(tag)),
  uninstall: (name: string) => act(() => protonApi.uninstall(name)),
  restartSteam: () => guard(SCOPE, protonApi.restartSteam),
};

/** 面板挂载:订阅快照推送并拉一次最新快照。返回清理函数。 */
export function startView(): () => void {
  const off = onToolEvent(TOOL, "view", (data) => isView(data) && store.set({ view: data }));
  act(protonApi.view);
  return off;
}

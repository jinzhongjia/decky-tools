import { guard } from "../../core/errors";
import { createStore } from "../../core/store";
import { InstalledTool, Release, Source, protonApi } from "./api";

// 跨 QAM 重挂保留的 proton 面板状态与动作。
export const SCOPE = "proton";

export interface ProtonState {
  sources: Source[];
  v3: boolean;
  source: string;
  releases: Record<string, Release[]>;
  stale: boolean;
  loadingReleases: boolean;
  installed: InstalledTool[];
  installedLoaded: boolean;
  expanded: boolean;
  restartNeeded: boolean;
}

export const store = createStore<ProtonState>({
  sources: [],
  v3: false,
  source: "",
  releases: {},
  stale: false,
  loadingReleases: false,
  installed: [],
  installedLoaded: false,
  expanded: false,
  restartNeeded: false,
});

export async function loadInstalled() {
  const state = await guard(SCOPE, protonApi.installed);
  if (state) store.set({ installed: state.tools, installedLoaded: true });
}

export async function loadReleases(refresh = false) {
  const { source } = store.get();
  if (!source) return;
  store.set({ loadingReleases: true });
  const res = await guard(SCOPE, () => protonApi.releases(source, refresh));
  store.set((s) => ({
    loadingReleases: false,
    stale: !!res?.stale,
    releases: res ? { ...s.releases, [source]: res.releases } : s.releases,
  }));
}

/** 面板首次打开:拉源列表与已安装;已有数据时只做静默刷新已安装。 */
export async function prime() {
  loadInstalled();
  if (store.get().sources.length) return loadReleases();
  const res = await guard(SCOPE, protonApi.sources);
  if (!res) return;
  store.set({ sources: res.sources, v3: res.x86_64_v3, source: res.sources[0]?.id ?? "" });
  await loadReleases();
}

export function selectSource(source: string) {
  store.set({ source, expanded: false });
  loadReleases();
}

export function install(release: Release) {
  return guard(SCOPE, () => protonApi.install(store.get().source, release.tag));
}

export async function uninstall(name: string) {
  const state = await guard(SCOPE, () => protonApi.uninstall(name));
  if (state) store.set({ installed: state.tools, restartNeeded: true });
}

export function restartSteam() {
  const client = (window as unknown as { SteamClient?: any }).SteamClient;
  client?.User?.StartRestart?.(false);
}

import { invoke } from "../../core/api";
import type { TaskView } from "../../ui/TaskProgress";

// proton 工具的后端接口与界面快照,对应 py_modules/deckytools/tools/proton/tool.py。
// 所有状态与判断(是否已安装、是否最新、是否需要重启、进行中任务)都由后端给出。
export const TOOL = "proton";

export interface SourceView {
  id: string;
  name: string;
  /** 本机会使用 x86-64-v3 优化包 */
  v3: boolean;
}

export interface ReleaseView {
  tag: string;
  published: string;
  size: number;
  prerelease: boolean;
  latest: boolean;
  installed: boolean;
  task: TaskView | null;
}

export interface InstalledTool {
  name: string;
  display_name: string;
  foreign_arch: boolean;
}

export interface ProtonView {
  sources: SourceView[];
  source: string;
  releases: ReleaseView[];
  releases_loaded: boolean;
  loading: boolean;
  stale: boolean;
  error: string | null;
  installed: InstalledTool[];
  installed_loaded: boolean;
  restart_needed: boolean;
}

export function isView(v: unknown): v is ProtonView {
  const s = v as ProtonView;
  return !!s && Array.isArray(s.sources) && Array.isArray(s.releases) && Array.isArray(s.installed);
}

export const protonApi = {
  view: () => invoke<ProtonView>(TOOL, "view"),
  selectSource: (source: string) => invoke<ProtonView>(TOOL, "select_source", { source }),
  refresh: () => invoke<ProtonView>(TOOL, "refresh"),
  install: (tag: string) => invoke<ProtonView>(TOOL, "install", { tag }),
  uninstall: (name: string) => invoke<ProtonView>(TOOL, "uninstall", { name }),
  restartSteam: () => invoke<null>(TOOL, "restart_steam"),
};

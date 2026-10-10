import { invoke } from "../../core/api";
import type { Task } from "../../core/tasks";

// proton 工具的后端接口,对应 py_modules/deckytools/tools/proton/tool.py 的 @rpc 方法。
export const TOOL = "proton";

export interface Source {
  id: string;
  name: string;
  repo: string;
  homepage: string;
  has_v3: boolean;
}

export interface Release {
  tag: string;
  published: string;
  prerelease: boolean;
  asset: string;
  name: string; // 安装后的目录名(= 压缩包去后缀)
  size: number;
  url: string;
  checksum_url: string;
}

export interface InstalledTool {
  name: string;
  display_name: string;
  symlink: boolean;
  foreign_arch: boolean;
  mtime: number;
}

export interface InstalledState {
  dir: string;
  tools: InstalledTool[];
}

export const protonApi = {
  sources: () => invoke<{ sources: Source[]; x86_64_v3: boolean }>(TOOL, "sources"),
  releases: (source: string, refresh = false) =>
    invoke<{ releases: Release[]; fetched: number; stale?: boolean }>(TOOL, "releases", {
      source,
      refresh,
    }),
  installed: () => invoke<InstalledState>(TOOL, "installed"),
  install: (source: string, tag: string) => invoke<Task>(TOOL, "install", { source, tag }),
  uninstall: (name: string) => invoke<InstalledState>(TOOL, "uninstall", { name }),
};

/** 与后端 ctx.start_task 的去重键一致:"<tool>:<source>:<tag>"。 */
export const installKey = (source: string, tag: string) => `${TOOL}:${source}:${tag}`;

export function isInstalledState(v: unknown): v is InstalledState {
  if (!v || typeof v !== "object") return false;
  const s = v as Record<string, unknown>;
  return typeof s.dir === "string" && Array.isArray(s.tools);
}

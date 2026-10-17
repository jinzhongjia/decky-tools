import type { FC, ReactNode } from "react";

// 前端工具注册表。每个工具一份 ToolDef,与后端 py_modules/deckytools/tools 的 Tool.id 对应。
// 前端只负责渲染后端快照;何时通知、通知什么由后端决定,这里只把 (key, params) 翻译成文案。
export interface ToolDef {
  id: string;
  icon: ReactNode;
  title: () => string;
  description: () => string;
  /** QAM 内的工具面板(Hub 负责外层的返回/标题)。 */
  Panel: FC;
  /** 后端通知 (key, params) → 本地化正文;未知 key 返回 null(不显示)。 */
  message?: (key: string, params: Record<string, unknown>) => string | null;
}

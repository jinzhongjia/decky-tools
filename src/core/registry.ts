import type { FC, ReactNode } from "react";

// 前端工具注册表。每个工具一份 ToolDef,与后端 py_modules/deckytools/tools 的 Tool.id 对应。
export interface ToolDef {
  id: string;
  icon: ReactNode;
  title: () => string;
  description: () => string;
  /** QAM 内的工具面板(Hub 负责外层的返回/标题)。 */
  Panel: FC;
  /** 插件加载时调用,返回清理函数;用于订阅全局事件(如完成提示)。 */
  setup?: () => () => void;
}

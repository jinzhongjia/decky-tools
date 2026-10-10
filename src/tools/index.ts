import type { ToolDef } from "../core/registry";
import { monitorTool } from "./monitor";
import { protonTool } from "./proton";

// 已注册工具,顺序即 QAM 列表顺序。新增工具在这里加一项(后端 py_modules/deckytools/tools 同步注册)。
export const TOOLS: ToolDef[] = [protonTool, monitorTool];

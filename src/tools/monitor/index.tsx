import { FaChartLine } from "react-icons/fa";

import type { ToolDef } from "../../core/registry";
import { TOOL } from "./api";
import { MonitorPanel } from "./Panel";
import { t } from "./strings";

export const monitorTool: ToolDef = {
  id: TOOL,
  icon: <FaChartLine />,
  title: () => t("title"),
  description: () => t("description"),
  Panel: MonitorPanel,
};

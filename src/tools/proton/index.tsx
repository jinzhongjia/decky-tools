import { FaWineGlassAlt } from "react-icons/fa";

import { errorText } from "../../core/i18n";
import type { ToolDef } from "../../core/registry";
import { TOOL } from "./api";
import { ProtonPanel } from "./Panel";
import { t } from "./strings";

/** 后端通知(tools/proton/tool.py 的 ctx.notify)→ 文案。 */
function message(key: string, params: Record<string, unknown>): string | null {
  const name = String(params.name ?? "");
  if (key === "install_done") return t("installDone", { name });
  if (key === "install_failed")
    return t("installFailed", { name, reason: errorText(String(params.error)) });
  return null;
}

export const protonTool: ToolDef = {
  id: TOOL,
  icon: <FaWineGlassAlt />,
  title: () => t("title"),
  description: () => t("description"),
  Panel: ProtonPanel,
  message,
};

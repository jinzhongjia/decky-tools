import { toaster } from "@decky/api";
import { FaWineGlassAlt } from "react-icons/fa";

import { onToolEvent } from "../../core/api";
import { errorText } from "../../core/i18n";
import type { ToolDef } from "../../core/registry";
import { onTaskChange } from "../../core/tasks";
import { TOOL, isInstalledState } from "./api";
import { ProtonPanel } from "./Panel";
import { store } from "./state";
import { t } from "./strings";

// 全局订阅:已安装列表推送 + 安装任务结束提示(用户多半已关掉 QAM,需 toast)。
function setup() {
  const offInstalled = onToolEvent(TOOL, "installed", (data) => {
    if (isInstalledState(data)) store.set({ installed: data.tools, installedLoaded: true });
  });
  const offTasks = onTaskChange((task, prev) => {
    if (task.tool !== TOOL || task.kind !== "install" || prev?.state === task.state) return;
    const name = String(task.meta.name ?? task.title);
    if (task.state === "done") {
      store.set({ restartNeeded: true });
      toaster.toast({ title: t("title"), body: t("installDone", { name }) });
    } else if (task.state === "failed") {
      const body = t("installFailed", { name, reason: errorText(task.error) });
      toaster.toast({ title: t("title"), body });
    }
  });
  return () => {
    offInstalled();
    offTasks();
  };
}

export const protonTool: ToolDef = {
  id: TOOL,
  icon: <FaWineGlassAlt />,
  title: () => t("title"),
  description: () => t("description"),
  Panel: ProtonPanel,
  setup,
};

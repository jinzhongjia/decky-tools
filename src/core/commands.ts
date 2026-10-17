import { onToolEvent } from "./api";

// 只有 Steam 前端能执行的动作:由后端下令(core/command 事件),前端照做,不自行决定。
// 白名单与后端 core/tool.py 的 COMMANDS 一致。
type SteamClientLike = { User?: { StartRestart?: (force: boolean) => void } };

const COMMANDS: Record<string, () => void> = {
  restart_steam: () =>
    (window as unknown as { SteamClient?: SteamClientLike }).SteamClient?.User?.StartRestart?.(
      false
    ),
};

export function startCommands(): () => void {
  return onToolEvent("core", "command", (data) => {
    const name = (data as { name?: unknown } | null)?.name;
    if (typeof name === "string" && COMMANDS[name]) COMMANDS[name]();
  });
}

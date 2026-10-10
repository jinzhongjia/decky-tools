import { addEventListener, callable, removeEventListener } from "@decky/api";

// 前端 ↔ 后端唯一接口层。后端只暴露一个 RPC `call(tool, method, params)`,
// 返回信封 {ok,data}|{ok:false,error};事件统一为 `decky_tools_event` {tool,type,data}。
// 契约另一端见 py_modules/deckytools/core/app.py 与 core/tool.py。

type Envelope<T> = { ok: true; data: T } | { ok: false; error: string };

const rawCall = callable<[string, string, Record<string, unknown> | undefined], Envelope<unknown>>(
  "call"
);

/** 后端返回的稳定错误码(或前端传输层错误 transport)。 */
export class ToolError extends Error {
  constructor(public code: string) {
    super(code);
  }
}

export async function invoke<T>(
  tool: string,
  method: string,
  params?: Record<string, unknown>
): Promise<T> {
  let res: Envelope<unknown>;
  try {
    res = await rawCall(tool, method, params);
  } catch (e) {
    console.error("[decky-tools] call failed", tool, method, e);
    throw new ToolError("transport");
  }
  if (!res || typeof res !== "object") throw new ToolError("transport");
  if (!res.ok) throw new ToolError(typeof res.error === "string" ? res.error : "internal");
  return res.data as T;
}

const EVENT = "decky_tools_event";
type Handler = (data: unknown) => void;
const handlers = new Map<string, Set<Handler>>();

function dispatch(payload: unknown) {
  if (!payload || typeof payload !== "object") return;
  const { tool, type, data } = payload as { tool?: unknown; type?: unknown; data?: unknown };
  if (typeof tool !== "string" || typeof type !== "string") return;
  handlers.get(`${tool}/${type}`)?.forEach((h) => {
    try {
      h(data);
    } catch (e) {
      console.error("[decky-tools] event handler failed", tool, type, e);
    }
  });
}

let attached: ((payload: unknown) => void) | null = null;

/** 插件加载时挂一次全局监听,所有工具的事件在这里多路分发。 */
export function attachEvents() {
  if (!attached) attached = addEventListener<[unknown]>(EVENT, dispatch);
}

export function detachEvents() {
  if (attached) removeEventListener(EVENT, attached);
  attached = null;
  handlers.clear();
}

/** 订阅某工具的某类事件;返回退订函数。data 未经校验,订阅方自行收窄。 */
export function onToolEvent(tool: string, type: string, handler: Handler): () => void {
  const key = `${tool}/${type}`;
  if (!handlers.has(key)) handlers.set(key, new Set());
  handlers.get(key)!.add(handler);
  return () => handlers.get(key)?.delete(handler);
}

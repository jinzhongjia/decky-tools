import { useEffect, useState } from "react";

import { ToolError } from "./api";
import { errorText } from "./i18n";

// 极简错误总线:异步回调里 guard() 捕获错误推到对应 scope,由 <ErrorBanner scope> 渲染。
const current = new Map<string, string | null>();
const listeners = new Map<string, Set<(msg: string | null) => void>>();

export function reportError(scope: string, msg: string | null) {
  current.set(scope, msg);
  listeners.get(scope)?.forEach((l) => l(msg));
}

export function messageOf(e: unknown): string {
  return errorText(e instanceof ToolError ? e.code : "internal");
}

export function useError(scope: string) {
  const [msg, setMsg] = useState<string | null>(current.get(scope) ?? null);
  useEffect(() => {
    if (!listeners.has(scope)) listeners.set(scope, new Set());
    listeners.get(scope)!.add(setMsg);
    return () => void listeners.get(scope)?.delete(setMsg);
  }, [scope]);
  return [msg, () => reportError(scope, null)] as const;
}

/** 包裹异步操作:失败不外抛(不拖垮宿主 UI),错误推到 scope 的横幅;成功清掉旧错误。 */
export async function guard<T>(scope: string, fn: () => Promise<T>): Promise<T | undefined> {
  try {
    const value = await fn();
    reportError(scope, null);
    return value;
  } catch (e) {
    if (!(e instanceof ToolError)) console.error("[decky-tools]", scope, e);
    reportError(scope, messageOf(e));
    return undefined;
  }
}

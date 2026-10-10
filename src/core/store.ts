import { useEffect, useState } from "react";

// 模块级小 store:Decky 会反复卸载/重挂 QAM 面板,组件内 useState 每次重挂就丢,
// 需要跨重挂保留的界面状态放这里。
export interface Store<T> {
  get(): T;
  set(patch: Partial<T> | ((prev: T) => Partial<T>)): void;
  subscribe(fn: (v: T) => void): () => void;
}

export function createStore<T extends object>(initial: T): Store<T> {
  let value = initial;
  const subs = new Set<(v: T) => void>();
  return {
    get: () => value,
    set(patch) {
      const next = typeof patch === "function" ? patch(value) : patch;
      value = { ...value, ...next };
      subs.forEach((fn) => fn(value));
    },
    subscribe(fn) {
      subs.add(fn);
      return () => subs.delete(fn);
    },
  };
}

export function useStore<T extends object>(store: Store<T>): T {
  const [value, setValue] = useState(store.get());
  useEffect(() => {
    setValue(store.get());
    return store.subscribe(setValue);
  }, [store]);
  return value;
}

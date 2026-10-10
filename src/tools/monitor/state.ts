import { onToolEvent } from "../../core/api";
import { guard } from "../../core/errors";
import { createStore } from "../../core/store";
import {
  Sample,
  Series,
  SystemInfo,
  TOOL,
  monitorApi,
  sampleToPoint,
  toSample,
  toSeries,
} from "./api";

export const SCOPE = "monitor";
const RENEW_MS = 5000; // 后端租约 15s,每 5s 续一次
const LONG_REFRESH_MS = 10000; // 30 分钟视图按 10s 分桶,同频重拉

/** 可选时间范围(秒),与后端 tools/monitor/tool.py 的 RANGES 一致。 */
export const RANGES = [120, 1800] as const;
export type Range = (typeof RANGES)[number];
export const SHORT: Range = 120;

export const store = createStore<{
  sample: Sample | null;
  info: SystemInfo | null;
  range: Range;
  series: Series;
  capacity: number;
}>({ sample: null, info: null, range: SHORT, series: {}, capacity: SHORT });

async function loadHistory() {
  const range = store.get().range;
  const res = await guard(SCOPE, () => monitorApi.history(range));
  const series = res && toSeries(res);
  if (series && store.get().range === range) {
    store.set({ series, capacity: res.points.length });
  }
}

/** 2 分钟视图逐秒追加实时点(与 1s 分桶对齐);30 分钟视图靠定时重拉。 */
function append(sample: Sample) {
  store.set((s) => {
    if (s.range !== SHORT) return { sample };
    const point = sampleToPoint(sample);
    const series: Series = {};
    for (const [key, value] of Object.entries(point)) {
      series[key] = [...(s.series[key] ?? []), value].slice(-s.capacity);
    }
    return { sample, series };
  });
}

export function selectRange(range: Range) {
  if (store.get().range === range) return;
  store.set({ range, series: {}, capacity: range === SHORT ? SHORT : range / 10 });
  loadHistory();
}

async function renew() {
  const res = await guard(SCOPE, monitorApi.watch);
  if (!res) return;
  const sample = toSample(res.sample);
  store.set((s) => ({ sample: sample ?? s.sample, info: res.info ?? s.info }));
  if (!store.get().info) await refreshInfo();
}

export async function refreshInfo() {
  const info = await guard(SCOPE, () => monitorApi.info(true));
  if (info) store.set({ info });
}

/** 面板挂载期间:续租实时推送 + 拉历史 + 订阅采样。返回清理函数。 */
export function startLive(): () => void {
  const off = onToolEvent(TOOL, "sample", (data) => {
    const sample = toSample(data);
    if (sample) append(sample);
  });
  renew().then(loadHistory);
  const renewTimer = setInterval(renew, RENEW_MS);
  const historyTimer = setInterval(() => {
    if (store.get().range !== SHORT) loadHistory();
  }, LONG_REFRESH_MS);
  // 不主动 unwatch:QAM 会频繁重挂,交给后端租约过期关闭推送
  return () => {
    clearInterval(renewTimer);
    clearInterval(historyTimer);
    off();
  };
}

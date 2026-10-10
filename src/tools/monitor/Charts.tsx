import { PanelSection } from "@decky/ui";

import { LineChart } from "../../ui/LineChart";
import { MetricCard } from "../../ui/MetricCard";
import { Sample } from "./api";
import { freq, gb, join, pct, ratio, temp, watts } from "./format";
import { useStore } from "../../core/store";
import { Segmented } from "../../ui/Segmented";
import { RANGES, SHORT, selectRange, store } from "./state";
import { t } from "./strings";

const COLORS = {
  cpu: "#1a9fff",
  gpu: "#b07cff",
  memory: "#2ec27e",
  power: "#ff9f1a",
  battery: "#e5d34b",
};

/** 功耗:Steam Deck 用 APU 功耗;其它设备退回电池放电功率(充电时无意义,置空)。 */
function powerMw(
  apu: number | null | undefined,
  battery: number | null | undefined
): number | null {
  if (apu != null) return apu;
  return battery != null && battery > 0 ? battery : null;
}

const scaled = (values: (number | null)[] | undefined, div: number) =>
  (values ?? []).map((v) => (v == null ? null : v / div));

function Chart(props: { values: (number | null)[]; color: string; max?: number; minMax?: number }) {
  const { capacity } = useStore(store);
  return <LineChart capacity={capacity} {...props} />;
}

function RangePicker() {
  const { range } = useStore(store);
  return (
    <Segmented
      options={RANGES.map((r) => ({ value: r, label: t(r === SHORT ? "range2m" : "range30m") }))}
      value={range}
      onChange={selectRange}
    />
  );
}

export function PerformanceCharts({ s }: { s: Sample }) {
  const { series } = useStore(store);
  const memPct = (x: Sample) => ratio(x.mem_used_mb, x.mem_total_mb);
  const memAmount =
    s.mem_used_mb != null && s.mem_total_mb != null
      ? `${gb(s.mem_used_mb)} / ${gb(s.mem_total_mb)}`
      : gb(s.mem_total_mb);
  return (
    <PanelSection title={t("performance")}>
      <RangePicker />
      <MetricCard
        label={t("cpu")}
        value={pct(s.cpu_pct_x10)}
        chart={<Chart values={scaled(series.cpu_pct_x10, 10)} color={COLORS.cpu} max={100} />}
        detail={join(freq(s.cpu_mhz), temp(s.cpu_temp_mc))}
      />
      <MetricCard
        label={t("gpu")}
        value={s.gpu_pct == null ? null : `${s.gpu_pct}%`}
        chart={<Chart values={scaled(series.gpu_pct, 1)} color={COLORS.gpu} max={100} />}
        detail={join(freq(s.gpu_mhz), temp(s.gpu_temp_mc))}
      />
      <MetricCard
        label={t("memory")}
        value={memPct(s) == null ? null : `${Math.round(memPct(s)!)}%`}
        chart={<Chart values={scaled(series.mem_pct_x10, 10)} color={COLORS.memory} max={100} />}
        detail={memAmount}
      />
    </PanelSection>
  );
}

/** 窗口内峰值与均值,帮助读懂自适应纵轴的功耗图。 */
function peakAvg(values: (number | null)[]): string | null {
  const nums = values.filter((v): v is number => v != null);
  if (nums.length < 2) return null;
  const avg = nums.reduce((a, b) => a + b, 0) / nums.length;
  return t("peakAvg", { peak: watts(Math.max(...nums))!, avg: watts(avg)! });
}

export function PowerCharts({ s }: { s: Sample }) {
  const { series } = useStore(store);
  const power = powerMw(s.apu_power_mw, s.battery_power_mw);
  const apu = series.apu_power_mw ?? [];
  const battery = series.battery_power_mw ?? [];
  const powerSeries = apu.map((v, i) => powerMw(v, battery[i]));
  const flow = s.battery_power_mw ? watts(s.battery_power_mw) : null;
  return (
    <PanelSection title={t("power")}>
      <MetricCard
        label={s.apu_power_mw != null ? t("apuPower") : t("dischargePower")}
        value={power == null ? null : watts(power)}
        chart={<Chart values={powerSeries} color={COLORS.power} minMax={5000} />}
        detail={peakAvg(powerSeries)}
      />
      <MetricCard
        label={t("battery")}
        value={s.battery_pct == null ? null : `${s.battery_pct}%`}
        chart={<Chart values={scaled(series.battery_pct, 1)} color={COLORS.battery} max={100} />}
        detail={join(s.battery_status ? t(s.battery_status) : null, flow)}
      />
    </PanelSection>
  );
}

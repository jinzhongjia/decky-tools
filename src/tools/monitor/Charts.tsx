import { PanelSection } from "@decky/ui";

import { LineChart } from "../../ui/LineChart";
import { MetricCard } from "../../ui/MetricCard";
import { Segmented } from "../../ui/Segmented";
import { Current, MonitorView } from "./api";
import { freq, gb, join, pct, temp, watts } from "./format";
import { selectRange } from "./state";
import { t } from "./strings";

const COLORS = {
  cpu: "#1a9fff",
  gpu: "#b07cff",
  memory: "#2ec27e",
  power: "#ff9f1a",
  battery: "#e5d34b",
};

type ChartProps = { view: MonitorView; metric: keyof typeof COLORS; max?: number; minMax?: number };

function Chart({ view, metric, max, minMax }: ChartProps) {
  return (
    <LineChart
      values={view.series[metric] ?? []}
      capacity={view.capacity}
      color={COLORS[metric]}
      max={max}
      minMax={minMax}
    />
  );
}

function RangePicker({ view }: { view: MonitorView }) {
  return (
    <Segmented
      options={view.ranges.map((r) => ({ value: r, label: t("rangeMinutes", { n: r / 60 }) }))}
      value={view.range}
      onChange={selectRange}
    />
  );
}

export function PerformanceCharts({ view, c }: { view: MonitorView; c: Current }) {
  const memAmount =
    c.mem_used_mb != null ? `${gb(c.mem_used_mb)} / ${gb(c.mem_total_mb)}` : gb(c.mem_total_mb);
  return (
    <PanelSection title={t("performance")}>
      <RangePicker view={view} />
      <MetricCard
        label={t("cpu")}
        value={pct(c.cpu_pct)}
        chart={<Chart view={view} metric="cpu" max={100} />}
        detail={join(freq(c.cpu_mhz), temp(c.cpu_temp_c))}
      />
      <MetricCard
        label={t("gpu")}
        value={pct(c.gpu_pct)}
        chart={<Chart view={view} metric="gpu" max={100} />}
        detail={join(freq(c.gpu_mhz), temp(c.gpu_temp_c))}
      />
      <MetricCard
        label={t("memory")}
        value={pct(c.mem_pct)}
        chart={<Chart view={view} metric="memory" max={100} />}
        detail={memAmount}
      />
    </PanelSection>
  );
}

export function PowerCharts({ view, c }: { view: MonitorView; c: Current }) {
  const stats = view.power_stats;
  return (
    <PanelSection title={t("power")}>
      <MetricCard
        label={c.power_source === "apu" ? t("apuPower") : t("dischargePower")}
        value={watts(c.power_mw)}
        chart={<Chart view={view} metric="power" minMax={5000} />}
        detail={stats && t("peakAvg", { peak: watts(stats.peak)!, avg: watts(stats.avg)! })}
      />
      <MetricCard
        label={t("battery")}
        value={pct(c.battery_pct)}
        chart={<Chart view={view} metric="battery" max={100} />}
        detail={join(
          c.battery_status ? t(c.battery_status) : null,
          c.battery_power_mw ? watts(c.battery_power_mw) : null
        )}
      />
    </PanelSection>
  );
}

import { ButtonItem, PanelSection, PanelSectionRow } from "@decky/ui";
import { memo, useEffect } from "react";

import { useStore } from "../../core/store";
import { ErrorBanner } from "../../ui/ErrorBanner";
import { InfoRow } from "../../ui/InfoRow";
import { SystemInfo } from "./api";
import { PerformanceCharts, PowerCharts } from "./Charts";
import { join } from "./format";
import { SCOPE, refreshInfo, startLive, store } from "./state";
import { t } from "./strings";

const dim: React.CSSProperties = { opacity: 0.6, fontSize: "0.85em", textAlign: "center" };

// info 只在刷新时变化:memo 后每秒的快照更新不会重渲染这一区
const SystemSection = memo(function SystemSection({ info }: { info: SystemInfo | null }) {
  const ip = info?.ip ? join(info.ip, info.interface ?? null) : info ? t("noNetwork") : null;
  const rows: [string, string | null | undefined][] = [
    [t("ip"), ip],
    [t("hostname"), info?.hostname],
    [t("device"), info?.product],
    [t("os"), info ? join(info.os ?? null, info.os_build ?? null) : null],
    [t("kernel"), info?.kernel],
    [t("cpuModel"), info?.cpu_model],
  ];
  return (
    <PanelSection title={t("system")}>
      {rows.map(([label, value]) => (
        <InfoRow key={label} label={label} value={value ?? null} />
      ))}
      <PanelSectionRow>
        <ButtonItem layout="below" onClick={refreshInfo}>
          {t("refresh")}
        </ButtonItem>
      </PanelSectionRow>
    </PanelSection>
  );
});

export function MonitorPanel() {
  const { view, info } = useStore(store);
  useEffect(() => startLive(), []);
  const c = view?.current;
  return (
    <>
      <ErrorBanner scope={SCOPE} />
      {view && c ? (
        <>
          <PerformanceCharts view={view} c={c} />
          <PowerCharts view={view} c={c} />
        </>
      ) : (
        <PanelSection>
          <PanelSectionRow>
            <div style={dim}>{t("waiting")}</div>
          </PanelSectionRow>
        </PanelSection>
      )}
      <SystemSection info={info} />
    </>
  );
}

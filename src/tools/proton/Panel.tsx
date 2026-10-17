import { ButtonItem, PanelSection, PanelSectionRow } from "@decky/ui";
import { useEffect } from "react";

import { errorText } from "../../core/i18n";
import { useStore } from "../../core/store";
import { ErrorBanner } from "../../ui/ErrorBanner";
import { DownloadSection } from "./DownloadSection";
import { InstalledSection } from "./InstalledSection";
import { SCOPE, actions, startView, store } from "./state";
import { t } from "./strings";

const dim: React.CSSProperties = { opacity: 0.6, fontSize: "0.85em", textAlign: "center" };

export function ProtonPanel() {
  const { view } = useStore(store);
  useEffect(() => startView(), []);
  return (
    <>
      <ErrorBanner scope={SCOPE} />
      {view?.restart_needed && (
        <PanelSection>
          <PanelSectionRow>
            <ButtonItem
              layout="below"
              description={t("restartHint")}
              onClick={actions.restartSteam}
            >
              {t("restartNow")}
            </ButtonItem>
          </PanelSectionRow>
        </PanelSection>
      )}
      {view ? (
        <>
          {view.error && !view.stale && (
            <PanelSectionRow>
              <div style={dim}>{errorText(view.error)}</div>
            </PanelSectionRow>
          )}
          <DownloadSection view={view} />
          <InstalledSection view={view} />
        </>
      ) : (
        <PanelSectionRow>
          <div style={dim}>{t("loading")}</div>
        </PanelSectionRow>
      )}
    </>
  );
}

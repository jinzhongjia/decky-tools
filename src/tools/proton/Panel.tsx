import { ButtonItem, PanelSection, PanelSectionRow } from "@decky/ui";
import { useEffect } from "react";

import { useStore } from "../../core/store";
import { ErrorBanner } from "../../ui/ErrorBanner";
import { DownloadSection } from "./DownloadSection";
import { InstalledSection } from "./InstalledSection";
import { SCOPE, prime, restartSteam, store } from "./state";
import { t } from "./strings";

function RestartRow() {
  const { restartNeeded } = useStore(store);
  if (!restartNeeded) return null;
  return (
    <PanelSection>
      <PanelSectionRow>
        <ButtonItem layout="below" description={t("restartHint")} onClick={restartSteam}>
          {t("restartNow")}
        </ButtonItem>
      </PanelSectionRow>
    </PanelSection>
  );
}

export function ProtonPanel() {
  useEffect(() => {
    prime();
  }, []);
  return (
    <>
      <ErrorBanner scope={SCOPE} />
      <RestartRow />
      <DownloadSection />
      <InstalledSection />
    </>
  );
}

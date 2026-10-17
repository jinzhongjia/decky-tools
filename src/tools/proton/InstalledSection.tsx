import { ConfirmModal, PanelSection, PanelSectionRow, showModal } from "@decky/ui";

import { ActionRow } from "../../ui/ActionRow";
import { Badge } from "../../ui/Badge";
import { InstalledTool, ProtonView } from "./api";
import { actions } from "./state";
import { t } from "./strings";

const dim: React.CSSProperties = { opacity: 0.6, fontSize: "0.85em", textAlign: "center" };

function confirmUninstall(tool: InstalledTool) {
  showModal(
    <ConfirmModal
      strTitle={t("uninstallTitle", { name: tool.display_name })}
      strDescription={t("uninstallBody")}
      strOKButtonText={t("uninstall")}
      bDestructiveWarning
      onOK={() => actions.uninstall(tool.name)}
    />
  );
}

export function InstalledSection({ view }: { view: ProtonView }) {
  const { installed, installed_loaded: installedLoaded } = view;
  return (
    <PanelSection title={`${t("installed")}${installed.length ? ` (${installed.length})` : ""}`}>
      {!installedLoaded && (
        <PanelSectionRow>
          <div style={dim}>{t("loading")}</div>
        </PanelSectionRow>
      )}
      {installedLoaded && !installed.length && (
        <PanelSectionRow>
          <div style={dim}>{t("noneInstalled")}</div>
        </PanelSectionRow>
      )}
      {installed.map((tool) => (
        <PanelSectionRow key={tool.name}>
          <ActionRow
            label={
              <span>
                {tool.display_name}
                {tool.foreign_arch && <Badge tone="amber">{t("foreignArch")}</Badge>}
              </span>
            }
            description={
              tool.foreign_arch
                ? t("foreignArchDesc")
                : tool.display_name !== tool.name
                  ? tool.name
                  : undefined
            }
            action={t("uninstall")}
            onClick={() => confirmUninstall(tool)}
          />
        </PanelSectionRow>
      ))}
    </PanelSection>
  );
}

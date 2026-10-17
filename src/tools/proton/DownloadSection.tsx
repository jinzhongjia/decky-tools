import { ButtonItem, DropdownItem, PanelSection, PanelSectionRow } from "@decky/ui";

import { useStore } from "../../core/store";
import { ActionRow } from "../../ui/ActionRow";
import { Badge } from "../../ui/Badge";
import { fmtBytes, fmtDate } from "../../ui/format";
import { TaskRow } from "../../ui/TaskProgress";
import { ProtonView, ReleaseView } from "./api";
import { SCOPE, actions, store } from "./state";
import { t } from "./strings";

const COLLAPSED = 5;
const dim: React.CSSProperties = { opacity: 0.6, fontSize: "0.85em", textAlign: "center" };

function ReleaseRow({ release }: { release: ReleaseView }) {
  const label = (
    <span>
      {release.tag}
      {release.latest && <Badge>{t("latest")}</Badge>}
      {release.prerelease && <Badge tone="amber">{t("prerelease")}</Badge>}
    </span>
  );
  return (
    <PanelSectionRow>
      {release.task ? (
        <TaskRow label={label} task={release.task} errorScope={SCOPE} />
      ) : (
        <ActionRow
          label={label}
          description={`${fmtDate(release.published)} · ${fmtBytes(release.size)}`}
          disabled={release.installed}
          action={release.installed ? t("isInstalled") : t("install")}
          onClick={() => actions.install(release.tag)}
        />
      )}
    </PanelSectionRow>
  );
}

function ReleaseList({ view }: { view: ProtonView }) {
  const { expanded } = useStore(store);
  if (!view.releases_loaded)
    return <div style={dim}>{view.loading ? t("loading") : t("noReleases")}</div>;
  if (!view.releases.length) return <div style={dim}>{t("noReleases")}</div>;
  const shown = expanded ? view.releases : view.releases.slice(0, COLLAPSED);
  return (
    <>
      {view.stale && <div style={dim}>{t("stale")}</div>}
      {shown.map((r) => (
        <ReleaseRow key={r.tag} release={r} />
      ))}
      {view.releases.length > COLLAPSED && (
        <PanelSectionRow>
          <ButtonItem layout="below" onClick={() => store.set({ expanded: !expanded })}>
            {expanded ? t("showLess") : t("showMore")}
          </ButtonItem>
        </PanelSectionRow>
      )}
    </>
  );
}

export function DownloadSection({ view }: { view: ProtonView }) {
  const source = view.sources.find((s) => s.id === view.source);
  return (
    <PanelSection title={t("download")}>
      <PanelSectionRow>
        <DropdownItem
          label={t("source")}
          rgOptions={view.sources.map((s) => ({ data: s.id, label: s.name }))}
          selectedOption={view.source}
          onChange={(opt) => actions.selectSource(opt.data as string)}
        />
      </PanelSectionRow>
      {source?.v3 && (
        <PanelSectionRow>
          <div style={dim}>{t("v3Hint")}</div>
        </PanelSectionRow>
      )}
      <ReleaseList view={view} />
      <PanelSectionRow>
        <ButtonItem layout="below" disabled={view.loading} onClick={actions.refresh}>
          {view.loading ? t("loading") : t("refresh")}
        </ButtonItem>
      </PanelSectionRow>
    </PanelSection>
  );
}

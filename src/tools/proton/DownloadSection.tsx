import { ButtonItem, DropdownItem, PanelSection, PanelSectionRow } from "@decky/ui";

import { useStore } from "../../core/store";
import { isActive, useTaskByKey } from "../../core/tasks";
import { fmtBytes, fmtDate } from "../../ui/format";
import { ActionRow } from "../../ui/ActionRow";
import { Badge } from "../../ui/Badge";
import { TaskRow } from "../../ui/TaskProgress";
import { Release, installKey } from "./api";
import { SCOPE, install, loadReleases, selectSource, store } from "./state";
import { t } from "./strings";

const COLLAPSED = 5;
const dim: React.CSSProperties = { opacity: 0.6, fontSize: "0.85em", textAlign: "center" };

function ReleaseRow({ release, latest }: { release: Release; latest: boolean }) {
  const { source, installed } = useStore(store);
  const task = useTaskByKey(installKey(source, release.tag));
  const done = installed.some((x) => x.name === release.name);
  const label = (
    <span>
      {release.tag}
      {latest && <Badge>{t("latest")}</Badge>}
      {release.prerelease && <Badge tone="amber">{t("prerelease")}</Badge>}
    </span>
  );

  return (
    <PanelSectionRow>
      {isActive(task) ? (
        <TaskRow label={label} task={task} errorScope={SCOPE} />
      ) : (
        <ActionRow
          label={label}
          description={`${fmtDate(release.published)} · ${fmtBytes(release.size)}`}
          disabled={done}
          action={done ? t("isInstalled") : t("install")}
          onClick={() => install(release)}
        />
      )}
    </PanelSectionRow>
  );
}

function ReleaseList() {
  const { source, releases, loadingReleases, expanded, stale } = useStore(store);
  const list = releases[source];
  if (!list) return <div style={dim}>{loadingReleases ? t("loading") : t("noReleases")}</div>;
  if (!list.length) return <div style={dim}>{t("noReleases")}</div>;
  const shown = expanded ? list : list.slice(0, COLLAPSED);
  return (
    <>
      {stale && <div style={dim}>{t("stale")}</div>}
      {shown.map((r, i) => (
        <ReleaseRow key={r.tag} release={r} latest={i === 0 && !r.prerelease} />
      ))}
      {list.length > COLLAPSED && (
        <PanelSectionRow>
          <ButtonItem layout="below" onClick={() => store.set({ expanded: !expanded })}>
            {expanded ? t("showLess") : t("showMore")}
          </ButtonItem>
        </PanelSectionRow>
      )}
    </>
  );
}

export function DownloadSection() {
  const { sources, source, v3, loadingReleases } = useStore(store);
  const hasV3 = v3 && !!sources.find((s) => s.id === source)?.has_v3;
  return (
    <PanelSection title={t("download")}>
      {sources.length > 0 && (
        <PanelSectionRow>
          <DropdownItem
            label={t("source")}
            rgOptions={sources.map((s) => ({ data: s.id, label: s.name }))}
            selectedOption={source}
            onChange={(opt) => selectSource(opt.data as string)}
          />
        </PanelSectionRow>
      )}
      {hasV3 && (
        <PanelSectionRow>
          <div style={dim}>{t("v3Hint")}</div>
        </PanelSectionRow>
      )}
      <ReleaseList />
      <PanelSectionRow>
        <ButtonItem layout="below" disabled={loadingReleases} onClick={() => loadReleases(true)}>
          {loadingReleases ? t("loading") : t("refresh")}
        </ButtonItem>
      </PanelSectionRow>
    </PanelSection>
  );
}

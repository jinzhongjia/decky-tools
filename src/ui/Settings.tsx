import { ButtonItem, PanelSection, PanelSectionRow, TextField } from "@decky/ui";
import { toaster } from "@decky/api";
import { useEffect, useState } from "react";

import { invoke } from "../core/api";
import { guard } from "../core/errors";
import { ErrorBanner } from "./ErrorBanner";
import { t } from "./strings";

const SCOPE = "settings";

// 全局选项,对应后端 core 工具的 get_options / set_option。
export function Settings() {
  const [mirror, setMirror] = useState("");
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    guard(SCOPE, () => invoke<{ github_mirror: string }>("core", "get_options")).then((o) => {
      if (o) setMirror(o.github_mirror || "");
      setLoaded(true);
    });
  }, []);

  const save = async () => {
    const ok = await guard(SCOPE, () =>
      invoke("core", "set_option", { key: "github_mirror", value: mirror.trim() })
    );
    if (ok !== undefined) toaster.toast({ title: t("title"), body: t("saved") });
  };

  return (
    <PanelSection title={t("settings")}>
      <ErrorBanner scope={SCOPE} />
      <PanelSectionRow>
        <TextField
          label={t("mirror")}
          description={t("mirrorDesc")}
          value={mirror}
          disabled={!loaded}
          onChange={(e) => setMirror(e.target.value)}
        />
      </PanelSectionRow>
      <PanelSectionRow>
        <ButtonItem layout="below" disabled={!loaded} onClick={save}>
          {t("save")}
        </ButtonItem>
      </PanelSectionRow>
    </PanelSection>
  );
}

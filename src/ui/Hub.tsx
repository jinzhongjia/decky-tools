import { ButtonItem, PanelSection, PanelSectionRow } from "@decky/ui";
import { FaArrowLeft, FaCog } from "react-icons/fa";
import type { ReactNode } from "react";

import { ToolDef } from "../core/registry";
import { createStore, useStore } from "../core/store";
import { TOOLS } from "../tools";
import { Footer } from "./Footer";
import { Settings } from "./Settings";
import { t } from "./strings";

// QAM 根:工具列表 ⇄ 单个工具面板 / 设置。当前视图放模块 store,QAM 重挂后停留原处。
const SETTINGS = "__settings";
const nav = createStore<{ view: string | null }>({ view: null });

function Entry(props: { icon: ReactNode; title: string; desc: string; onClick: () => void }) {
  return (
    <PanelSectionRow>
      <ButtonItem layout="below" description={props.desc} onClick={props.onClick}>
        <div style={{ display: "flex", alignItems: "center", gap: "0.6rem" }}>
          {props.icon}
          <span>{props.title}</span>
        </div>
      </ButtonItem>
    </PanelSectionRow>
  );
}

function Home() {
  const open = (view: string) => nav.set({ view });
  return (
    <>
      <PanelSection title={t("tools")}>
        {TOOLS.map((tool) => (
          <Entry
            key={tool.id}
            icon={tool.icon}
            title={tool.title()}
            desc={tool.description()}
            onClick={() => open(tool.id)}
          />
        ))}
      </PanelSection>
      <PanelSection>
        <Entry
          icon={<FaCog />}
          title={t("settings")}
          desc={t("settingsDesc")}
          onClick={() => open(SETTINGS)}
        />
        <Footer />
      </PanelSection>
    </>
  );
}

function BackBar({ title }: { title: string }) {
  return (
    <PanelSection>
      <PanelSectionRow>
        <ButtonItem layout="below" onClick={() => nav.set({ view: null })}>
          <div style={{ display: "flex", alignItems: "center", gap: "0.6rem" }}>
            <FaArrowLeft />
            <span>{title}</span>
          </div>
        </ButtonItem>
      </PanelSectionRow>
    </PanelSection>
  );
}

export function Hub() {
  const { view } = useStore(nav);
  if (view === SETTINGS) {
    return (
      <>
        <BackBar title={t("back")} />
        <Settings />
      </>
    );
  }
  const tool: ToolDef | undefined = TOOLS.find((x) => x.id === view);
  if (!tool) return <Home />;
  return (
    <>
      <BackBar title={t("back")} />
      <tool.Panel />
    </>
  );
}

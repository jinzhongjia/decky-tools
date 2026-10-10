import { Focusable, Navigation } from "@decky/ui";
import { FaGithub, FaTag } from "react-icons/fa";

import VERSION from "decky-tools:version";

const REPO = "https://github.com/jinzhongjia/decky-tools";
const rowStyle: React.CSSProperties = { display: "flex", alignItems: "center", gap: "0.4rem" };

export function Footer() {
  return (
    <div
      style={{
        marginTop: "1rem",
        display: "flex",
        flexDirection: "column",
        gap: "0.3rem",
        fontSize: "0.75em",
        opacity: 0.5,
      }}
    >
      <div style={rowStyle}>
        <FaTag />
        <span>Version: {VERSION}</span>
      </div>
      <Focusable
        style={{ ...rowStyle, cursor: "pointer" }}
        onActivate={() => Navigation.NavigateToExternalWeb(REPO)}
      >
        <FaGithub />
        <span>Github: {REPO.split(".com/")[1]}</span>
      </Focusable>
    </div>
  );
}

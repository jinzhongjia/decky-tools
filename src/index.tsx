import { definePlugin } from "@decky/api";
import { staticClasses } from "@decky/ui";
import { FaToolbox } from "react-icons/fa";

import { attachEvents, detachEvents } from "./core/api";
import { startCommands } from "./core/commands";
import { Boundary } from "./ui/Boundary";
import { Hub } from "./ui/Hub";
import { startNotifications } from "./ui/notifications";

export default definePlugin(() => {
  attachEvents();
  const cleanups = [startNotifications(), startCommands()];
  return {
    name: "Decky Tools",
    titleView: <div className={staticClasses.Title}>Decky Tools</div>,
    icon: <FaToolbox />,
    content: (
      <Boundary>
        <Hub />
      </Boundary>
    ),
    onDismount() {
      cleanups.forEach((fn) => fn());
      detachEvents();
    },
  };
});

import { definePlugin } from "@decky/api";
import { staticClasses } from "@decky/ui";
import { FaToolbox } from "react-icons/fa";

import { attachEvents, detachEvents } from "./core/api";
import { startTaskSync } from "./core/tasks";
import { TOOLS } from "./tools";
import { Boundary } from "./ui/Boundary";
import { Hub } from "./ui/Hub";

export default definePlugin(() => {
  attachEvents();
  const cleanups = [
    startTaskSync(),
    ...TOOLS.flatMap((tool) => (tool.setup ? [tool.setup()] : [])),
  ];
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

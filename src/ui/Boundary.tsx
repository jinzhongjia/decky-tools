import { Component, ReactNode } from "react";

import { t } from "./strings";

// 渲染期异常兜底:子树出错只显示降级 UI,不拖垮宿主 Steam UI。异步错误走 guard()。
export class Boundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state: { error: Error | null } = { error: null };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  componentDidCatch(error: Error, info: unknown) {
    console.error("[decky-tools] render error", error, info);
  }

  render() {
    if (!this.state.error) return this.props.children;
    return (
      <div style={{ padding: "1rem" }}>
        <div>{t("unavailable")}</div>
        <div style={{ opacity: 0.6, fontSize: "0.8em", marginTop: "0.5rem" }}>
          {this.state.error.message}
        </div>
      </div>
    );
  }
}

// 极简 i18n:中/英两套文案,按 Steam 客户端语言选,非中文一律英文。
// 内核与每个工具各自 defineStrings,键名互不干扰。
export type Lang = "zh" | "en";

export const lang: Lang = (navigator.language || "").toLowerCase().startsWith("zh") ? "zh" : "en";

export function defineStrings<K extends string>(dict: Record<Lang, Record<K, string>>) {
  return (key: K, vars?: Record<string, string | number>): string => {
    let s = dict[lang][key] ?? dict.en[key] ?? key;
    if (vars) for (const [k, v] of Object.entries(vars)) s = s.replace(`{${k}}`, String(v));
    return s;
  };
}

const ERRORS: Record<Lang, Record<string, string>> = {
  zh: {
    transport: "无法连接插件后端",
    internal: "内部错误,请查看日志",
    invalid_request: "请求参数无效",
    unknown_tool: "工具不存在",
    unknown_method: "后端不支持该操作,请更新插件",
    busy: "正在进行中,请稍候",
    not_found: "未找到目标资源",
    network: "网络连接失败,请检查网络或设置下载镜像",
    http_error: "服务器返回错误,请稍后重试",
    rate_limited: "GitHub 请求过于频繁,请稍后再试",
    disk_full: "磁盘空间不足",
    checksum_mismatch: "文件校验失败,请重新下载",
    extract_failed: "解压失败,文件可能已损坏",
    already_installed: "该版本已安装",
    cancelled: "已取消",
    unavailable: "组件不可用,请重新安装插件后重试",
  },
  en: {
    transport: "Cannot reach the plugin backend",
    internal: "Internal error, see logs",
    invalid_request: "Invalid request",
    unknown_tool: "Unknown tool",
    unknown_method: "Operation not supported, please update the plugin",
    busy: "Busy, please wait",
    not_found: "Resource not found",
    network: "Network error, check your connection or set a download mirror",
    http_error: "Server error, please retry later",
    rate_limited: "GitHub rate limit hit, please retry later",
    disk_full: "Not enough disk space",
    checksum_mismatch: "Checksum mismatch, please download again",
    extract_failed: "Extraction failed, the archive may be corrupted",
    already_installed: "This version is already installed",
    cancelled: "Cancelled",
    unavailable: "Component unavailable, please reinstall the plugin",
  },
};

/** 错误码 → 本地化文案;未知码给通用文案,不把原始错误透给用户。 */
export function errorText(code: string): string {
  return ERRORS[lang][code] ?? ERRORS[lang].internal;
}

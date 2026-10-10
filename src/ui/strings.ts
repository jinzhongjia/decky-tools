import { defineStrings } from "../core/i18n";

export const t = defineStrings({
  zh: {
    title: "工具箱",
    tools: "工具",
    back: "返回",
    settings: "设置",
    settingsDesc: "下载镜像等全局选项",
    mirror: "GitHub 下载镜像",
    mirrorDesc: "留空直连;填写加速前缀,如 https://example.com/ 。仅作用于 GitHub 发布文件下载",
    save: "保存",
    saved: "已保存",
    cancel: "取消",
    unavailable: "界面出错了",
    stage_download: "下载中",
    stage_verify: "校验中",
    stage_extract: "解压中",
    queued: "排队中",
  },
  en: {
    title: "Toolbox",
    tools: "Tools",
    back: "Back",
    settings: "Settings",
    settingsDesc: "Global options such as download mirror",
    mirror: "GitHub download mirror",
    mirrorDesc:
      "Leave empty for direct downloads, or enter a proxy prefix like https://example.com/. Only applies to GitHub release files",
    save: "Save",
    saved: "Saved",
    cancel: "Cancel",
    unavailable: "Something went wrong",
    stage_download: "Downloading",
    stage_verify: "Verifying",
    stage_extract: "Extracting",
    queued: "Queued",
  },
});

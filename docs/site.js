"use strict";

const chinese = {
  headline: "你的 Agent 会话，",
  headlineAccent: "就在刘海上。",
  summary: "一眼看清 Codex、Claude Code 和 Pi 哪条在跑、哪条已完成。",
  download: "下载 macOS 版",
  pending: "首个公开版本发布后开放下载",
  requirements: "macOS 15+ · Apple 芯片与 Intel",
  localRequirements: "本地体验版 · macOS 15+",
  previewRequirements: "v1.7.1 公开预览版 · Codex · macOS 15+",
  sourceBuild: "Claude Code 和 Pi 可从源码构建 1.8 体验",
  search: "搜索会话",
  instances: "全部实例",
  atlasTitle: "构建搜索索引",
  fieldTitle: "完善版本说明",
  working: "运行中",
  ready: "✓ 待查看",
  demoCaption: "用两条示例会话试试刘海。",
  collapse: "收起面板",
  expand: "展开面板",
  finish: "完成一条回复",
  restart: "重新运行",
  featureStatus: "一眼看到完成状态",
  detailStatus: "Agent 运行时动物会动。回复完成后亮起绿勾，等你通过 ZooCove 打开。",
  featureJump: "找到对应的会话",
  detailJump: "自动识别 Cockpit 管理的 Codex 和 Claude Code 实例，也可以手动添加本机目录。",
  featurePet: "给每条会话一张脸",
  detailPet: "从 16 只涂鸦动物里挑一个，也可以换成自己的项目图标。",
  footer: "原生 macOS 应用 · 读取本机的会话数据",
  releases: "版本发布 ↗",
};

const english = {
  localRequirements: "Local preview build · macOS 15+",
  previewRequirements: "v1.7.1 public preview · Codex · macOS 15+",
  expand: "Expand panel",
  restart: "Run again",
};
for (const element of document.querySelectorAll("[data-copy]")) {
  english[element.dataset.copy] = element.textContent;
}

const isChinese = new URLSearchParams(location.search).get("lang") === "zh";
const copy = isChinese ? chinese : english;
if (isChinese) {
  document.documentElement.lang = "zh-CN";
  const language = document.querySelector("#language");
  language.textContent = "English";
  language.href = "?lang=en";
  language.lang = "en";
}

for (const element of document.querySelectorAll("[data-copy]")) {
  element.textContent = copy[element.dataset.copy];
}

const island = document.querySelector("#island");
const notch = document.querySelector("#toggle-panel");
const panelAction = document.querySelector("#panel-action");
const panel = document.querySelector("#demo-panel");
let expanded = true;

function togglePanel() {
  expanded = !expanded;
  island.toggleAttribute("data-open", expanded);
  for (const button of [notch, panelAction]) button.setAttribute("aria-expanded", expanded);
  panel.setAttribute("aria-hidden", !expanded);
  panelAction.textContent = expanded ? copy.collapse : copy.expand;
  notch.setAttribute("aria-label", panelAction.textContent);
}
notch.setAttribute("aria-label", copy.collapse);
notch.addEventListener("click", togglePanel);
panelAction.addEventListener("click", togglePanel);

const pet = document.querySelector("[data-pet]");
const status = document.querySelector("#demo-status");
const finishAction = document.querySelector("#finish-action");
let finished = false;

finishAction.addEventListener("click", () => {
  finished = !finished;
  pet.classList.toggle("working", !finished);
  pet.classList.toggle("ready", finished);
  status.classList.toggle("finished", finished);
  status.textContent = finished ? copy.ready : copy.working;
  finishAction.textContent = finished ? copy.restart : copy.finish;
});

const repositoryPattern = /^[\w.-]+\/[\w.-]+$/;
const explicitRepository = document.querySelector('meta[name="zoocove-repository"]').content.trim();
const pages = /^([\w-]+)\.github\.io$/i.exec(location.hostname);
const firstPathPart = location.pathname.split("/")[1];
const pagesRepository = pages && firstPathPart ? `${pages[1]}/${firstPathPart}` : "";
const repository = explicitRepository || pagesRepository;
const localDMG = document.querySelector('meta[name="zoocove-local-dmg"]')?.content;
const localHost = ["localhost", "127.0.0.1", "[::1]"].includes(location.hostname);
const download = document.querySelector("#download");

function setLink(id, href) {
  const link = document.getElementById(id);
  link.href = href;
  link.hidden = false;
}

if (repositoryPattern.test(repository)) {
  const source = `https://github.com/${repository}`;
  const previewTag = document.querySelector('meta[name="zoocove-preview-tag"]')?.content.trim();
  const preview = /^v\d+\.\d+\.\d+$/.test(previewTag ?? "");
  const asset = preview ? `download/${previewTag}` : "latest/download";
  setLink("source", source);
  setLink("release-notes", `${source}/releases`);
  setLink("download", `${source}/releases/${asset}/ZooCove.dmg`);
  if (previewTag === "v1.7.1") {
    document.querySelector("#requirements").textContent = copy.previewRequirements;
    setLink("source-build", isChinese
      ? `${source}/blob/main/README.zh-CN.md#从源码构建`
      : `${source}#build-from-source`);
    document.querySelector("#source-build-note").hidden = false;
  }
} else if (localHost && localDMG && /^[\w.-]+\.dmg$/.test(localDMG)) {
  setLink("download", `./${localDMG}`);
  download.download = localDMG;
  document.querySelector("#requirements").textContent = copy.localRequirements;
}
document.querySelector("#release-pending").hidden = !download.hidden;

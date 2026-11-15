"use strict";

const chinese = {
  headline: "你的 Agent 会话，",
  headlineAccent: "就在刘海上。",
  summary: "同时开着 Codex、Claude Code 和 Pi 的多个会话，一排动物就能看清谁在跑、谁已完成。",
  download: "下载 macOS 版",
  pending: "首个公开版本发布后开放下载",
  requirements: "macOS 15+ · Apple 芯片与 Intel",
  localRequirements: "本地体验版 · macOS 15+",
  previewRequirements: "v1.7.1 公开预览版 · Codex · macOS 15+",
  sourceBuild: "Claude Code 和 Pi 可从源码构建 1.8 体验",
  search: "搜索会话",
  instances: "全部实例",
  working: "运行中",
  ready: "✓ 待查看",
  defaultProfile: "默认实例",
  demoSummary: (working, ready) => `8 条演示 · 3 个 Agent · ${working} 条运行 · ${ready} 条待看`,
  collapse: "收起面板",
  expand: "展开面板",
  finish: "完成选中会话",
  restart: "重新运行选中会话",
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
  defaultProfile: "Default profile",
  working: "Working",
  ready: "✓ Ready",
  demoSummary: (working, ready) => `8 example chats across 3 agents · ${working} working · ${ready} ready`,
  expand: "Expand panel",
  restart: "Run selected chat again",
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
const chatList = document.querySelector("#demo-chats");
const caption = document.querySelector("#demo-caption");
const finishAction = document.querySelector("#finish-action");
let expanded = true;
let selected;

function showPanel(open) {
  expanded = open;
  island.toggleAttribute("data-open", expanded);
  for (const button of [notch, panelAction]) button.setAttribute("aria-expanded", expanded);
  panel.setAttribute("aria-hidden", !expanded);
  panel.inert = !expanded;
  panelAction.textContent = expanded ? copy.collapse : copy.expand;
  notch.setAttribute("aria-label", panelAction.textContent);
}
notch.addEventListener("click", () => showPanel(!expanded));
panelAction.addEventListener("click", () => showPanel(!expanded));
notch.setAttribute("aria-label", copy.collapse);

const examples = [
  { project: "atlas", agent: "Claude Code", cockpit: true, animal: "platypus",
    title: "Build the search index", zh: "构建搜索索引", pace: 2.4 },
  { project: "billing", agent: "Codex", animal: "capybara",
    title: "Check invoice edge cases", zh: "检查账单边界情况", pace: 3.1 },
  { project: "docs", agent: "Pi Agent", animal: "mallard", ready: true,
    title: "Polish the release notes", zh: "完善版本说明", pace: 2.8 },
  { project: "web", agent: "Claude Code", animal: "bee",
    title: "Fix the mobile layout", zh: "修复移动端布局", pace: 1.8 },
  { project: "api", agent: "Codex", cockpit: true, animal: "octopus",
    title: "Trace the slow request", zh: "追踪慢请求", pace: 2.6 },
  { project: "ci", agent: "Pi Agent", animal: "frog",
    title: "Investigate a flaky build", zh: "排查不稳定的构建", pace: 2.35 },
  { project: "ship", agent: "Claude Code", cockpit: true, animal: "otter", ready: true,
    title: "Review the release checklist", zh: "检查发版清单", pace: 2.65 },
  { project: "tests", agent: "Codex", animal: "red-panda",
    title: "Add regression coverage", zh: "补齐回归测试", pace: 2.9 },
];

function updateStatus(chat) {
  const status = chat.ready ? copy.ready : copy.working;
  chat.slot.classList.toggle("working", !chat.ready);
  chat.slot.classList.toggle("ready", Boolean(chat.ready));
  chat.slot.setAttribute("aria-label", [chat.project, chat.profile, status].join(" · "));
  chat.status.classList.toggle("finished", Boolean(chat.ready));
  chat.status.textContent = status;
}

function setSelection(chat, reveal = true) {
  for (const item of [selected, chat]) {
    if (!item) continue;
    const active = item === chat;
    item.slot.setAttribute("aria-pressed", active);
    item.row.setAttribute("aria-pressed", active);
  }
  selected = chat;
  finishAction.textContent = chat.ready ? copy.restart : copy.finish;
  if (!reveal) return;
  showPanel(true);
  const top = chat.row.offsetTop;
  const bottom = top + chat.row.offsetHeight;
  if (top < chatList.scrollTop) chatList.scrollTop = top;
  if (bottom > chatList.scrollTop + chatList.clientHeight) chatList.scrollTop = bottom - chatList.clientHeight;
}

function updateCaption() {
  const ready = chats.filter(chat => chat.ready).length;
  caption.textContent = copy.demoSummary(chats.length - ready, ready);
}

const strip = notch.parentElement;
const slotTemplate = document.querySelector("#demo-slot");
const chatTemplate = document.querySelector("#demo-chat");
const chats = examples.map((example, index) => {
  const slot = slotTemplate.content.firstElementChild.cloneNode(true);
  const row = chatTemplate.content.firstElementChild.cloneNode(true);
  const status = row.querySelector(".status");
  const profile = `${example.agent} · ${example.cockpit ? "Cockpit" : copy.defaultProfile}`;
  const chat = { ...example, slot, row, status, profile };
  for (const image of [slot.querySelector("img"), row.querySelector("img")]) {
    image.src = `assets/${example.animal}.png`;
  }
  slot.style.setProperty("--pace", `${example.pace}s`);
  slot.style.setProperty("--phase", `${-example.pace * (index % 5) / 5}s`);
  slot.classList.toggle("hovering", example.animal === "bee");
  slot.querySelector(".project").textContent = example.project;
  row.querySelector("strong").textContent = isChinese ? example.zh : example.title;
  row.querySelector("small").textContent = profile;
  slot.title = profile;
  if (index < 4) strip.insertBefore(slot, notch);
  else strip.append(slot);
  chatList.append(row);
  updateStatus(chat);
  slot.addEventListener("click", () => setSelection(chat));
  row.addEventListener("click", () => setSelection(chat, false));
  return chat;
});
setSelection(chats[0], false);
updateCaption();

finishAction.addEventListener("click", () => {
  selected.ready = !selected.ready;
  updateStatus(selected);
  setSelection(selected, false);
  updateCaption();
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

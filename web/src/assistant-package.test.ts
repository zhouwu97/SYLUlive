import { describe, expect, it } from "vitest";
import {
  assistantAvailability,
  buildInstallSteps,
  channelForHostname,
  extensionsPageForUserAgent,
  formatBytes,
  parseAssistantPackage,
  shortHash,
  type AssistantPackage,
} from "./assistant-package";

const hash = "a".repeat(64);
const developmentPackage: AssistantPackage = {
  channel: "development",
  extensionVersion: "0.1.0",
  fileName: "sylulive-assistant.zip",
  bytes: 346428,
  sha256: hash,
  builtAt: "2026-09-29T07:34:55.346Z",
  sites: [
    "https://sylulive.online/*",
    "http://localhost:5173/*",
    "http://127.0.0.1:5173/*",
  ],
};
const productionPackage: AssistantPackage = { ...developmentPackage, channel: "production", sites: ["https://sylulive.online/*"] };

describe("parseAssistantPackage", () => {
  it("接受合法清单并保留下载所需字段", () => {
    expect(parseAssistantPackage(developmentPackage)).toEqual(developmentPackage);
  });
  it.each([
    ["非对象", null],
    ["未知通道", { ...developmentPackage, channel: "staging" }],
    ["版本号形状不符", { ...developmentPackage, extensionVersion: "v1" }],
    ["文件名含路径穿越", { ...developmentPackage, fileName: "../secret.zip" }],
    ["文件名带路径分隔符", { ...developmentPackage, fileName: "a/b.zip" }],
    ["校验值不是十六进制", { ...developmentPackage, sha256: "z".repeat(64) }],
    ["校验值长度不符", { ...developmentPackage, sha256: hash.slice(0, 63) }],
    ["大小不是有限正数", { ...developmentPackage, bytes: -1 }],
    ["大小超出上限", { ...developmentPackage, bytes: 21 * 1024 * 1024 }],
    ["构建时间无法解析", { ...developmentPackage, builtAt: "昨天" }],
    ["授权站点不是数组", { ...developmentPackage, sites: "https://sylulive.online/*" }],
  ])("拒绝 %s", (_label, value) => {
    expect(parseAssistantPackage(value)).toBeNull();
  });
});

describe("assistantAvailability", () => {
  it("开发包配本地站点、生产包配线上站点都可用", () => {
    expect(assistantAvailability(parseAssistantPackage(developmentPackage), { origin: "http://127.0.0.1:5173" })).toBe("ok");
    expect(assistantAvailability(parseAssistantPackage(productionPackage), { origin: "https://sylulive.online" })).toBe("ok");
  });
  it("生产包配本地站点时先判定本站未被授权", () => {
    expect(assistantAvailability(productionPackage, { origin: "http://127.0.0.1:5173" })).toBe("host-not-covered");
  });
  it("开发包发到线上域名时判定通道不符", () => {
    expect(assistantAvailability(developmentPackage, { origin: "https://sylulive.online" })).toBe("wrong-channel");
  });
  it("协议不符或清单缺失、来源异常时不可用", () => {
    expect(assistantAvailability(developmentPackage, { origin: "https://localhost:5173" })).toBe("host-not-covered");
    expect(assistantAvailability(null, { origin: "http://127.0.0.1:5173" })).toBe("unavailable");
    expect(assistantAvailability(developmentPackage, { origin: "不是地址" })).toBe("unavailable");
  });
  it("授权站点里的其他条目不会误判为本站可用", () => {
    expect(assistantAvailability({ ...productionPackage, sites: ["https://other.example/*"] }, { origin: "https://sylulive.online" })).toBe("host-not-covered");
  });
});

describe("安装引导文案", () => {
  it("Edge 的 UA 同时包含 Chrome，必须先匹配 Edg", () => {
    const edge = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0";
    expect(extensionsPageForUserAgent(edge)).toBe("edge://extensions");
    expect(extensionsPageForUserAgent("Mozilla/5.0 (Windows NT 10.0) Chrome/140.0.0.0 Safari/537.36")).toBe("chrome://extensions");
  });
  it("六个步骤覆盖下载、解压、扩展页、开发者模式、装载和复检", () => {
    const steps = buildInstallSteps("edge://extensions");
    expect(steps).toHaveLength(6);
    expect(steps.join("\n")).toContain("edge://extensions");
    expect(steps[1]).toContain("不要移动");
    expect(steps[5]).toContain("重新检测");
    expect(steps[5]).toContain("不必刷新");
  });
  it("本机地址属于开发通道", () => {
    expect(channelForHostname("127.0.0.1")).toBe("development");
    expect(channelForHostname("localhost")).toBe("development");
    expect(channelForHostname("sylulive.online")).toBe("production");
  });
  it("体积和校验值按可读形式展示", () => {
    expect(formatBytes(512)).toBe("512 B");
    expect(formatBytes(346428)).toBe("338 KB");
    expect(formatBytes(3 * 1024 * 1024)).toBe("3.0 MB");
    expect(shortHash(hash)).toBe(`${"a".repeat(8)}…${"a".repeat(8)}`);
  });
});

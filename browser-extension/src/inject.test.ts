import { describe, expect, it } from "vitest";
import { planRelayInjection } from "./inject";

const productionHosts = ["https://sylulive.online/*"];
const developmentHosts = [
  "https://sylulive.online/*",
  "http://localhost:5173/*",
  "http://127.0.0.1:5173/*",
];

describe("planRelayInjection", () => {
  it("只保留 http(s) 站点匹配模式并去重", () => {
    expect(
      planRelayInjection([
        "https://sylulive.online/*",
        "https://sylulive.online/*",
        "chrome-extension://abc/*",
        "<all_urls>",
      ]),
    ).toEqual(["https://sylulive.online/*"]);
  });
  it("开发通道补注入本地站点，生产通道不会在本地注入任何东西", () => {
    expect(planRelayInjection(developmentHosts)).toContain("http://127.0.0.1:5173/*");
    expect(planRelayInjection(productionHosts)).toEqual(["https://sylulive.online/*"]);
    expect(planRelayInjection(productionHosts)).not.toContain("http://localhost:5173/*");
  });
  it("缺少 host_permissions 时不注入", () => {
    expect(planRelayInjection()).toEqual([]);
    expect(planRelayInjection([])).toEqual([]);
  });
});

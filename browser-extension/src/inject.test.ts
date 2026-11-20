import { afterEach, describe, expect, it, vi } from "vitest";
import { installSelfHealingInjection, planRelayInjection } from "./inject";

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

describe('self-healing relay lifecycle', () => {
  afterEach(() => vi.unstubAllGlobals());
  it('injects on worker start and browser startup without adding school host access', async () => {
    const installed = vi.fn(), startup = vi.fn();
    const executeScript = vi.fn().mockResolvedValue(undefined);
    const query = vi.fn().mockResolvedValue([{id: 17}, {}]);
    vi.stubGlobal('chrome', {
      runtime: {getManifest: () => ({host_permissions: productionHosts}), onInstalled: {addListener: installed}, onStartup: {addListener: startup}},
      tabs: {query}, scripting: {executeScript},
    });
    installSelfHealingInjection();
    await vi.waitFor(() => expect(executeScript).toHaveBeenCalledTimes(1));
    expect(query).toHaveBeenCalledWith({url: productionHosts[0]});
    expect(executeScript).toHaveBeenCalledWith({target: {tabId: 17, frameIds: [0]}, files: ['relay.js']});
    await Promise.resolve();
    startup.mock.calls[0][0]();
    await vi.waitFor(() => expect(executeScript).toHaveBeenCalledTimes(2));
  });
  it('coalesces simultaneous initialization/install events and tolerates inaccessible tabs', async () => {
    const installed = vi.fn();
    let resolve!: (value: unknown[]) => void;
    const pending = new Promise<unknown[]>(done => { resolve = done; });
    const query = vi.fn().mockReturnValue(pending);
    const executeScript = vi.fn().mockRejectedValue(new Error('tab closed'));
    vi.stubGlobal('chrome', {
      runtime: {getManifest: () => ({host_permissions: productionHosts}), onInstalled: {addListener: installed}, onStartup: {addListener: vi.fn()}},
      tabs: {query}, scripting: {executeScript},
    });
    installSelfHealingInjection();
    installed.mock.calls[0][0]({reason: 'install'});
    expect(query).toHaveBeenCalledTimes(1);
    resolve([{id: 17}]);
    await vi.waitFor(() => expect(executeScript).toHaveBeenCalledTimes(1));
  });
});

import { describe, expect, it } from "vitest";
import { pickHelloConnections } from "./hello";

const site = "https://sylulive.online";
const other = "https://evil.example";
const connection = {
  appUserId: 7,
  provider: "undergraduate",
  studentId: "2403000001",
  displayName: "张三",
  state: "connected",
  epoch: "epoch-1",
  connectedAt: "2026-09-29T01:00:00.000Z",
  origin: site,
  confirmed: true,
};

describe("pickHelloConnections", () => {
  it("provider 从存储键反解，内部字段不外泄", () => {
    const [item] = pickHelloConnections(
      { [`connection:${site}:undergraduate`]: connection },
      site,
    );
    expect(item).toEqual({
      provider: "undergraduate",
      studentId: "2403000001",
      displayName: "张三",
      epoch: "epoch-1",
      state: "connected",
    });
    expect(JSON.stringify(item)).not.toMatch(/appUserId|confirmed|origin/);
  });
  it("其他站点的连接一条都不返回", () => {
    const stored = {
      [`connection:${site}:undergraduate`]: connection,
      [`connection:${other}:graduate`]: { ...connection, provider: "graduate" },
      [`cache:${site}:undergraduate:epoch-1`]: { studentId: "2403000001" },
    };
    expect(pickHelloConnections(stored, site)).toHaveLength(1);
    expect(pickHelloConnections(stored, site)[0].provider).toBe("undergraduate");
    expect(pickHelloConnections({}, site)).toEqual([]);
  });
  it("未知 provider 与缺字段的半截记录直接跳过", () => {
    const stored = {
      [`connection:${site}:mysql`]: connection,
      [`connection:${site}:graduate`]: { ...connection, studentId: undefined },
      [`connection:${site}:physical`]: null,
      [`connection:${site}:erke`]: { ...connection, provider: "erke", epoch: undefined },
    };
    expect(pickHelloConnections(stored, site)).toEqual([]);
  });
  it("过期连接保留 expired，缺省状态按已连接处理", () => {
    const stored = {
      [`connection:${site}:graduate`]: { ...connection, provider: "graduate", state: "expired" },
      [`connection:${site}:physical`]: { ...connection, provider: "physical", state: undefined },
    };
    const result = pickHelloConnections(stored, site);
    expect(result.find((x) => x.provider === "graduate")?.state).toBe("expired");
    expect(result.find((x) => x.provider === "physical")?.state).toBe("connected");
  });
});

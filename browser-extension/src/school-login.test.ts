import { expect, it } from "vitest";
import { loginStage } from "./school-assistant";
import { vpnPath } from "./school";
it("仅适配本科、学校 CAS 与二课的固定登录页", () => {
  expect(loginStage("undergraduate", "https://jxw.sylu.edu.cn/xtgl/login_slogin.html")).toBe("undergraduate");
  expect(loginStage("erke", "https://webvpn.sylu.edu.cn" + vpnPath("/SyluTW/Sys/UserLogin.aspx"))).toBe("erke");
  expect(loginStage("erke", "https://webvpn.sylu.edu.cn" + vpnPath("/authserver/login", "authserver.sylu.edu.cn", "https"))).toBe("vpn");
  for (const url of ["https://other.example/authserver/login", "https://jxw.sylu.edu.cn.evil.example/xtgl/login_slogin.html", "https://webvpn.sylu.edu.cn" + vpnPath("/authserver/login", "other.example"), "https://webvpn.sylu.edu.cn/http/unknown/SyluTW/Sys/UserLogin.aspx"])
    expect(loginStage("erke", url)).toBeUndefined();
});

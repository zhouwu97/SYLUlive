import CryptoJS from "crypto-js";
import type {
  AcademicProvider,
  AcademicDataset,
  AcademicTerm,
  Course,
} from "@sylulive/academic-contracts";
import {
  courses,
  grades,
  graduateDecode,
  graduateProfile,
  profile,
  ranges,
  schoolDocument,
  tableData,
  creditRequirements,
} from "./parsers";
export const origins: Record<AcademicProvider, string> = {
  undergraduate: "https://jxw.sylu.edu.cn",
  graduate: "https://yjsgl.sylu.edu.cn",
  erke: "https://webvpn.sylu.edu.cn",
  physical: "http://47.92.231.221",
};
export const entrances: Record<AcademicProvider, string> = {
  undergraduate: origins.undergraduate + "/xtgl/login_slogin.html",
  graduate: origins.graduate + "/home/stulogin",
  erke: origins.erke,
  physical: origins.physical,
};
const physicalProviderOptInKey = "physicalProviderEnabled";

// 体测服务仍是 HTTP 明文协议，默认不启用；开关只保存在扩展本机，不上传业务服务器。
export async function isPhysicalProviderEnabled() {
  const value = await chrome.storage.local.get(physicalProviderOptInKey);
  return value[physicalProviderOptInKey] === true;
}

export async function setPhysicalProviderEnabled(enabled: boolean) {
  if (enabled) {
    await chrome.storage.local.set({ [physicalProviderOptInKey]: true });
    return;
  }
  await chrome.storage.local.remove(physicalProviderOptInKey);
  await chrome.storage.session.remove("physicalLogin");
  // 用户可能尚未授予 cookies 权限；清理失败不应阻止关闭本机开关。
  await chrome.cookies.remove({ url: origins.physical, name: "userid" }).catch(() => undefined);
}

async function requirePhysicalProviderOptIn(provider: AcademicProvider) {
  if (provider === "physical" && !(await isPhysicalProviderEnabled()))
    throw new Error("体测连接默认关闭；请在助手页阅读风险并手动开启");
}
const knownPaths = [
  "/xsxxxggl/",
  "/kbcx/",
  "/cjcx/",
  "/xjyj/",
  "/xsxy/",
  "/student/",
  "/service/",
  "/http/",
];
export async function schoolRequest(
  provider: AcademicProvider,
  path: string,
  body?: Record<string, string>,
  signal?: AbortSignal,
  json = false,
  headers: Record<string, string> = {},
): Promise<string> {
  if (
    !path.startsWith("/") ||
    path.startsWith("//") ||
    !knownPaths.some((p) => path.startsWith(p))
  )
    throw new Error("学校请求目标无效");
  let prefix = "";
  const tabs = await chrome.tabs.query({ url: origins[provider] + "/*" });
  const tab = tabs.find((t) => t.active) || tabs[0];
  if (provider === "graduate" && tab?.url)
    prefix = new URL(tab.url).pathname.match(/^\/\(S\([^)]+\)\)/i)?.[0] || "";
  const url = origins[provider] + prefix + path;
  const init: RequestInit = {
    method: body ? "POST" : "GET",
    credentials: "include",
    signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(18000)]) : AbortSignal.timeout(18000),
    headers: {
      ...(body
        ? {
            "Content-Type": json
              ? "application/json"
              : "application/x-www-form-urlencoded",
          }
        : {}),
      ...headers,
    },
    body: body
      ? json
        ? JSON.stringify(body)
        : new URLSearchParams(body)
      : undefined,
  };
  const response = await fetch(url, init);
  if (!response.ok || response.status === 901)
    throw new Error(`学校请求失败（${response.status}），请检查登录状态`);
  if (new URL(response.url).origin !== origins[provider])
    throw new Error("学校跳转到其他登录系统，请在官网完成登录");
  const buffer = await response.arrayBuffer();
  const contentType = response.headers.get("content-type") || "";
  return new TextDecoder(
    provider === "erke" && !/utf-8/i.test(contentType) ? "gbk" : "utf-8",
  ).decode(buffer);
}
function vpnPath(path: string) {
  const key = CryptoJS.enc.Utf8.parse("wrdvpnisthebest!");
  const encrypted = CryptoJS.AES.encrypt("xg.sylu.edu.cn", key, {
    iv: key,
    mode: CryptoJS.mode.CFB,
    padding: CryptoJS.pad.NoPadding,
  }).ciphertext.toString();
  return "/http/" + key.toString() + encrypted + path;
}
export async function identity(
  provider: AcademicProvider,
  signal?: AbortSignal,
): Promise<{ studentId: string; displayName: string }> {
  await requirePhysicalProviderOptIn(provider);
  if (provider === "undergraduate")
    return profile(
      await schoolRequest(
        provider,
        "/xsxxxggl/xsgrxxwh_cxXsgrxx.html?gnmkdm=N100801&layout=default",
        undefined,
        signal,
      ),
    );
  if (provider === "graduate")
    return graduateProfile(
      await schoolRequest(
        provider,
        "/student/default/getxscardinfo",
        undefined,
        signal,
      ),
    );
  if (provider === "physical") {
    const v = (await chrome.storage.session.get("physicalLogin"))
      .physicalLogin as { userId?: string; account?: string; token?: string } | undefined;
    if (!v?.userId || !v.token) throw new Error("请在助手中登录体测系统");
    const cookie = await chrome.cookies.get({url:origins.physical,name:'userid'});
    if(cookie?.value !== v.userId) throw new Error('体测登录身份已变化，请重新连接');
    const form:Record<string,string>={userId:v.userId};form.sign=sign(form);
    const value=JSON.parse(await schoolRequest(provider,'/service/sysUser/mobile/findStudent',form,signal,true,{Authorization:v.token,'X-Requested-With':'com.wisedu.cpdaily'}));
    if(!value.data || typeof value.data !== 'object')throw new Error('体测会话已过期，请重新登录');
    return { studentId: v.userId, displayName: v.account || "" };
  }
  const html = await schoolRequest(
    provider,
    vpnPath("/SyluTW/Sys/SystemForm/FinishExam/StuFinishStudentScore.aspx"),
    undefined,
    signal,
  );
  const d = schoolDocument(html);
  const text = d.body?.textContent || "";
  const m = text.match(/学号\s*[：:]?\s*(\d{8,20})/);
  if (!m)
    throw new Error("二课身份未确认，请在 WebVPN 中进入二课系统并完成登录");
  return { studentId: m[1], displayName: "" };
}
export async function fetchDataset(
  provider: AcademicProvider,
  dataset: AcademicDataset,
  term: AcademicTerm,
  signal: AbortSignal,
) {
  await requirePhysicalProviderOptIn(provider);
  if (provider === "undergraduate") {
    if (
      !/^\d{4}$/.test(term.year) ||
      !["3", "12", "16"].includes(term.semester)
    )
      throw new Error("学期参数无效");
    const form = { xnm: term.year, xqm: term.semester };
    if (dataset === "courses") {
      const text = await schoolRequest(
        provider,
        "/kbcx/xskbcx_cxXsKb.html",
        { ...form, kblx: "1" },
        signal,
      );
      return courses(JSON.parse(text));
    }
    if (dataset === "grades") {
      await schoolRequest(
        provider,
        "/cjcx/cjcx_cxDgXscj.html?gnmkdm=N305005&layout=default",
        undefined,
        signal,
      );
      const result = [];
      for (let page = 1; page <= 20; page++) {
        const text = await schoolRequest(
          provider,
          "/cjcx/cjcx_cxXsgrcj.html?doType=query&gnmkdm=N305005",
          {
            ...form,
            "queryModel.showCount": "500",
            "queryModel.currentPage": String(page),
          },
          signal,
        );
        const batch = grades(JSON.parse(text));
        result.push(...batch);
        if (batch.length < 500) return result;
      }
      throw new Error("成绩分页超出限制，本次结果未替换已有资料");
    }
    if (dataset === "situation")
      return tableData(
        await schoolRequest(
          provider,
          "/xsxy/xsxyqk_cxXsxyqkIndex.html?gnmkdm=N105515&layout=default",
          undefined,
          signal,
        ),
      );
    if (dataset === "requirements") {
      const html=await schoolRequest(
          provider,
          "/xjyj/xjyj_cxXjyjIndex.html?gnmkdm=N105505&layout=default",
          undefined,
          signal,
        );
      const document=schoolDocument(html),params:Record<string,string>={};
      for(const key of ['jg_id','njdm_id','zyh_id']){
        const value=document.querySelector(`select#${key} option[selected],select[name="${key}"] option[selected]`)?.getAttribute('value')?.trim();
        if(value)params[key]=value;
      }
      if(Object.keys(params).length!==3)return tableData(html);
      const detail=await schoolRequest(provider,'/xjyj/xjyj_cxXjyjjdlb.html?gnmkdm=N105505',params,signal,false,{'X-Requested-With':'XMLHttpRequest'});
      if(detail.trim().startsWith('<'))return tableData(detail);
      return creditRequirements(JSON.parse(detail));
    }
  }
  if (provider === "graduate" && dataset === "courses") {
    const terms = graduateDecode(
      await schoolRequest(
        provider,
        "/student/default/bindterm",
        undefined,
        signal,
      ),
    );
    if (!Array.isArray(terms)) throw new Error("研究生学期列表无法解析");
    const selected =
      terms.find((t) => String(t.termcode) === term.providerTermId) ||
      terms.find((t) => t.selected === true || t.selected === "true") ||
      terms[0];
    if (!selected?.termcode) throw new Error("请选择有效的研究生学期");
    const parsed = graduateDecode(
      await schoolRequest(
        provider,
        "/student/pygl/py_kbcx_ew",
        { kblx: "xs", termcode: String(selected.termcode) },
        signal,
      ),
    );
    if (!Array.isArray(parsed?.rows)) throw new Error("研究生课表格式已变化");
    const result: Course[] = [];
    parsed.rows.forEach((row: Record<string, string>, ri: number) => {
      for (let day = 1; day <= 7; day++) {
        const text =
          schoolDocument(
            String(row["z" + day] || "").replace(/<br\s*\/?>/gi, "\n"),
          ).textContent || "";
        for (const line of text
          .split("\n")
          .map((x) => x.trim())
          .filter(Boolean)) {
          const m = line.match(
            /^(.+?)\s*\[([^\]]+)\]\s*(.+?)\s*\[([^\]]+)\]\s*$/,
          );
          const periods = ranges(String(row.mc || row.jcid || ""), 20),
            weeks = m ? ranges(m[2], 60) : [];
          if (!m || !periods.length || !weeks.length)
            throw new Error("研究生课程时间无法解析，原资料已保留");
          result.push({
            id: `graduate:${m[1].trim()}:${m[3].trim()}:${day}:${periods.join('-')}`,
            name: m[1].trim(),
            teacher: m[3].trim(),
            room: m[4].trim(),
            day,
            periods,
            weeks,
          });
        }
      }
    });
    return result;
  }
  if (provider === "erke" && dataset === "erke") {
    const d = schoolDocument(
      await schoolRequest(
        provider,
        vpnPath("/SyluTW/Sys/SystemForm/FinishExam/StuFinishStudentScore.aspx"),
        undefined,
        signal,
      ),
    );
    const number = (id: string) => {
      const el = d.getElementById(id) || d.querySelector(`[id$="${id}"]`);
      if (!el) throw new Error("二课资料格式已变化");
      const n = Number(el.textContent?.trim() || 0);
      if (!Number.isFinite(n)) throw new Error("二课分数无法解析");
      return n;
    };
    return {
      required: number("SunCount"),
      earned: number("SunCount1"),
      categories: ["A", "B", "C", "D", "E"].map((c, i) => ({
        name: [
          "思想成长",
          "实践实习",
          "创新创业",
          "志愿公益",
          "文体活动和技能特长",
        ][i],
        required: number("Count" + c),
        earned: number("Count" + c + "1"),
      })),
    };
  }
  if (provider === "physical" && dataset === "physical") {
    const login = (await chrome.storage.session.get("physicalLogin"))
      .physicalLogin as
      { userId: string; token: string; year?: string } | undefined;
    if (!login) throw new Error("请先在助手中登录体测");
    const form: Record<string, string> = {
      user_id: login.userId,
      school_year: term.year || login.year || "",
    };
    form.sign = sign(form);
    const body = JSON.parse(
      await schoolRequest(
        provider,
        "/service/mobile/gymResult/selectUserPlanScore",
        form,
        signal,
        true,
        {
          Authorization: login.token,
          "X-Requested-With": "com.wisedu.cpdaily",
        },
      ),
    );
    const data = body?.data?.data_arr;
    if (!Array.isArray(data)) throw new Error("体测会话已过期或返回格式改变");
    return {
      total_score: body.data.total_score,
      total_grade: body.data.total_grade,
      scores: data.map((x: Record<string, unknown>) => ({
        name: String(x.item_name || x.name || x.itemName || ""),
        score: String(x.score || x.item_score || ""),
        result: String(x.result || x.item_result || ""),
        grade: String(x.grade || ""),
      })),
    };
  }
  throw new Error("此系统不支持该项资料");
}
function sign(params: Record<string, string>) {
  return CryptoJS.SHA1(
    Object.keys(params)
      .filter((k) => k !== "sign" && params[k] !== "")
      .sort()
      .map((k) => `${k}=${params[k]}`)
      .join("&") + "&key=8d6c5b73a50d4707bd71c93882ddbc8b",
  )
    .toString()
    .toUpperCase();
}
export async function physicalLogin(account: string, password: string) {
  await requirePhysicalProviderOptIn("physical");
  const form = {
    username: account,
    password: CryptoJS.MD5(password).toString(),
    sys_id: "iscpMobile",
    nonceStr: "",
    captchaValue: "",
    sign: "",
  };
  form.sign = sign(form);
  const body = JSON.parse(
    await schoolRequest(
      "physical",
      "/service/login/mobile/check",
      form,
      undefined,
      true,
    ),
  );
  const data = body.data || body;
  const userId = String(
    data.user_id || data.userId || data.id || body.user_id || "",
  );
  const token = String(body.token || data.token || "");
  if (!userId || !token) throw new Error("体测登录未成功，请核对账号密码");
  await chrome.storage.session.set({
    physicalLogin: {
      userId,
      token,
      account,
      year: String(body.school_date || data.school_date || ""),
    },
  });
  await chrome.cookies.set({
    url: origins.physical,
    name: "userid",
    value: userId,
    path: "/",
  });
}

import { parseHTML } from "linkedom";
import CryptoJS from "crypto-js";
import type { Course, Grade } from "@sylulive/academic-contracts";
export function schoolDocument(html: string) {
  if (/<input[^>]+(?:name|id)=["'](?:mm|password)["']/i.test(html))
    throw new Error("学校登录已过期，请在学校官网重新登录");
  return parseHTML(html).document;
}
export function profile(html: string) {
  const d = schoolDocument(html);
  const field = (id: string) =>
    (d.getElementById(id)?.textContent || "").trim();
  const id = field("col_xh");
  const hidden = (
    d.getElementById("xh_id") as HTMLInputElement | null
  )?.getAttribute("value");
  const current = d.getElementById("curXh_id")?.getAttribute("value");
  if (!id || id !== hidden || id !== current)
    throw new Error("学校身份未能确认，请完成登录后重试");
  return { studentId: id, displayName: field("col_xm") };
}
export function ranges(expression: string, max: number): number[] {
  const result = new Set<number>();
  for (const part of expression.replace(/周|节/g, "").split(/[,，、;]/)) {
    const m = part.match(/(\d+)\s*(?:[-~至到—–]\s*(\d+))?/);
    if (!m) continue;
    const start = Number(m[1]),
      end = Number(m[2] || m[1]);
    if (start < 1 || end > max || end < start)
      throw new Error("学校课程时间格式不正确");
    for (let n = start; n <= end; n++) {
      if (
        (part.includes("单") && n % 2 === 0) ||
        (part.includes("双") && n % 2 === 1)
      )
        continue;
      result.add(n);
    }
  }
  return [...result].sort((a, b) => a - b);
}
export function courses(body: unknown): Course[] {
  const data = body as { kbList?: Record<string, unknown>[] };
  if (!Array.isArray(data?.kbList))
    throw new Error("课表结构已变化，原资料已保留");
  return data.kbList.map((c, index) => {
    const day = Number(c.xqj),
      periods = ranges(String(c.jc || ""), 20),
      weeks = ranges(String(c.zcd || ""), 60);
    if (
      !Number.isInteger(day) ||
      day < 1 ||
      day > 7 ||
      !periods.length ||
      !weeks.length
    )
      throw new Error("课表包含无法识别的时间");
    return {
      id: `school:${c.kch_id || c.kcmc}:${c.xm || ""}:${day}:${periods.join("-")}`,
      name: String(c.kcmc || ""),
      room: String(c.cdmc || ""),
      teacher: String(c.xm || ""),
      day,
      periods,
      weeks,
    };
  });
}
export function grades(body: unknown): Grade[] {
  const data = body as { items?: Record<string, unknown>[] };
  if (!Array.isArray(data?.items))
    throw new Error("成绩结构已变化，原资料已保留");
  return data.items.map((g, i) => ({
    id: String(g.jxb_id || g.kch_id || i),
    name: String(g.kcmc || ""),
    credit: Number(g.xf || 0),
    score: String(g.cj ?? ""),
    gpa:
      g.jd === undefined || g.jd === null || g.jd === "" ? null : Number(g.jd),
    nature: String(g.kcxzmc || ""),
    term: `${g.xnm || ""}-${g.xqm || ""}`,
  }));
}
export function tableData(html: string) {
  const d = schoolDocument(html);
  const tables = [...d.querySelectorAll("table")]
    .map((t) => ({
      headers: [...t.querySelectorAll("th")].map((x) =>
        (x.textContent || "").trim(),
      ),
      rows: [...t.querySelectorAll("tr")]
        .map((tr) =>
          [...tr.querySelectorAll("td")].map((x) =>
            (x.textContent || "").trim(),
          ),
        )
        .filter((r) => r.length),
    }))
    .filter((t) => t.rows.length);
  if (!tables.length) throw new Error("学校未返回可识别的数据表");
  return { tables };
}
export function graduateDecode(raw: string): any {
  let direct: unknown;
  try {
    direct = JSON.parse(raw);
  } catch {}
  if (direct && typeof direct === "object") return direct;
  const text = typeof direct === "string" ? direct : raw.trim();
  try {
    const decoded = CryptoJS.AES.decrypt(
      text,
      CryptoJS.enc.Utf8.parse("southsoft12345!#"),
      { mode: CryptoJS.mode.ECB, padding: CryptoJS.pad.Pkcs7 },
    ).toString(CryptoJS.enc.Utf8);
    try {
      return JSON.parse(decoded);
    } catch {
      return decoded;
    }
  } catch {
    throw new Error("研究生系统响应无法解析");
  }
}
export function graduateProfile(raw: string) {
  const body = graduateDecode(raw);
  const data = Array.isArray(body) ? body[0] : body?.data || body;
  if (!data?.xh) throw new Error("研究生登录已过期或身份未确认");
  return {
    studentId: String(data.xh).trim(),
    displayName: String(data.xm || ""),
  };
}
export function creditRequirements(payload: unknown) {
  if(!Array.isArray(payload))throw new Error('学分要求数据结构已变化');
  type Row={id:string;name:string;credits:number;grade:string;status:string;term:string};
  type Module={name:string;required:number|null;requiredCount:number|null;earned:number;courses:Row[]};
  const modules:Module[]=[];
  const number=(v:unknown)=>v===null||v===undefined||v===''?null:Number.isFinite(Number(v))?Number(v):null;
  const visit=(node:Record<string,any>,parent?:Module)=>{
    if(!node||typeof node!=='object')return;
    const name=String(node.xfyqjdmc||'').trim();let next=parent;
    if(name){
      const courses:Row[]=(Array.isArray(node.kcList)?node.kcList:[]).map((c:Record<string,any>)=>({id:String(c.kch||''),name:String(c.kcmc||''),credits:number(c.xf)||0,grade:String(c.cj||''),status:c.cj==='未开放'?'未开放':String(c.tdbj)==='1'?'课程替代':(number(c.yxxf)||0)>0?'通过':number(c.bfzcj)!==null?(Number(c.bfzcj)>=60?'通过':'不及格'):c.xnmc||c.xqmc?'已选':'未选',term:`${c.xnmc||''} ${c.xqmc||''}`.trim()}));
      const module:Module={name,required:number(node.yqzdxf),requiredCount:number(node.kczdms),earned:(Array.isArray(node.kcList)?node.kcList:[]).reduce((sum:number,c:Record<string,any>)=>sum+(number(c.yxxf)||0),0),courses};
      if(/^至少修\d+(?:\.\d+)?(?:学分|门)(?:[（(][^）)]*[)）])?$/.test(name.replace(/\s/g,''))&&parent){
        for(const course of courses)if(!parent.courses.some(c=>c.id===course.id&&c.name===course.name&&c.term===course.term)){parent.courses.push(course);if(['通过','课程替代'].includes(course.status))parent.earned+=course.credits;}
      }else{modules.push(module);next=module;}
    }
    if(Array.isArray(node.xfyqjdList))node.xfyqjdList.forEach((child:Record<string,any>)=>visit(child,next));
  };
  payload.forEach(node=>visit(node));
  if(payload.length&&!modules.length)throw new Error('学分要求缺少模块，原资料已保留');
  return {modules:modules.map(m=>({...m,status:m.required===null&&m.requiredCount===null?'学校未提供要求':(m.required===null||m.earned>=m.required)&&(m.requiredCount===null||m.courses.filter(c=>['通过','课程替代'].includes(c.status)).length>=m.requiredCount)?'本地计算达标':'本地计算存在缺口'}))};
}

import { describe, expect, it } from "vitest";
import {
  TRANSFER_PROTOCOL,
  TransferError,
  createTransferKeys,
  decryptTransfer,
  fromBase64Url,
  parseTransferPayload,
  preferredSchedule,
  toBase64Url,
  transferQrText,
  transferSummary,
} from "./academic-transfer";

// 与 App 端 academic_transfer_crypto_test.dart 共用的固定向量：
// 任一端改动密钥派生、附加数据或编码，两边的测试都会失败。
const vector = {
  webPrivateD: "Hx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8",
  webX: "a_hdX-hFmLEMphmewJzNfTXc1xlf3R3Hc3oMZwBu8lE",
  webY: "uVLyXuwd7tH8oZGDiZBGY1fTFK37fpdguNmvyPOala0",
  appPublic: "BAObhS22IkCKvlihjA8FZjGmykss_uwZiq4lAXytCdTo4gi2FuDcV3Wl2EB3XTja_UZ22jQQAhXovoV77SukrDA",
  sessionId: "AAECAwQFBgcICQoLDA0ODw",
  nonce: "AAECAwQFBgcICQoL",
  plaintext:
    '{"version":1,"generatedAt":"2026-11-11T00:00:00.000Z","schedules":[{"id":"current","kind":"current","label":"测试课表","courses":[{"id":"c1","name":"高等数学","teacher":"张老师","room":"A101","day":1,"periods":[1,2],"weeks":[1,2,3]}]}]}',
  ciphertext:
    "XyNtlS36oF8fpVvM7WGP4Lssc8fj6aXqOChBH7ZCH7yTUEFr-cteE00K9Egeqc-yFwb_8CxNAS2rSbfnL7p6MQnHxS_spwg_wXd7DLBHiKP2fL9-oLyQfF_BWs-BD8k0nI6PH0Pt7Fyqx88pksaj48RIKsdKh6cZzU0JBEEodAN1ct-y_y5YvMsnFcsYjVyBwjUwnzcOQtLSnxOAzORGIyp71arkpIdChVUnrOjPBlQUnQTxiBSfxgnj7cPPDUSurTCSfvSoEV2FkXmV9fbkfGW7W-FkHBG_cpnrYP9bM1d5xvAGGyADvD3YbQuplDzTN561nq2JhtHD-mLNHr8wlwDTFGp8lEM",
};
const envelope = { app_public_key: vector.appPublic, nonce: vector.nonce, ciphertext: vector.ciphertext };
const webPrivateKey = () =>
  crypto.subtle.importKey(
    "jwk",
    { kty: "EC", crv: "P-256", d: vector.webPrivateD, x: vector.webX, y: vector.webY },
    { name: "ECDH", namedCurve: "P-256" },
    false,
    ["deriveBits"],
  );

describe("扫码同步加解密", () => {
  it("能解开 App 端按固定向量生成的密文", async () => {
    const plain = await decryptTransfer(await webPrivateKey(), vector.sessionId, envelope);
    expect(plain).toBe(vector.plaintext);
    expect(parseTransferPayload(plain).schedules[0].courses[0].name).toBe("高等数学");
  });

  it("密文换到另一张码或被改动时认证失败", async () => {
    const key = await webPrivateKey();
    await expect(decryptTransfer(key, "BBECAwQFBgcICQoLDA0ODw", envelope)).rejects.toBeInstanceOf(TransferError);
    const tampered = fromBase64Url(vector.ciphertext);
    tampered[3] ^= 1;
    await expect(decryptTransfer(key, vector.sessionId, { ...envelope, ciphertext: toBase64Url(tampered) })).rejects.toBeInstanceOf(TransferError);
    await expect(decryptTransfer(key, vector.sessionId, { ...envelope, app_public_key: "不是公钥" })).rejects.toBeInstanceOf(TransferError);
  });

  it("页面生成的密钥可与任意一次性对端完成往返", async () => {
    const keys = await createTransferKeys();
    expect(fromBase64Url(keys.publicKey)).toHaveLength(65);
    const sessionId = "session-roundtrip";
    const app = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
    const webPublic = await crypto.subtle.importKey("raw", fromBase64Url(keys.publicKey), { name: "ECDH", namedCurve: "P-256" }, false, []);
    const encoder = new TextEncoder();
    const material = await crypto.subtle.importKey("raw", await crypto.subtle.deriveBits({ name: "ECDH", public: webPublic }, app.privateKey, 256), "HKDF", false, ["deriveKey"]);
    const key = await crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt: encoder.encode(sessionId), info: encoder.encode(TRANSFER_PROTOCOL) }, material, { name: "AES-GCM", length: 256 }, false, ["encrypt"]);
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: encoder.encode(`${TRANSFER_PROTOCOL}|${sessionId}`) }, key, encoder.encode("{\"version\":1}"));
    const plain = await decryptTransfer(keys.privateKey, sessionId, {
      app_public_key: toBase64Url(new Uint8Array(await crypto.subtle.exportKey("raw", app.publicKey))),
      nonce: toBase64Url(nonce),
      ciphertext: toBase64Url(new Uint8Array(ciphertext)),
    });
    expect(plain).toBe("{\"version\":1}");
  });

  it("二维码把会话与公钥放在 # 之后", () => {
    const text = transferQrText("https://sylulive.online", "abc", "KEY");
    expect(text).toBe("https://sylulive.online/web/app-scan#v=1&s=abc&k=KEY");
    expect(new URL(text).search).toBe("");
  });
});

describe("扫码同步资料校验", () => {
  const course = { id: "c1", name: "数据结构", teacher: "李老师", room: "B202", day: 2, periods: [3, 4], weeks: [1, 2] };
  const payload = (extra: Record<string, unknown>) => JSON.stringify({ version: 1, generatedAt: "2026-11-11T08:00:00+08:00", ...extra });

  it("拒绝无法读取或版本不符的资料", () => {
    expect(() => parseTransferPayload("not json")).toThrow(TransferError);
    expect(() => parseTransferPayload(JSON.stringify({ version: 2 }))).toThrow(/同步格式不一致/);
  });

  it("只保留已知字段，跳过不合法的课程并消除重复 id", () => {
    const result = parseTransferPayload(payload({
      password: "不应被带入",
      schedules: [{
        id: "current", kind: "current", label: "2026-2027 第一学期", provider: "undergraduate",
        term: { year: "2026", semester: "3" }, termStart: "2026-09-07", cookie: "x",
        courses: [
          { ...course, studentId: "2300000000" },
          { ...course, name: "操作系统" },
          { ...course, id: "bad", day: 9 },
          { ...course, id: "bad2", weeks: [] },
          "junk",
        ],
      }, {
        id: "archive:1", kind: "archive", label: "大二下", provider: "other", term: { year: "2025", semester: "9" }, termStart: "2025-13-40", courses: [],
      }],
    }));
    expect(JSON.stringify(result)).not.toMatch(/不应被带入|2300000000|cookie/);
    expect(result.skipped).toBe(3);
    const [current, archive] = result.schedules;
    expect(current.courses.map((item) => item.id)).toEqual(["c1", "c1#2"]);
    expect(current.term).toEqual({ year: "2026", semester: "3" });
    expect(current.termStart).toBe("2026-09-07");
    expect(archive).toMatchObject({ kind: "archive", provider: "", term: null, termStart: "" });
    expect(preferredSchedule(result.schedules)).toBe(current);
    expect(transferSummary(result)).toEqual(["课表 1 份"]);
  });

  it("没有当前课表时退回第一份有课的课表", () => {
    const result = parseTransferPayload(payload({ schedules: [
      { id: "a", kind: "current", courses: [] },
      { id: "b", kind: "term", courses: [course] },
    ] }));
    expect(preferredSchedule(result.schedules)?.id).toBe("b");
    expect(preferredSchedule([])).toBeUndefined();
  });

  it("解析成绩、考试、二课与体测，缺失的部分保持为空", () => {
    const empty = parseTransferPayload(payload({}));
    expect(empty).toMatchObject({ schedules: [], grades: null, exams: null, erke: null, physical: null, skipped: 0 });
    expect(transferSummary(empty)).toEqual([]);

    const result = parseTransferPayload(payload({
      grades: { fetchedAt: "2026-11-10T10:00:00Z", items: [
        { id: "g1", name: "线性代数", credit: 3, score: "92", gpa: 4.2, nature: "必修", term: "2025-2026 第一学期" },
        { id: "g2", name: "体育", credit: "1", score: "优秀", gpa: null },
        { id: "g3", name: "", credit: 2, score: "80" },
        { id: "g4", name: "无学分", credit: -1, score: "80" },
      ] },
      exams: { items: [
        { id: "e1", name: "高数期末", startTime: "2026-12-30T09:00:00+08:00", endTime: "2026-12-30T11:00:00+08:00", room: "A101" },
        { id: "e2", name: "时间倒置", startTime: "2026-12-30T11:00:00+08:00", endTime: "2026-12-30T09:00:00+08:00" },
      ] },
      erke: { fetchedAt: "2026-11-09T10:00:00Z", requiredTotal: 60, earnedTotal: "42.5", graduationGap: 17.5, conclusion: "未达标",
        categories: [{ code: "A", name: "思想成长", required: 10, earned: 8 }, { code: "B", name: "" }],
        activities: [{ item: "志愿服务", score: "1.5", date: "2026-10-01", category: "志愿公益" }, { item: "" }] },
      physical: { fetchedAt: "2026-11-08T10:00:00Z", years: [
        { year: "2025", totalScore: "82.5", totalGrade: "良好", scores: [{ name: "50米跑", result: "7.2", grade: "良好", score: 80 }, { name: "" }] },
        { year: "", totalScore: 1 },
      ] },
    }));
    expect(result.skipped).toBe(3);
    expect(result.grades).toEqual([
      { id: "g1", name: "线性代数", credit: 3, score: "92", gpa: 4.2, nature: "必修", term: "2025-2026 第一学期" },
      { id: "g2", name: "体育", credit: 1, score: "优秀", gpa: null, nature: "", term: "" },
    ]);
    expect(result.gradesFetchedAt).toBe("2026-11-10T10:00:00.000Z");
    expect(result.exams).toHaveLength(1);
    expect(result.exams?.[0].startTime).toBe("2026-12-30T01:00:00.000Z");
    expect(result.erke).toMatchObject({ requiredTotal: 60, earnedTotal: 42.5, conclusion: "未达标" });
    expect(result.erke?.categories).toHaveLength(1);
    expect(result.erke?.activities).toHaveLength(1);
    expect(result.physical?.years).toEqual([
      { year: "2025", totalScore: 82.5, totalGrade: "良好", scores: [{ name: "50米跑", result: "7.2", grade: "良好", score: 80 }] },
    ]);
    expect(transferSummary(result)).toEqual(["成绩 2 门", "考试 1 场", "二课", "体测"]);
  });
});

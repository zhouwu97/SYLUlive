import { describe, expect, it } from "vitest";
import { ApiError } from "./api";
import {
  attachmentFailureState,
  attachmentFileIDs,
  attachmentHelp,
  initialAttachmentIDs,
  isInternalMessage,
  messageAttachmentIDs,
  messageSenderLabel,
  rejectAttachmentFiles,
  ticketAttachmentLimits,
  ticketAttachmentURL,
} from "./attachments";

function attachment(fileID: number, extra: Record<string, unknown> = {}) {
  return { id: fileID * 10, file_id: fileID, ...extra };
}

describe("工单附件地址", () => {
  it("只生成带鉴权的读取地址", () => {
    expect(ticketAttachmentURL(attachment(7))).toBe("/api/feedback/attachments/7");
    expect(ticketAttachmentURL({ id: 3, path: "/uploads/secret.png" })).toBe(
      "/api/feedback/attachments/3",
    );
  });

  it("不会把服务端返回的 /uploads 直链当成附件地址", () => {
    // 私有文件在 /uploads 上拿不到，任何以字符串形式流下来的路径都不能直接用。
    expect(ticketAttachmentURL("/uploads/secret.png")).toBe("");
    expect(ticketAttachmentURL({ url: "/uploads/secret.png" })).toBe("");
    expect(ticketAttachmentURL(0)).toBe("");
    expect(ticketAttachmentURL(-1)).toBe("");
    expect(ticketAttachmentURL(null)).toBe("");
  });

  it("同一附件在多条消息里出现时只保留一次", () => {
    expect(attachmentFileIDs([attachment(7), attachment(7), attachment(9)])).toEqual([
      7, 9,
    ]);
    expect(attachmentFileIDs("not-an-array")).toEqual([]);
  });
});

describe("初始提交与后续消息的附件划分", () => {
  it("优先读取 initial_submission 自己的附件", () => {
    const ids = initialAttachmentIDs({
      ticket: { attachments: [attachment(1)] },
      initial_submission: { attachments: [attachment(2), attachment(3)] },
      messages: [{ id: 9, attachments: [attachment(4)] }],
    });
    expect(ids).toEqual([2, 3]);
  });

  it("历史数据没有初始消息附件时回退到工单附件，并扣掉后续消息已挂的附件", () => {
    // 管理员后来发的图同样挂在 ticket.attachments 上，不扣掉会被再显示成「初始提交」的一部分。
    const ids = initialAttachmentIDs({
      ticket: { attachments: [attachment(1), attachment(2), attachment(3)] },
      initial_submission: { content: "最初的问题", attachments: [] },
      messages: [{ id: 9, attachments: [attachment(2), attachment(3)] }],
    });
    expect(ids).toEqual([1]);
  });

  it("按消息自身的附件渲染，不回头共用初始区编号", () => {
    expect(messageAttachmentIDs({ attachments: [attachment(5)] })).toEqual([5]);
    expect(messageAttachmentIDs(undefined)).toEqual([]);
  });
});

describe("消息来源标签", () => {
  it("区分系统事件、初始提交、官方回复、请求补充与内部备注", () => {
    expect(messageSenderLabel({ sender_type: "system", message_type: "system" })).toBe(
      "系统事件",
    );
    expect(
      messageSenderLabel({ sender_type: "admin", message_type: "status_change" }),
    ).toBe("系统事件");
    expect(
      messageSenderLabel({ sender_type: "user", message_type: "initial_submission" }),
    ).toBe("初始提交");
    expect(messageSenderLabel({ sender_type: "admin", message_type: "text" })).toBe(
      "官方回复",
    );
    expect(messageSenderLabel({ sender_type: "admin", message_type: "request_info" })).toBe(
      "请求补充信息",
    );
    expect(
      messageSenderLabel({
        sender_type: "admin",
        message_type: "internal_note",
        visible_to_user: true,
      }),
    ).toBe("内部备注");
    expect(
      messageSenderLabel({
        sender_type: "admin",
        message_type: "text",
        visible_to_user: false,
      }),
    ).toBe("内部备注");
    expect(messageSenderLabel({ sender_type: "user", message_type: "text" })).toBe(
      "用户补充",
    );
  });

  it("内部备注按类型或可见位任一命中，不会把用户回复误判成内部", () => {
    expect(isInternalMessage({ message_type: "internal_note" })).toBe(true);
    expect(isInternalMessage({ visible_to_user: false })).toBe(true);
    expect(
      isInternalMessage({ sender_type: "user", message_type: "text", visible_to_user: true }),
    ).toBe(false);
    expect(isInternalMessage(null)).toBe(false);
  });
});

function file(name: string, type: string, size: number) {
  return new File([new Uint8Array(size)], name, { type });
}

describe("上传前的本地约束", () => {
  const ok = () => file("a.png", "image/png", 1024);
  it("超出数量上限的附件逐条拒绝", () => {
    const files = Array.from({ length: ticketAttachmentLimits.maxCount + 2 }, ok);
    const rejections = rejectAttachmentFiles(files);
    expect(rejections).toHaveLength(2);
    expect(rejections.map((x) => x.index)).toEqual([6, 7]);
    expect(rejections[0].reason).toContain(`最多 ${ticketAttachmentLimits.maxCount} 张`);
  });

  it("拦下服务端不认的格式与超限体积", () => {
    const rejections = rejectAttachmentFiles([
      file("video.mp4", "video/mp4", 1024),
      file("big.png", "image/png", ticketAttachmentLimits.maxSizeBytes + 1),
      file("empty.png", "image/png", 0),
    ]);
    expect(rejections.map((x) => x.file)).toEqual(["video.mp4", "big.png"]);
    expect(rejections[0].reason).toContain("png");
    expect(rejections[1].reason).toContain("MiB");
    // 空文件由表单自己忽略，不该占用数量额度也不该报错。
    expect(rejectAttachmentFiles([file("empty.png", "image/png", 0), ok()])).toEqual([]);
  });

  it("同名附件按位置逐份处理，不会因为重名一起被丢掉", () => {
    const files = [
      file("shot.png", "image/png", 1024),
      file("shot.png", "image/png", 1024),
      file("shot.png", "video/mp4", 1024),
    ];
    // 前两份同名附件都合格，只有第三份被拒：按名字去重会把它们一起丢掉。
    expect(rejectAttachmentFiles(files).map((x) => `${x.index}:${x.file}`)).toEqual([
      "2:shot.png",
    ]);
  });

  it("提示文案与服务端上限一致", () => {
    expect(attachmentHelp).toContain("10 MiB");
    expect(attachmentHelp).toContain(String(ticketAttachmentLimits.maxCount));
    expect(attachmentHelp).not.toContain("webp");
  });
});

describe("附件读取失败的状态归类", () => {
  it("鉴权与授权问题是不可恢复状态，其余给重试", () => {
    expect(
      attachmentFailureState(new ApiError(401, "attachment_auth_expired", "登录已失效")),
    ).toEqual({ phase: "unavailable", message: "登录已失效，重新登录后可查看" });
    expect(
      attachmentFailureState(new ApiError(404, "attachment_unavailable", "无权查看")),
    ).toEqual({ phase: "unavailable", message: "无权查看，或文件已被删除" });
    expect(
      attachmentFailureState(new ApiError(500, "request_failed", "附件读取失败（500）")),
    ).toEqual({ phase: "retryable", message: "附件读取失败（500）" });
    expect(attachmentFailureState(new Error("网络中断"))).toEqual({
      phase: "retryable",
      message: "附件读取失败，请重试",
    });
  });
});

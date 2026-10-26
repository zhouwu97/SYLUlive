import { useEffect, useState } from "react";
import { ApiError, requestBlob } from "./api";
import { useUI } from "./ui";
import "./attachments.css";

// 工单附件是私有文件：服务端在事务内把上传记录 claim 成 private，
// 因此网页只能通过 /api/feedback/attachments/:file_id 这个带鉴权的接口读取。
// 这里集中做三件事：附件编号提取、地址生成与带状态的读取，避免出现第二处
// 手拼 /uploads 链接的地方。

export type AttachmentLimits = {
  maxCount: number;
  maxSizeBytes: number;
  allowedTypes: string[];
};

// 与上传服务端的裁决保持一致：/api/upload 用 http.DetectContentType 只放行
// jpg/png/gif，单张上限取 cfg.MaxFileSize（默认 10 MiB）。
// 客户端提前拦掉只是省一趟白传，服务端仍是最终判断方。
export const ticketAttachmentLimits: AttachmentLimits = {
  maxCount: 6,
  maxSizeBytes: 10 * 1024 * 1024,
  allowedTypes: ["image/png", "image/jpeg", "image/gif"],
};

export const attachmentAccept = ticketAttachmentLimits.allowedTypes
  .map((type) => `.${type.replace("image/", "")}`)
  .join(",");
export const attachmentHelp = `每张不超过 ${Math.round(
  ticketAttachmentLimits.maxSizeBytes / 1024 / 1024,
)} MiB，仅支持 ${ticketAttachmentLimits.allowedTypes
  .map((type) => type.replace("image/", ""))
  .join("、")}，最多 ${ticketAttachmentLimits.maxCount} 张。附件只在工单内可见。`;

export function attachmentFileID(value: unknown): number {
  if (typeof value === "number") return Number.isInteger(value) && value > 0 ? value : 0;
  if (!value || typeof value !== "object") return 0;
  const item = value as Record<string, any>;
  for (const candidate of [item.file_id, item.fileId, item.file?.id, item.id]) {
    const id = attachmentFileID(candidate);
    if (id) return id;
  }
  return 0;
}

export function attachmentFileIDs(values: unknown): number[] {
  if (!Array.isArray(values)) return [];
  const seen = new Set<number>();
  const ids: number[] = [];
  for (const value of values) {
    const id = attachmentFileID(value);
    if (id && !seen.has(id)) {
      seen.add(id);
      ids.push(id);
    }
  }
  return ids;
}

// 受保护地址：只接受正整数编号，任何指向 /uploads 的直链都在这里被挡掉。
export function ticketAttachmentURL(value: unknown): string {
  const id = attachmentFileID(value);
  if (!id) return "";
  return `/api/feedback/attachments/${id}`;
}

function referencedIDs(messages: unknown): Set<number> {
  const ids = new Set<number>();
  if (!Array.isArray(messages)) return ids;
  for (const message of messages) {
    for (const id of attachmentFileIDs((message as Record<string, any>)?.attachments)) {
      ids.add(id);
    }
  }
  return ids;
}

// 初始区优先用 initial_submission.attachments；只有它为空时才回退到
// ticket.attachments（历史数据的兼容字段），并且排除已经挂在后续消息上的附件，
// 否则管理员后来发的图会被重复显示成「初始提交」的一部分。
export function initialAttachmentIDs(data: unknown): number[] {
  const payload = (data || {}) as Record<string, any>;
  const messages = payload.messages;
  const fromInitial = attachmentFileIDs(payload.initial_submission?.attachments);
  if (fromInitial.length) return fromInitial;
  const later = referencedIDs(messages);
  return attachmentFileIDs(payload.ticket?.attachments).filter((id) => !later.has(id));
}

export function messageAttachmentIDs(message: unknown): number[] {
  return attachmentFileIDs((message as Record<string, any>)?.attachments);
}

// 按服务端的消息类型枚举区分系统事件、请求补充、官方回复与用户补充，
// 不能再简单地把「非 admin 一律叫用户补充」。
export function messageSenderLabel(message: unknown): string {
  const m = (message || {}) as Record<string, any>;
  const type = String(m.message_type || "");
  if (type === "system" || type === "status_change") return "系统事件";
  if (type === "initial_submission") return "初始提交";
  if (String(m.sender_type || "") === "admin") {
    if (type === "internal_note" || m.visible_to_user === false) return "内部备注";
    if (type === "request_info") return "请求补充信息";
    return "官方回复";
  }
  return "用户补充";
}

export function isInternalMessage(message: unknown): boolean {
  const m = (message || {}) as Record<string, any>;
  return m.visible_to_user === false || String(m.message_type || "") === "internal_note";
}

export type AttachmentRejection = {
  index: number;
  file: string;
  reason: string;
};

// 上传前的本地提示；服务端仍然是最终裁决，这里只负责避免用户白传一趟。
// 逐份按下标判断：同名附件（同一张截图被选了两次）不会互相顶掉。
export function rejectAttachmentFiles(
  files: File[],
  limits: AttachmentLimits = ticketAttachmentLimits,
): AttachmentRejection[] {
  const rejections: AttachmentRejection[] = [];
  files.forEach((file, index) => {
    if (!file.size) return;
    if (index + 1 > limits.maxCount) {
      rejections.push({
        index,
        file: file.name,
        reason: `最多 ${limits.maxCount} 张附件`,
      });
      return;
    }
    if (!limits.allowedTypes.includes(file.type)) {
      rejections.push({
        index,
        file: file.name,
        reason: `仅支持 ${limits.allowedTypes.map((t) => t.replace("image/", "")).join("、")} 图片`,
      });
      return;
    }
    if (file.size > limits.maxSizeBytes) {
      rejections.push({
        index,
        file: file.name,
        reason: `单张不超过 ${Math.round(limits.maxSizeBytes / 1024 / 1024)} MiB`,
      });
    }
  });
  return rejections;
}

type LoadState =
  | { phase: "loading" }
  | { phase: "ready"; url: string }
  | { phase: "unavailable"; message: string }
  | { phase: "retryable"; message: string };

export function attachmentFailureState(error: unknown): LoadState {
  if (error instanceof ApiError) {
    if (error.code === "attachment_auth_expired")
      return { phase: "unavailable", message: "登录已失效，重新登录后可查看" };
    if (error.code === "attachment_unavailable")
      return { phase: "unavailable", message: "无权查看，或文件已被删除" };
    return { phase: "retryable", message: error.message };
  }
  return { phase: "retryable", message: "附件读取失败，请重试" };
}

function AttachmentImage({ fileID, label }: { fileID: number; label: string }) {
  const ui = useUI();
  const [state, setState] = useState<LoadState>({ phase: "loading" });
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    let objectURL = "";
    setState({ phase: "loading" });
    requestBlob(ticketAttachmentURL(fileID), { signal: controller.signal })
      .then((blob) => {
        if (controller.signal.aborted) return;
        objectURL = URL.createObjectURL(blob);
        setState({ phase: "ready", url: objectURL });
      })
      .catch((error) => {
        if (controller.signal.aborted) return;
        setState(attachmentFailureState(error));
      });
    return () => {
      controller.abort();
      if (objectURL) URL.revokeObjectURL(objectURL);
    };
  }, [fileID, attempt]);

  // 灯箱标题与图片替代文本共用同一份标签，读屏用户听到的就是可点开放大的那张。
  if (state.phase === "ready")
    return (
      <button
        type="button"
        className="attachment-thumb"
        onClick={() =>
          ui.open(
            label,
            <img className="attachment-full" src={state.url} alt={label} />,
          )
        }
      >
        <img src={state.url} alt={label} loading="lazy" />
      </button>
    );
  if (state.phase === "loading")
    return <span className="attachment-state">{label} 加载中…</span>;
  if (state.phase === "unavailable")
    return <span className="attachment-state">{state.message}</span>;
  return (
    <button
      type="button"
      className="attachment-state"
      onClick={() => setAttempt((value) => value + 1)}
    >
      {state.message}（重试）
    </button>
  );
}

// `scope` 只影响标签文案：初始提交区和某条消息里的图片在无障碍里要能分清是哪一处。
export function TicketAttachments({
  data,
  scope = "附件",
}: {
  data: unknown;
  scope?: string;
}) {
  const ids = attachmentFileIDs(data);
  if (!ids.length) return null;
  return (
    <div className="post-images ticket-attachments">
      {ids.map((id, index) => (
        <AttachmentImage
          key={id}
          fileID={id}
          label={`${scope} ${index + 1}`}
        />
      ))}
    </div>
  );
}

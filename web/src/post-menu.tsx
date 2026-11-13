// 信息流卡片右上角的「…」菜单与「不感兴趣」后的撤销条。
// 菜单项与 App 的 FeedPostActionMenu 对齐：别人的帖子是 不感兴趣 / 不看 TA / 举报，
// 自己的帖子是 编辑 / 删除；两种都多一个「复制链接」。负反馈只在首页信息流里出现。
import { useEffect, useId, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from "react";
import { errorText, request, write, type Entity } from "./api";
import { useAuth } from "./auth";
import {
  clearDismissed,
  feedFeedbackApi,
  markDismissed,
  type Dismissal,
  type FeedSource,
} from "./feed-feedback";
import { copyPostLink } from "./post-actions";
import { Form, Icon, useUI } from "./ui";
import "./post-menu.css";

export function ReportPostForm({ postId }: { postId: number }) {
  const ui = useUI();
  return (
    <Form
      fields={[{ name: "reason", label: "举报原因", type: "textarea", required: true }]}
      submit="提交举报"
      onSubmit={async (data) => {
        await write("/api/reports", { ...data, target_type: "post", target_id: postId });
        ui.close();
        ui.notify("举报已提交，我们会尽快处理");
      }}
    />
  );
}

function DeletePostConfirm({ postId }: { postId: number }) {
  const ui = useUI();
  const [busy, setBusy] = useState(false);
  return (
    <>
      <p>删除后帖子将不再公开显示。</p>
      <div className="form-actions">
        <button type="button" className="btn" onClick={ui.close}>取消</button>
        <button
          type="button"
          className="btn danger"
          disabled={busy}
          aria-busy={busy}
          onClick={async () => {
            setBusy(true);
            const ok = await ui.act(() => request(`/api/posts/${postId}`, { method: "DELETE" }), "帖子已删除");
            setBusy(false);
            if (ok) ui.close();
          }}
        >
          {busy ? "正在删除…" : "确认删除"}
        </button>
      </div>
    </>
  );
}

type MenuItem = { key: string; label: string; hint?: string; icon: string; danger?: boolean; run: () => void };

export function PostCardMenu({
  post,
  feedSource,
  onEdit,
}: {
  post: Entity;
  /** 只有首页信息流传入；搜索、收藏、个人主页不提供负反馈。 */
  feedSource?: FeedSource;
  onEdit?: () => void;
}) {
  const auth = useAuth(), ui = useUI();
  const [open, setOpen] = useState(false);
  const wrap = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const menuId = useId();
  const postId = Number(post.id);
  const authorId = Number(post.author_id || post.author?.id) || undefined;
  const authorName = post.author?.nickname || "校园同学";
  const mine = !!auth.user && authorId === auth.user.id;

  function close(focusTrigger = true) {
    setOpen(false);
    if (focusTrigger) trigger.current?.focus();
  }

  useEffect(() => {
    if (!open) return;
    const outside = (event: PointerEvent) => { if (!wrap.current?.contains(event.target as Node)) setOpen(false); };
    document.addEventListener("pointerdown", outside);
    // 打开后把焦点放到第一项，键盘用户可以直接上下选择。
    const frame = requestAnimationFrame(() => wrap.current?.querySelector<HTMLElement>('[role="menuitem"]')?.focus());
    return () => { document.removeEventListener("pointerdown", outside); cancelAnimationFrame(frame); };
  }, [open]);

  async function dismiss(dismissal: Dismissal, send: () => Promise<unknown>) {
    if (!auth.requireUser() || !auth.user) return;
    const userId = auth.user.id;
    // 先收起卡片，请求失败再恢复，点击后立即有反馈。
    markDismissed(userId, dismissal);
    try {
      await send();
    } catch (error) {
      clearDismissed(userId, dismissal);
      ui.notify(errorText(error));
    }
  }

  const items: MenuItem[] = [];
  if (mine) {
    if (onEdit) items.push({ key: "edit", label: "编辑", icon: "edit", run: onEdit });
  } else if (feedSource) {
    items.push({
      key: "not-interested", label: "不感兴趣", hint: "首页不再推荐，减少类似内容", icon: "block",
      run: () => void dismiss({ kind: "post", postId }, () => feedFeedbackApi.notInterested(postId, feedSource)),
    });
    if (authorId) items.push({
      key: "hide-author", label: "不看 TA", hint: `首页不再展示 ${authorName} 的帖子`, icon: "eye-off",
      run: () => void dismiss({ kind: "author", authorId, postId, authorName }, () => feedFeedbackApi.hideAuthor(authorId)),
    });
  }
  items.push({ key: "copy", label: "复制链接", icon: "link", run: () => void copyPostLink(post, ui) });
  if (mine) {
    items.push({ key: "delete", label: "删除", icon: "trash", danger: true, run: () => ui.open("删除内容", <DeletePostConfirm postId={postId} />) });
  } else {
    items.push({ key: "report", label: "举报", icon: "flag", run: () => auth.requireUser() && ui.open("举报内容", <ReportPostForm postId={postId} />) });
  }

  function onMenuKey(event: ReactKeyboardEvent<HTMLDivElement>) {
    const all = [...(wrap.current?.querySelectorAll<HTMLElement>('[role="menuitem"]') || [])];
    const index = all.indexOf(document.activeElement as HTMLElement);
    let next = -1;
    if (event.key === "ArrowDown") next = (index + 1) % all.length;
    else if (event.key === "ArrowUp") next = (index - 1 + all.length) % all.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = all.length - 1;
    else if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); close(); return; }
    else if (event.key === "Tab") { setOpen(false); return; }
    if (next < 0) return;
    event.preventDefault();
    all[next]?.focus();
  }

  return (
    <div className={`post-card-menu${open ? " is-open" : ""}`} ref={wrap}>
      <button
        ref={trigger}
        type="button"
        className="post-card-menu-trigger"
        aria-label="帖子更多操作"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        onClick={() => setOpen((value) => !value)}
        onKeyDown={(event) => { if (event.key === "ArrowDown" && !open) { event.preventDefault(); setOpen(true); } }}
      >
        <Icon name="more" size={20} />
      </button>
      {open && (
        <div className="post-card-menu-list" role="menu" id={menuId} aria-label="帖子操作" onKeyDown={onMenuKey}>
          {items.map((item, index) => (
            <span key={item.key} className="post-card-menu-row">
              {item.key === "copy" && index > 0 && !mine && <span className="post-card-menu-divider" role="separator" />}
              <button
                type="button"
                role="menuitem"
                tabIndex={-1}
                className={item.danger ? "is-danger" : undefined}
                onClick={() => {
                  // 负反馈会把卡片换成撤销条，焦点交给撤销按钮；其他操作回到触发按钮，弹窗关闭后焦点能还原。
                  close(item.key !== "not-interested" && item.key !== "hide-author");
                  item.run();
                }}
              >
                <Icon name={item.icon} size={18} />
                <span className="post-card-menu-copy"><b>{item.label}</b>{item.hint && <small>{item.hint}</small>}</span>
              </button>
            </span>
          ))}
        </div>
      )}
    </div>
  );
}

/** 卡片被标记后留下的一行撤销条；撤销成功后卡片原样回来。 */
export function DismissedPost({ dismissal }: { dismissal: Dismissal }) {
  const auth = useAuth(), ui = useUI();
  const [busy, setBusy] = useState(false);
  const undoButton = useRef<HTMLButtonElement>(null);
  const author = dismissal.kind === "author";
  useEffect(() => {
    // 菜单项随卡片一起卸载后焦点会落到 body，把它接到撤销按钮上。
    if (!document.activeElement || document.activeElement === document.body) undoButton.current?.focus({ preventScroll: true });
  }, []);
  async function undo() {
    if (!auth.user || busy) return;
    const userId = auth.user.id;
    setBusy(true);
    try {
      await (author ? feedFeedbackApi.restoreAuthor(dismissal.authorId) : feedFeedbackApi.undoNotInterested(dismissal.postId));
      clearDismissed(userId, dismissal);
      ui.notify(author ? `已恢复显示 ${dismissal.authorName} 的帖子` : "已撤销，这条帖子会继续出现在推荐里");
    } catch (error) {
      ui.notify(errorText(error));
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="feed-dismissed" role="status">
      <Icon name={author ? "eye-off" : "block"} size={18} />
      <p>
        <b>{author ? `已不再展示 ${dismissal.authorName} 的帖子` : "已减少此类推荐"}</b>
        <span>{author ? "首页的推荐、最新和热门都不会再出现 TA 的内容。" : "首页不再展示这条帖子，搜索仍然可以找到。"}</span>
      </p>
      <button ref={undoButton} type="button" className="btn" disabled={busy} aria-busy={busy} onClick={undo}>{busy ? "正在撤销…" : "撤销"}</button>
    </div>
  );
}

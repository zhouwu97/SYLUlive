import { useEffect, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { asset, errorText, rows, time, useApi, write, type Entity } from "./api";
import { useAuth } from "./auth";
import { MediaUploadPicker, uploadImageFiles } from "./media";
import { StickerPicker, StickerRenderer, type StickerPayload } from "./emoji";
import { Empty, Head, Icon, QueryState, useUI } from "./ui";
import { consumeSSE } from "./sse";

function conversationPeer(conversation: Entity, userId?: number) {
  const first = conversation.user1 || conversation.user_1;
  const second = conversation.user2 || conversation.user_2;
  return Number(conversation.user1_id) === userId ? second : first || (Number(conversation.user2_id) === userId ? first : second);
}

function messageImage(message: Entity) {
  const file = message.file || message.attachment;
  return asset(file?.download_url || file?.url || file?.path) || (message.file_id ? `/api/messages/files/${message.file_id}` : undefined);
}

function MessageBubble({ message, mine }: { message: Entity; mine: boolean }) {
  const image = messageImage(message);
  return <div className={`message-bubble ${mine ? "mine" : ""}`}>
    {message.content && message.content !== "[表情]" && <p>{message.content}</p>}
    {message.sticker_id && <StickerRenderer stickerId={message.sticker_id} assetKey={message.asset_key} packId={message.pack_id} />}
    {image && <img className="message-image" src={image} alt="消息图片" loading="lazy" />}
    <small>{time(message.created_at)}</small>
  </div>;
}

export function Messages() {
  const auth = useAuth(), ui = useUI(), qc = useQueryClient();
  const conversations = useApi(auth.user ? "/api/messages/conversations" : null);
  const [selected, setSelected] = useState<number | null>(null);
  const list = rows(conversations.data, "conversations");
  useEffect(() => {
    if (selected === null && list[0]?.id) setSelected(Number(list[0].id));
  }, [list, selected]);
  const active = list.find((item) => Number(item.id) === selected);
  const peer = conversationPeer(active || {}, auth.user?.id);
  const messages = useApi(selected ? `/api/messages/conversations/${selected}` : null);

  useEffect(() => {
    if (!selected) return;
    write(`/api/messages/conversations/${selected}/read`, {}).then(() => qc.invalidateQueries({ queryKey: ["api", "/api/messages/conversations"] })).catch(() => undefined);
  }, [selected, qc]);

  useEffect(() => {
    if (!auth.user) return;
    const controller = new AbortController();
    fetch("/api/messages/events", { credentials: "same-origin", headers: { Accept: "text/event-stream", "X-Requested-With": "SYLUlive-Web" }, signal: controller.signal })
      .then((response) => consumeSSE(response, () => { qc.invalidateQueries({ queryKey: ["api", "/api/messages/conversations"] }); if (selected) qc.invalidateQueries({ queryKey: ["api", `/api/messages/conversations/${selected}`] }); }))
      .catch(() => undefined);
    return () => controller.abort();
  }, [auth.user?.id, qc, selected]);

  return <>
    <Head title="私信" description="和同学分享图片、表情与校园日常" />
    {!auth.user ? <Empty title="登录后查看私信" description="私信内容只会在账号之间传递" /> : !list.length ? <Empty title="还没有会话" description="从同学主页发起一条消息后，会话会出现在这里" /> : <div className="chat-layout messages-shell">
      <aside className="chat-list">
        {list.map((conversation) => {
          const itemPeer = conversationPeer(conversation, auth.user?.id);
          return <button type="button" key={conversation.id} className={`chat-row ${selected === Number(conversation.id) ? "active" : ""}`} onClick={() => setSelected(Number(conversation.id))}>
            <span className="chat-avatar">{itemPeer?.nickname?.slice(0, 1) || "同"}</span>
            <span className="chat-row-copy"><b>{itemPeer?.nickname || "校园同学"}</b><small>{conversation.last_message?.content || (conversation.last_message?.sticker_id ? "表情" : "暂无消息")}</small></span>
            {Number(conversation.unread_count) > 0 && <em>{conversation.unread_count}</em>}
          </button>;
        })}
      </aside>
      <section className="chat-main">
        <div className="chat-head"><div><b>{peer?.nickname || "会话"}</b><small>私密消息</small></div><span className="tag brand">实时</span></div>
        <QueryState query={messages} empty={!rows(messages.data, "messages").length}>
          <div className="chat-messages">
            {rows(messages.data, "messages").map((message) => <MessageBubble key={message.id || message.client_message_id} message={message} mine={Number(message.sender_id) === auth.user?.id} />)}
          </div>
        </QueryState>
        {peer?.id && <MessageComposer targetId={Number(peer.id)} onSent={() => { qc.invalidateQueries({ queryKey: ["api", `/api/messages/conversations/${selected}`] }); qc.invalidateQueries({ queryKey: ["api", "/api/messages/conversations"] }); }} />}
      </section>
    </div>}
  </>;
}

function MessageComposer({ targetId, onSent }: { targetId: number; onSent: () => void }) {
  const ui = useUI();
  const [content, setContent] = useState("");
  const [files, setFiles] = useState<File[]>([]);
  const [sticker, setSticker] = useState<StickerPayload | null>(null);
  const [showStickers, setShowStickers] = useState(false);
  const [busy, setBusy] = useState(false);
  async function send() {
    if (busy || (!content.trim() && !files.length && !sticker)) return;
    if (files.length && sticker) { ui.notify("图片和表情不能同时发送"); return; }
    setBusy(true);
    try {
      let fileId: number | undefined;
      if (files.length) fileId = (await uploadImageFiles(files))[0];
      await write(`/api/messages/${targetId}`, { content: content.trim(), ...(fileId ? { file_id: fileId } : {}), ...(sticker ? { sticker_id: sticker.sticker_id, asset_key: sticker.asset_key, pack_id: sticker.pack_id } : {}), client_message_id: crypto.randomUUID() });
      setContent(""); setFiles([]); setSticker(null); setShowStickers(false); onSent(); ui.notify("消息已发送");
    } catch (error) { ui.notify(errorText(error)); } finally { setBusy(false); }
  }
  return <div className="message-composer">
    {sticker && <div className="composer-sticker"><StickerRenderer stickerId={sticker.sticker_id} assetKey={sticker.asset_key} packId={sticker.pack_id} label={sticker.label} /><button type="button" className="icon-btn" onClick={() => setSticker(null)} aria-label="移除表情">×</button></div>}
    {files.length > 0 && <div className="composer-file">已选择 {files.length} 张图片<button type="button" className="link-btn" onClick={() => setFiles([])}>清除</button></div>}
    {showStickers && <StickerPicker compact onSelect={(value) => { setSticker(value); setFiles([]); }} />}
    <textarea value={content} onChange={(event) => setContent(event.target.value)} placeholder="写下想说的话…" rows={2} onKeyDown={(event) => { if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) { event.preventDefault(); send(); } }} />
    <div className="composer-actions"><button type="button" className={`icon-btn ${showStickers ? "active" : ""}`} aria-label="选择表情" onClick={() => setShowStickers((value) => !value)}><span>☺</span></button><label className="icon-btn" aria-label="添加图片"><Icon name="file" /><input type="file" accept="image/jpeg,image/png,image/gif" hidden onChange={(event) => { const files = Array.from(event.target.files || []).slice(0, 1); setFiles(files); setSticker(null); }} /></label><button type="button" className="btn primary" disabled={busy} onClick={send}>{busy ? "发送中…" : "发送"}</button></div>
  </div>;
}

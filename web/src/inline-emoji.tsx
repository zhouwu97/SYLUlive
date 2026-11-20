import { graphemes, splitEmojiText } from "./emoji-text";
import "./inline-emoji.css";

export function EmojiText({ text }: { text: string }) {
  const parts = splitEmojiText(text);
  // 只有 1–3 个 Emoji 的短内容（如只回一个 😇）按聊天习惯放大，避免缩成正文里的小图标。
  if (parts.some((part) => part.emoji) && parts.every((part) => part.emoji || !part.text.trim()) && graphemes(text.trim()).length <= 3) {
    return <span className="inline-emoji emoji-only">{text.trim()}</span>;
  }
  return parts.map((part, index) => part.emoji ? <span className="inline-emoji" key={index}>{part.text}</span> : part.text);
}

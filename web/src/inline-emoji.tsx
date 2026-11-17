import { splitEmojiText } from "./emoji-text";
import "./inline-emoji.css";

export function EmojiText({ text }: { text: string }) {
  return splitEmojiText(text).map((part, index) => part.emoji ? <span className="inline-emoji" key={index}>{part.text}</span> : part.text);
}

import { describe, expect, it } from "vitest";
import { splitEmojiText, truncateGraphemes } from "./emoji-text";

describe("正文 Emoji 保留 Unicode 字符", () => {
  it("中文、数字和标点不使用 Emoji 字体", () => {
    expect(splitEmojiText("课程 2026 #1 © ™ 😡😭🙏")).toEqual([
      { text: "课程 2026 #1 © ™ ", emoji: false },
      { text: "😡", emoji: true }, { text: "😭", emoji: true }, { text: "🙏", emoji: true },
    ]);
  });
  it.each(["👩🏽‍💻", "👨‍👩‍👧‍👦", "🇨🇳", "1️⃣", "❤️", "🙏🏽"])("组合字符 %s 不拆分", emoji => {
    expect(splitEmojiText(emoji)).toEqual([{ text: emoji, emoji: true }]);
    expect(truncateGraphemes(`前${emoji}后`, 2)).toEqual({ text: `前${emoji}`, truncated: true });
  });
  it("显式文本样式与 HTML 字面内容保持原样", () => {
    const text = "<script>❤︎</script>";
    expect(splitEmojiText(text)).toEqual([{ text, emoji: false }]);
  });
  it("摘要截断不切断代理对或 ZWJ 序列", () => {
    const prefix = "文".repeat(219);
    expect(truncateGraphemes(`${prefix}👩🏽‍💻后`, 220)).toEqual({ text: `${prefix}👩🏽‍💻`, truncated: true });
    expect(truncateGraphemes("😡😭🙏", 3)).toEqual({ text: "😡😭🙏", truncated: false });
  });
});

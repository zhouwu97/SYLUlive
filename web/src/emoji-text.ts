const segmenter = typeof Intl.Segmenter === "function" ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null;
const emojiPresentation = /\p{Emoji_Presentation}/u;
const pictograph = /\p{Extended_Pictographic}/u;

export function graphemes(text: string): string[] {
  return segmenter ? Array.from(segmenter.segment(text), part => part.segment) : Array.from(text);
}

/** 只给 Emoji 单独指定字体，数字、标点和中文继续使用正文文字字体。 */
export function splitEmojiText(text: string): { text: string; emoji: boolean }[] {
  if (!segmenter) return [{ text, emoji: false }];
  const parts: { text: string; emoji: boolean }[] = [];
  for (const segment of graphemes(text)) {
    const emoji = !segment.includes("\uFE0E") && (emojiPresentation.test(segment) || segment.includes("\u20E3") || segment.includes("\uFE0F") && pictograph.test(segment));
    const previous = parts.at(-1);
    if (!emoji && previous && !previous.emoji) previous.text += segment;
    else parts.push({ text: segment, emoji });
  }
  return parts;
}

export function truncateGraphemes(text: string, limit: number) {
  const parts = graphemes(text);
  return { text: parts.slice(0, limit).join(""), truncated: parts.length > limit };
}

import { describe, expect, it } from "vitest";
import { favoriteCreateFields, favoriteSelection, messageEmojiFields, packAssetUrl, stickerUrl } from "./emoji-selection";

const hash = "aad70d8d064f9eb79286c1393490716c";
describe("表情选择与发送契约", () => {
  it("私有图片使用授权 file_id，不把 asset_id 当成 sticker_id", () => {
    const item = favoriteSelection({ favorite_id: 9, kind: "custom", asset_id: 33, file_id: 44, url: "https://untrusted.example/image", is_animated: true });
    expect(item).toMatchObject({ kind: "image", favorite_id: 9, file_id: 44, url: "/api/emoji/favorites/9/file", asset_key: "private:33", animated: true });
    expect(messageEmojiFields(item!)).toEqual({ file_id: 44 });
    expect(favoriteCreateFields(item!)).toEqual({ kind: "custom", file_id: 44 });
  });
  it("旧贴图收藏不猜所属包，保留 hash 兼容", () => {
    const item = favoriteSelection({ id: 9, kind: "builtin", sticker_id: hash });
    expect(item).toMatchObject({ kind: "sticker", url: `/stickers/${hash}` });
    expect(messageEmojiFields(item!)).toEqual({ sticker_id: hash });
    expect(favoriteCreateFields(item!)).toEqual({ kind: "builtin", sticker_id: hash });
  });
  it("官方贴图保留逻辑身份，不混入私有文件字段", () => {
    const item = favoriteSelection({ id: 9, sticker_id: hash, asset_key: `official:ovo:${hash}`, pack_id: "ovo" });
    expect(messageEmojiFields(item!)).toEqual({ sticker_id: hash, asset_key: `official:ovo:${hash}`, pack_id: "ovo" });
    expect(item?.url).toBe(`/api/emoji/packs/ovo/assets/${hash}`);
  });
  it.each([{}, { id: 2, asset_id: 33 }, { id: 2, file_id: 0 }, { id: -1, file_id: 44 }, { id: 1.5, file_id: 44 }, { id: 9, sticker_id: "33" }, { id: 9, file_id: "44x" }])("缺损身份不能生成发送数据 %j", (item) => {
    expect(favoriteSelection(item)).toBeNull();
  });
  it("资源路径编码并锁定目录版本", () => {
    expect(packAssetUrl("a/b", "a?b", 123)).toBe("/api/emoji/packs/a%2Fb/assets/a%3Fb?version=123");
    expect(stickerUrl(hash, `builtin:${hash}`)).toBe(`/stickers/${hash}`);
    expect(stickerUrl(hash, `official:ovo:${hash}`)).toBe(`/api/emoji/packs/ovo/assets/${hash}`);
  });
});

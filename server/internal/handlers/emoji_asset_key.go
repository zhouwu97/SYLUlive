package handlers

import (
	"errors"
	"fmt"
	"strings"
)

// 资源键规则与客户端 EmojiAssetKey.parse 保持一致。服务端不能假设客户端
// 已经校验过：一旦写入，同一条消息会被所有接收方按同一身份解析渲染。
const (
	emojiAssetKeyMaxLength = 512
	emojiAssetPartMaxLength = 128
)

var emojiAssetNamespaces = map[string]struct{}{
	"unicode": {}, "builtin": {}, "official": {}, "private": {}, "local": {},
}

// emojiAssetKey 是拆分并校验过的资源身份，packID 为空表示该命名空间不带包身份。
type emojiAssetKey struct {
	namespace string
	packID    string
	assetID   string
}

// validateEmojiAssetReference 校验提交到私信与回复中的资源身份：asset_key 结构、
// asset_key 与 pack_id 的一致性，以及 official 命名空间下的资源确实已经发布。
func validateEmojiAssetReference(assetKey, packID *string) error {
	if assetKey == nil || *assetKey == "" {
		return nil
	}
	key, err := parseEmojiAssetKey(*assetKey)
	if err != nil {
		return err
	}
	claimed := ""
	if packID != nil {
		claimed = strings.TrimSpace(*packID)
	}
	if claimed != key.packID {
		return errors.New("pack_id 与 asset_key 不一致")
	}
	if key.namespace == "official" && !isPublishedOfficialEmoji(key.packID, key.assetID) {
		return errors.New("官方表情包资源不存在")
	}
	return nil
}

func parseEmojiAssetKey(raw string) (emojiAssetKey, error) {
	if len(raw) > emojiAssetKeyMaxLength {
		return emojiAssetKey{}, errors.New("asset_key 过长")
	}
	parts := strings.Split(raw, ":")
	if len(parts) < 2 || len(parts) > 3 {
		return emojiAssetKey{}, errors.New("asset_key 格式无效")
	}
	key := emojiAssetKey{namespace: parts[0], assetID: parts[len(parts)-1]}
	if len(parts) == 3 {
		key.packID = parts[1]
	}
	if _, ok := emojiAssetNamespaces[key.namespace]; !ok {
		return emojiAssetKey{}, fmt.Errorf("不支持的表情资源命名空间: %s", key.namespace)
	}
	// unicode 资源不带包身份；private 兼容历史的不带包身份写法；
	// 其余命名空间必须带，否则无法定位资源属于哪个包。
	switch key.namespace {
	case "unicode":
		if key.packID != "" {
			return emojiAssetKey{}, errors.New("Unicode 资源不允许携带 pack_id")
		}
	case "private":
	case "builtin", "official", "local":
		if key.packID == "" {
			return emojiAssetKey{}, fmt.Errorf("%s 资源必须携带 pack_id", key.namespace)
		}
	}
	values := []string{key.assetID}
	if key.packID != "" {
		values = append(values, key.packID)
	}
	for _, value := range values {
		if err := validateEmojiAssetPart(value); err != nil {
			return emojiAssetKey{}, err
		}
	}
	return key, nil
}

// validateEmojiAssetPart 允许非 ASCII 标识（Unicode 表情本身、第三方包的资源名），
// 但首尾空白与控制字符会污染存储、日志与展示，必须在写入前拒绝。
func validateEmojiAssetPart(value string) error {
	if value == "" || len(value) > emojiAssetPartMaxLength ||
		strings.TrimSpace(value) != value ||
		strings.ContainsFunc(value, func(r rune) bool { return r < 0x20 || r == 0x7f }) {
		return errors.New("表情资源标识无效")
	}
	return nil
}

func isPublishedOfficialEmoji(packID, assetID string) bool {
	for i := range officialEmojiPacks {
		pack := &officialEmojiPacks[i]
		if pack.ID != packID {
			continue
		}
		_, exists := pack.assets[assetID]
		return exists
	}
	return false
}

package utils

import (
	"strings"

	"github.com/clipperhouse/uax29/v2/graphemes"
)

// TruncateGraphemes 按用户可见字符截断文本，避免拆开组合 Emoji。
func TruncateGraphemes(value string, limit int) string {
	if value == "" {
		return value
	}
	if limit <= 0 {
		return "..."
	}

	iterator := graphemes.FromString(value)
	count := 0
	end := 0
	for iterator.Next() {
		count++
		if count > limit {
			return value[:end] + "..."
		}
		end = iterator.End()
	}
	return value
}

// CountGraphemes 按 Unicode 扩展字素簇统计用户可见字符。
func CountGraphemes(value string) int {
	iterator := graphemes.FromString(value)
	count := 0
	for iterator.Next() {
		count++
	}
	return count
}

// NormalizeDishName 菜品名归一化：trim、合并并删除内部空白、兼容全角空格、转小写。
// " 锅包肉 "、"锅包肉"、"锅 包 肉"、"锅　包肉" 均归一化为 "锅包肉"。
func NormalizeDishName(name string) string {
	// 全角空格（U+3000）→ 普通空格
	normalized := strings.Map(func(r rune) rune {
		if r == '\u3000' {
			return ' '
		}
		return r
	}, name)
	// Fields 按空白切分并丢弃空白（连续空白合并 + 删除菜名中空白）
	return strings.ToLower(strings.Join(strings.Fields(strings.TrimSpace(normalized)), ""))
}

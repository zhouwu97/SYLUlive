package utils

import "github.com/clipperhouse/uax29/v2/graphemes"

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

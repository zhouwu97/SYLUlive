package utils

import "testing"

func TestTruncateGraphemesPreservesVisibleCharacters(t *testing.T) {
	tests := []struct {
		name  string
		value string
		limit int
		want  string
	}{
		{name: "无需截断", value: "你好😀", limit: 3, want: "你好😀"},
		{name: "家庭组合", value: "A👨‍👩‍👧‍👦B", limit: 2, want: "A👨‍👩‍👧‍👦..."},
		{name: "国旗组合", value: "🇨🇳🇯🇵", limit: 1, want: "🇨🇳..."},
		{name: "肤色组合", value: "👍🏻👍🏽", limit: 1, want: "👍🏻..."},
		{name: "变体选择符", value: "❤️!", limit: 1, want: "❤️..."},
		{name: "零上限", value: "😀", limit: 0, want: "..."},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := TruncateGraphemes(test.value, test.limit); got != test.want {
				t.Fatalf("TruncateGraphemes() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestNormalizeDishName(t *testing.T) {
	cases := []struct {
		input string
		want  string
	}{
		{" 锅包肉 ", "锅包肉"},
		{"锅包肉", "锅包肉"},
		{"锅 包 肉", "锅包肉"},
		{"锅　包肉", "锅包肉"}, // 全角空格 U+3000
		{"麻 辣 香 锅", "麻辣香锅"},
		{"  ", ""},
		{"", ""},
		{"  锅 包 肉  ", "锅包肉"},
	}
	for _, c := range cases {
		if got := NormalizeDishName(c.input); got != c.want {
			t.Errorf("NormalizeDishName(%q) = %q, want %q", c.input, got, c.want)
		}
	}
}

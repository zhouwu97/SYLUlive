package services

// CalculateWaterSectionLevel 计算用户在某个版块内的等级。
// 与 CalculateUserLevel 不同，版块等级阈值更低，便于在水帖版块快速获得身份。
func CalculateWaterSectionLevel(exp int) int {
	if exp >= 800 {
		return 8
	}
	if exp >= 560 {
		return 7
	}
	if exp >= 360 {
		return 6
	}
	if exp >= 220 {
		return 5
	}
	if exp >= 120 {
		return 4
	}
	if exp >= 60 {
		return 3
	}
	if exp >= 20 {
		return 2
	}
	return 1
}

// WaterSectionLevelMinExp 返回某个版块等级的最低经验。
func WaterSectionLevelMinExp(level int) int {
	switch level {
	case 8:
		return 800
	case 7:
		return 560
	case 6:
		return 360
	case 5:
		return 220
	case 4:
		return 120
	case 3:
		return 60
	case 2:
		return 20
	default:
		return 0
	}
}

// NextWaterSectionLevelExp 返回下一级所需总经验；满级返回 0。
func NextWaterSectionLevelExp(level int) int {
	if level >= 8 {
		return 0
	}
	return WaterSectionLevelMinExp(level + 1)
}

// defaultWaterSectionLevelTitles 默认版块等级称号。
// 不能被外部修改；版主自定义覆盖存储在 WaterSectionLevelTitle 表。
var defaultWaterSectionLevelTitles = map[int]string{
	1: "初来乍到",
	2: "小有活跃",
	3: "常驻同学",
	4: "后起之秀",
	5: "版块熟人",
	6: "热心答主",
	7: "核心成员",
	8: "镇版大佬",
}

// DefaultWaterSectionLevelTitle 返回某个等级的默认称号。
// 超出 1-8 范围返回空字符串。
func DefaultWaterSectionLevelTitle(level int) string {
	if level < 1 || level > 8 {
		return ""
	}
	return defaultWaterSectionLevelTitles[level]
}

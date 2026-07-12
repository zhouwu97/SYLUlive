package models

// ExpAward 经验奖励结果，用于接口返回给前端展示提示。
type ExpAward struct {
	Scope       string `json:"scope"`        // "global" / "water_section"
	Exp         int    `json:"exp"`          // 本次发放的经验
	Action      string `json:"action"`       // post_daily / reply_daily
	LevelBefore int    `json:"level_before"` // 发放前等级
	LevelAfter  int    `json:"level_after"`  // 发放后等级
	LevelUp     bool   `json:"level_up"`     // 是否升级

	// 仅当 scope=water_section
	SectionID    uint   `json:"section_id,omitempty"`
	SectionSlug  string `json:"section_slug,omitempty"`
	SectionTitle string `json:"section_title,omitempty"`
	TitleBefore  string `json:"title_before,omitempty"`
	TitleAfter   string `json:"title_after,omitempty"`
}

// WaterSectionAuthorMeta 帖子作者在该帖子所属水帖版块内的等级与称号。
// 仅当 board_id=1 且 post_type 是有效水帖版块 slug 时由后端填充。
type WaterSectionAuthorMeta struct {
	SectionID    uint   `json:"section_id"`
	SectionSlug  string `json:"section_slug"`
	SectionTitle string `json:"section_title,omitempty"`
	Level        int    `json:"level"`
	Exp          int    `json:"exp"`
	Title        string `json:"title"` // 版主自定义优先；否则默认称号
}

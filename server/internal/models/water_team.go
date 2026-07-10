package models

import (
	"time"

	"gorm.io/gorm"
)

// Team Recruitment Status
const (
	RecruitmentStatusRecruiting = "recruiting"
	RecruitmentStatusFull       = "full"
	RecruitmentStatusClosed     = "closed"
	RecruitmentStatusExpired    = "expired"
)

// Team Application Status
const (
	ApplicationStatusPending   = "pending"
	ApplicationStatusAccepted  = "accepted"
	ApplicationStatusRejected  = "rejected"
	ApplicationStatusCancelled = "cancelled"
)

// WaterTeamRecruitment 组队招募信息
type WaterTeamRecruitment struct {
	ID            uint       `gorm:"primaryKey" json:"id"`
	PostID        uint       `gorm:"not null;uniqueIndex" json:"post_id"`
	SectionID     uint       `gorm:"not null;index" json:"section_id"`
	TagID         uint       `gorm:"not null;index" json:"tag_id"`
	NeededCount   int        `gorm:"not null;default:1" json:"needed_count"`
	AcceptedCount int        `gorm:"not null;default:0" json:"accepted_count"`
	RolesJSON     string     `gorm:"type:text;not null" json:"roles_json"`
	Deadline      *time.Time `gorm:"index" json:"deadline"`
	Status        string     `gorm:"size:32;not null;default:'recruiting';index" json:"status"`

	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`

	Post    *Post            `gorm:"foreignKey:PostID" json:"post,omitempty"`
	Section *WaterSection    `gorm:"foreignKey:SectionID" json:"section,omitempty"`
	Tag     *WaterSectionTag `gorm:"foreignKey:TagID" json:"tag,omitempty"`
}

func (WaterTeamRecruitment) TableName() string { return "water_team_recruitments" }

// WaterTeamApplication 组队申请信息
type WaterTeamApplication struct {
	ID            uint `gorm:"primaryKey" json:"id"`
	RecruitmentID uint `gorm:"not null;index;uniqueIndex:idx_recruitment_applicant" json:"recruitment_id"`
	PostID        uint `gorm:"not null;index" json:"post_id"`
	ApplicantID   uint `gorm:"not null;index;uniqueIndex:idx_recruitment_applicant" json:"applicant_id"`
	OwnerID       uint `gorm:"not null;index" json:"owner_id"`

	Message      string `gorm:"size:500;not null" json:"message"`
	Availability string `gorm:"size:200" json:"availability"`
	Status       string `gorm:"size:32;not null;default:'pending';index" json:"status"`

	ReviewedAt *time.Time `json:"reviewed_at"`
	OwnerReply string     `gorm:"size:500" json:"owner_reply"`

	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`

	Recruitment *WaterTeamRecruitment `gorm:"foreignKey:RecruitmentID" json:"recruitment,omitempty"`
	Post        *Post                 `gorm:"foreignKey:PostID" json:"post,omitempty"`
	Applicant   *User                 `gorm:"foreignKey:ApplicantID" json:"applicant,omitempty"`
	Owner       *User                 `gorm:"foreignKey:OwnerID" json:"owner,omitempty"`
}

func (WaterTeamApplication) TableName() string { return "water_team_applications" }

// EffectiveRecruitmentStatus 计算招募信息的有效状态
func EffectiveRecruitmentStatus(recruitment WaterTeamRecruitment, now time.Time) string {
	if recruitment.Status == RecruitmentStatusClosed {
		return RecruitmentStatusClosed
	}
	if recruitment.Deadline != nil && !now.Before(*recruitment.Deadline) {
		return RecruitmentStatusExpired
	}
	if recruitment.AcceptedCount >= recruitment.NeededCount {
		return RecruitmentStatusFull
	}
	return RecruitmentStatusRecruiting
}

// EnsureWaterTeamSchema 确保组队相关数据约束和唯一索引
func EnsureWaterTeamSchema(db *gorm.DB) error {
	// Create partial unique index for single team tag per section
	var count int64
	db.Raw("SELECT count(*) FROM pg_class WHERE relname = 'idx_water_section_single_team_tag'").Count(&count)
	
	// Postgres or SQLite syntax
	// SQLite supports partial indexes since 3.8.0, PostgreSQL since 8.2
	err := db.Exec(`
		CREATE UNIQUE INDEX IF NOT EXISTS idx_water_section_single_team_tag 
		ON water_section_tags(section_id) 
		WHERE content_mode = 'team_recruitment';
	`).Error
	if err != nil {
		return err
	}

	return nil
}

// MigrateLegacyTeamRecruitmentTag 将现有的 competition / team 标签迁移为 team_recruitment 模式
func MigrateLegacyTeamRecruitmentTag(db *gorm.DB) error {
	return db.Exec(`
		UPDATE water_section_tags
		SET content_mode = 'team_recruitment'
		WHERE section_id = (
			SELECT id FROM water_sections WHERE slug = 'competition'
		)
		AND slug = 'team'
		AND (content_mode = '' OR content_mode = 'standard');
	`).Error
}

package models

import (
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"
)

// CampusCalendar 保存一个学年的完整校历 JSON。日期明细保持原子发布，避免跨表发布不一致。
type CampusCalendar struct {
	ID           uint           `gorm:"primaryKey" json:"id"`
	AcademicYear string         `gorm:"size:20;not null;uniqueIndex:idx_campus_calendar_year_version" json:"academic_year"`
	Version      int            `gorm:"not null;uniqueIndex:idx_campus_calendar_year_version" json:"version"`
	Status       string         `gorm:"size:20;not null;index" json:"status"`
	Data         datatypes.JSON `gorm:"type:jsonb;not null" json:"data"`
	SourceName   string         `gorm:"size:255" json:"source_name"`
	SourceHash   string         `gorm:"size:64;index" json:"source_hash"`
	CreatedBy    uint           `gorm:"index" json:"created_by"`
	PublishedAt  *time.Time     `json:"published_at"`
	CreatedAt    time.Time      `json:"created_at"`
	UpdatedAt    time.Time      `json:"updated_at"`
	DeletedAt    gorm.DeletedAt `gorm:"index" json:"-"`
}

func (CampusCalendar) TableName() string { return "campus_calendars" }

// EnsureCampusCalendarIndexes 限制一个学年只能有一个已发布版本。
func EnsureCampusCalendarIndexes(db *gorm.DB) error {
	return db.Exec(`
		CREATE UNIQUE INDEX IF NOT EXISTS idx_campus_calendar_published_year
		ON campus_calendars (academic_year)
		WHERE status = 'published'
	`).Error
}

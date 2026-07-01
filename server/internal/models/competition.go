package models

import (
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"
)

type CompetitionCategory struct {
	ID          uint      `gorm:"primaryKey" json:"id"`
	Name        string    `gorm:"size:100;not null" json:"name"`
	Slug        string    `gorm:"size:80;not null;uniqueIndex" json:"slug"`
	Description string    `gorm:"size:500" json:"description"`
	Icon        string    `gorm:"size:80" json:"icon"`
	SortOrder   int       `gorm:"default:0;index" json:"sort_order"`
	IsActive    bool      `gorm:"default:true;index" json:"is_active"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

func (CompetitionCategory) TableName() string { return "competition_categories" }

type CompetitionEvent struct {
	ID uint `gorm:"primaryKey" json:"id"`

	Title       string `gorm:"size:200;not null;index" json:"title"`
	Subtitle    string `gorm:"size:300" json:"subtitle"`
	Summary     string `gorm:"size:1000" json:"summary"`
	Description string `gorm:"type:text" json:"description"`

	PrimaryCategoryID uint                 `gorm:"index" json:"primary_category_id"`
	PrimaryCategory   *CompetitionCategory `gorm:"foreignKey:PrimaryCategoryID" json:"primary_category,omitempty"`
	Tags              datatypes.JSON       `json:"tags"`

	CompetitionLevel        string `gorm:"size:40;index" json:"competition_level"`
	SchoolRecognitionStatus string `gorm:"size:32;index" json:"school_recognition_status"`
	SchoolRecognitionGrade  string `gorm:"size:16;index" json:"school_recognition_grade"`

	RecommendationLevel  string `gorm:"size:8;index" json:"recommendation_level"`
	ImportanceScore      int    `gorm:"default:0;index" json:"importance_score"`
	RecommendationReason string `gorm:"size:1000" json:"recommendation_reason"`
	IsFeatured           bool   `gorm:"default:false;index" json:"is_featured"`
	IsVerified           bool   `gorm:"default:false;index" json:"is_verified"`

	Organizer         string `gorm:"size:255" json:"organizer"`
	HostUnit          string `gorm:"size:255" json:"host_unit"`
	UndertakeUnit     string `gorm:"size:255" json:"undertake_unit"`
	TargetAudience    string `gorm:"size:500" json:"target_audience"`
	ParticipationType string `gorm:"size:50" json:"participation_type"`
	TeamSizeMin       int    `gorm:"default:0" json:"team_size_min"`
	TeamSizeMax       int    `gorm:"default:0" json:"team_size_max"`

	RegistrationStart *time.Time `gorm:"index" json:"registration_start"`
	RegistrationEnd   *time.Time `gorm:"index" json:"registration_end"`
	EventStart        *time.Time `gorm:"index" json:"event_start"`
	EventEnd          *time.Time `gorm:"index" json:"event_end"`

	RegistrationTimeText string     `gorm:"size:255" json:"registration_time_text"`
	EventTimeText        string     `gorm:"size:255" json:"event_time_text"`
	TimePrecision        string     `gorm:"size:24;default:'unknown';index" json:"time_precision"`
	TimeStatus           string     `gorm:"size:24;default:'pending';index" json:"time_status"`
	TimeNote             string     `gorm:"size:500" json:"time_note"`
	SortMonth            int        `gorm:"default:0;index" json:"sort_month"`
	SortDate             *time.Time `gorm:"index" json:"sort_date"`

	Location       string         `gorm:"size:255" json:"location"`
	IsOnline       bool           `gorm:"default:false;index" json:"is_online"`
	OfficialURL    string         `gorm:"size:500;index" json:"official_url"`
	NoticeURL      string         `gorm:"size:500" json:"notice_url"`
	AttachmentURLs datatypes.JSON `json:"attachment_urls"`

	SourceChannel   string `gorm:"size:50;index" json:"source_channel"`
	SourceNote      string `gorm:"size:1000" json:"source_note"`
	SourceArticleID string `gorm:"size:80;index" json:"source_article_id"`

	Status     string     `gorm:"size:20;default:'active';index" json:"status"`
	Version    int        `gorm:"default:1" json:"version"`
	VerifiedBy uint       `gorm:"index" json:"verified_by"`
	VerifiedAt *time.Time `json:"verified_at"`
	CreatedBy  uint       `gorm:"index" json:"created_by"`
	UpdatedBy  uint       `gorm:"index" json:"updated_by"`
	CreatedAt  time.Time  `json:"created_at"`
	UpdatedAt  time.Time  `json:"updated_at"`
	ArchivedAt *time.Time `json:"archived_at"`
}

func (CompetitionEvent) TableName() string { return "competition_events" }

type CompetitionEventAttachment struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	EventID   uint      `gorm:"not null;index" json:"event_id"`
	FileName  string    `gorm:"size:255" json:"file_name"`
	FileURL   string    `gorm:"size:500" json:"file_url"`
	FileType  string    `gorm:"size:80" json:"file_type"`
	FileSize  int64     `json:"file_size"`
	SortOrder int       `gorm:"default:0" json:"sort_order"`
	CreatedAt time.Time `json:"created_at"`
}

func (CompetitionEventAttachment) TableName() string { return "competition_event_attachments" }

type UserCompetitionCalendar struct {
	ID          uint      `gorm:"primaryKey" json:"id"`
	UserID      uint      `gorm:"not null;uniqueIndex" json:"user_id"`
	Title       string    `gorm:"size:100" json:"title"`
	Description string    `gorm:"size:500" json:"description"`
	Visibility  string    `gorm:"size:20;default:'private'" json:"visibility"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

func (UserCompetitionCalendar) TableName() string { return "user_competition_calendars" }

type UserCompetitionCalendarItem struct {
	ID                      uint           `gorm:"primaryKey" json:"id"`
	CalendarID              uint           `gorm:"not null;index" json:"calendar_id"`
	UserID                  uint           `gorm:"not null;index" json:"user_id"`
	Title                   string         `gorm:"size:200;not null;index" json:"title"`
	Summary                 string         `gorm:"size:1000" json:"summary"`
	Description             string         `gorm:"type:text" json:"description"`
	CategoryID              uint           `gorm:"index" json:"category_id"`
	CategoryName            string         `gorm:"size:100" json:"category_name"`
	Tags                    datatypes.JSON `json:"tags"`
	Level                   string         `gorm:"size:40;index" json:"level"`
	CompetitionLevel        string         `gorm:"size:40;index" json:"competition_level"`
	SchoolRecognitionStatus string         `gorm:"size:32;index" json:"school_recognition_status"`
	SchoolRecognitionGrade  string         `gorm:"size:16;index" json:"school_recognition_grade"`
	RecommendationLevel     string         `gorm:"size:8;index" json:"recommendation_level"`
	ImportanceScore         int            `gorm:"default:0;index" json:"importance_score"`
	Organizer               string         `gorm:"size:255" json:"organizer"`
	TargetAudience          string         `gorm:"size:500" json:"target_audience"`
	OfficialURL             string         `gorm:"size:500;index" json:"official_url"`
	NoticeURL               string         `gorm:"size:500" json:"notice_url"`
	Location                string         `gorm:"size:255" json:"location"`
	IsOnline                bool           `gorm:"default:false;index" json:"is_online"`
	RegistrationStart       *time.Time     `gorm:"index" json:"registration_start"`
	RegistrationEnd         *time.Time     `gorm:"index" json:"registration_end"`
	EventStart              *time.Time     `gorm:"index" json:"event_start"`
	EventEnd                *time.Time     `gorm:"index" json:"event_end"`
	RegistrationStartText   string         `gorm:"size:255" json:"registration_start_text"`
	RegistrationEndText     string         `gorm:"size:255" json:"registration_end_text"`
	EventStartText          string         `gorm:"size:255" json:"event_start_text"`
	EventEndText            string         `gorm:"size:255" json:"event_end_text"`
	RegistrationTimeText    string         `gorm:"size:255" json:"registration_time_text"`
	EventTimeText           string         `gorm:"size:255" json:"event_time_text"`
	TimePrecision           string         `gorm:"size:24;default:'unknown';index" json:"time_precision"`
	TimeStatus              string         `gorm:"size:24;default:'pending';index" json:"time_status"`
	TimeNote                string         `gorm:"size:500" json:"time_note"`
	SortMonth               int            `gorm:"default:0;index" json:"sort_month"`
	SortDate                *time.Time     `gorm:"index" json:"sort_date"`
	PlanStatus              string         `gorm:"size:24;default:'watching';index" json:"plan_status"`
	UserDeadline            *time.Time     `gorm:"index" json:"user_deadline"`
	SourceType              string         `gorm:"size:20;index" json:"source_type"`
	SourceEventID           *uint          `gorm:"index" json:"source_event_id"`
	SourceShareCode         string         `gorm:"size:32;index" json:"source_share_code"`
	SourceSnapshotID        *uint          `gorm:"index" json:"source_snapshot_id"`
	IsCustomModified        bool           `gorm:"default:false" json:"is_custom_modified"`
	OriginalHash            string         `gorm:"size:64;index" json:"original_hash"`
	UserNote                string         `gorm:"size:1000" json:"user_note"`
	IsPinned                bool           `gorm:"default:false;index" json:"is_pinned"`
	DisplayOrder            int            `gorm:"default:0;index" json:"display_order"`
	CreatedAt               time.Time      `json:"created_at"`
	UpdatedAt               time.Time      `json:"updated_at"`
	DeletedAt               gorm.DeletedAt `gorm:"index" json:"-"`
}

func (UserCompetitionCalendarItem) TableName() string { return "user_competition_calendar_items" }

type CalendarShareSnapshot struct {
	ID             uint           `gorm:"primaryKey" json:"id"`
	ShareCode      string         `gorm:"size:32;not null;uniqueIndex" json:"share_code"`
	SnapshotHash   string         `gorm:"size:64;index" json:"snapshot_hash"`
	SnapshotJSON   datatypes.JSON `json:"snapshot_json"`
	Version        int            `gorm:"default:1" json:"version"`
	Title          string         `gorm:"size:100" json:"title"`
	Description    string         `gorm:"size:500" json:"description"`
	ItemCount      int            `gorm:"default:0" json:"item_count"`
	CreatedBy      uint           `gorm:"not null;index" json:"created_by"`
	CreatedAt      time.Time      `json:"created_at"`
	ExpiresAt      *time.Time     `gorm:"index" json:"expires_at"`
	Status         string         `gorm:"size:20;default:'active';index" json:"status"`
	DisabledReason string         `gorm:"size:500" json:"disabled_reason"`
	ReportCount    int            `gorm:"default:0" json:"report_count"`
	ImportCount    int            `gorm:"default:0" json:"import_count"`
	LastImportedAt *time.Time     `json:"last_imported_at"`
}

func (CalendarShareSnapshot) TableName() string { return "calendar_share_snapshots" }

type CalendarShareSnapshotItem struct {
	ID          uint           `gorm:"primaryKey" json:"id"`
	SnapshotID  uint           `gorm:"not null;index" json:"snapshot_id"`
	ShareCode   string         `gorm:"size:32;index" json:"share_code"`
	ItemJSON    datatypes.JSON `json:"item_json"`
	Title       string         `gorm:"size:200;index" json:"title"`
	OfficialURL string         `gorm:"size:500;index" json:"official_url"`
	SortDate    *time.Time     `gorm:"index" json:"sort_date"`
	CreatedAt   time.Time      `json:"created_at"`
}

func (CalendarShareSnapshotItem) TableName() string { return "calendar_share_snapshot_items" }

type CompetitionImportBatch struct {
	ID                uint           `gorm:"primaryKey" json:"id"`
	BatchID           string         `gorm:"size:64;not null;uniqueIndex" json:"batch_id"`
	UserID            uint           `gorm:"not null;index" json:"user_id"`
	SourceType        string         `gorm:"size:32;index" json:"source_type"`
	RawPayload        datatypes.JSON `json:"-"`
	NormalizedPayload datatypes.JSON `json:"normalized_payload"`
	PayloadSize       int            `json:"payload_size"`
	ErrorSummary      datatypes.JSON `json:"error_summary"`
	Status            string         `gorm:"size:20;default:'previewed';index" json:"status"`
	ErrorCount        int            `gorm:"default:0" json:"error_count"`
	ItemCount         int            `gorm:"default:0" json:"item_count"`
	ValidCount        int            `gorm:"default:0" json:"valid_count"`
	CreatedAt         time.Time      `json:"created_at"`
	ExpiresAt         time.Time      `gorm:"index" json:"expires_at"`
	CommittedAt       *time.Time     `json:"committed_at"`
}

func (CompetitionImportBatch) TableName() string { return "competition_import_batches" }

func EnsureCompetitionCategories(db *gorm.DB) error {
	categories := []CompetitionCategory{
		{Name: "创新创业与综合挑战", Slug: "innovation_startup", Icon: "rocket_launch", SortOrder: 10, IsActive: true},
		{Name: "计算机与人工智能", Slug: "computer_ai", Icon: "code", SortOrder: 20, IsActive: true},
		{Name: "电子信息与通信", Slug: "electronic_info", Icon: "memory", SortOrder: 30, IsActive: true},
		{Name: "智能制造与交通车辆", Slug: "smart_manufacturing_vehicle", Icon: "precision_manufacturing", SortOrder: 40, IsActive: true},
		{Name: "艺术设计与数字创意", Slug: "art_design", Icon: "palette", SortOrder: 50, IsActive: true},
		{Name: "经管商科与电商", Slug: "business_economics", Icon: "business_center", SortOrder: 60, IsActive: true},
		{Name: "数理建模与基础学科", Slug: "math_science", Icon: "calculate", SortOrder: 70, IsActive: true},
		{Name: "材料化工与环境能源", Slug: "materials_chem_env", Icon: "science", SortOrder: 80, IsActive: true},
		{Name: "外语人文与表达", Slug: "language_humanities", Icon: "translate", SortOrder: 90, IsActive: true},
		{Name: "国防安全与其他", Slug: "defense_security_other", Icon: "shield", SortOrder: 100, IsActive: true},
	}
	for _, category := range categories {
		var existing CompetitionCategory
		if err := db.Where("slug = ?", category.Slug).First(&existing).Error; err != nil {
			if err == gorm.ErrRecordNotFound {
				if err := db.Create(&category).Error; err != nil {
					return err
				}
				continue
			}
			return err
		}
		updates := map[string]interface{}{
			"name": category.Name, "icon": category.Icon, "sort_order": category.SortOrder, "is_active": true,
		}
		if err := db.Model(&existing).Updates(updates).Error; err != nil {
			return err
		}
	}
	return nil
}

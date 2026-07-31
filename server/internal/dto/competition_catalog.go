package dto

import "encoding/json"

const CompetitionCatalogSchemaVersion = "sylulive-competition-catalog/2.2"

// CompetitionCatalogDocument 是生产服务唯一接受的目录导入格式。
type CompetitionCatalogDocument struct {
	SchemaVersion         string                     `json:"schema_version"`
	DatasetVersion        string                     `json:"dataset_version"`
	PackageHash           string                     `json:"package_hash"`
	PublishStatus         string                     `json:"publish_status"`
	ProductionLoadAllowed bool                       `json:"production_load_allowed"`
	ItemCount             int                        `json:"item_count"`
	SourceFilename        string                     `json:"source_filename,omitempty"`
	Items                 []CompetitionCatalogRecord `json:"items"`
}

// CompetitionCatalogRecord 同时承载公开事实和目录治理字段。
// RecordHash 不参与自身哈希，服务端会按其余字段固定顺序重新计算。
type CompetitionCatalogRecord struct {
	CompetitionID                 string          `json:"competition_id"`
	ParentCompetitionID           string          `json:"parent_competition_id,omitempty"`
	RecordHash                    string          `json:"record_hash"`
	CatalogOrder                  int             `json:"catalog_order"`
	Title                         string          `json:"title"`
	Subtitle                      string          `json:"subtitle,omitempty"`
	Summary                       string          `json:"summary,omitempty"`
	Description                   string          `json:"description,omitempty"`
	PrimaryCategorySlug           string          `json:"primary_category_slug,omitempty"`
	Tags                          []string        `json:"tags"`
	CompetitionLevel              string          `json:"competition_level,omitempty"`
	SchoolRecognitionStatus       string          `json:"school_recognition_status,omitempty"`
	SchoolRecognitionGrade        string          `json:"school_recognition_grade,omitempty"`
	CompetitionRating             string          `json:"competition_rating,omitempty"`
	ImportanceScore               int             `json:"importance_score"`
	Organizer                     string          `json:"organizer,omitempty"`
	HostUnit                      string          `json:"host_unit,omitempty"`
	TargetAudience                string          `json:"target_audience,omitempty"`
	EligibleEntryYears            []string        `json:"eligible_entry_years"`
	EligibleColleges              []string        `json:"eligible_colleges"`
	EligibleMajors                []string        `json:"eligible_majors"`
	ParticipationType             string          `json:"participation_type,omitempty"`
	TeamSizeMin                   int             `json:"team_size_min"`
	TeamSizeMax                   int             `json:"team_size_max"`
	RegistrationStart             string          `json:"registration_start,omitempty"`
	RegistrationEnd               string          `json:"registration_end,omitempty"`
	EventStart                    string          `json:"event_start,omitempty"`
	EventEnd                      string          `json:"event_end,omitempty"`
	RegistrationTimeText          string          `json:"registration_time_text,omitempty"`
	EventTimeText                 string          `json:"event_time_text,omitempty"`
	TimePrecision                 string          `json:"time_precision"`
	TimeStatus                    string          `json:"time_status"`
	TimeNote                      string          `json:"time_note,omitempty"`
	SortMonth                     int             `json:"sort_month"`
	Location                      string          `json:"location,omitempty"`
	IsOnline                      bool            `json:"is_online"`
	OfficialURL                   string          `json:"official_url,omitempty"`
	NoticeURL                     string          `json:"notice_url,omitempty"`
	SourceChannel                 string          `json:"source_channel,omitempty"`
	SourceNote                    string          `json:"source_note,omitempty"`
	Status                        string          `json:"status"`
	ManualRatingReasonPublic      string          `json:"manual_rating_reason_public,omitempty"`
	MajorFitSummaryPublic         string          `json:"major_fit_summary_public,omitempty"`
	EvidenceSummaryPublic         string          `json:"evidence_summary_public,omitempty"`
	EvidenceSubgrade              string          `json:"evidence_subgrade,omitempty"`
	RiskTags                      []string        `json:"risk_tags"`
	SearchDisplayAllowed          bool            `json:"search_display_allowed"`
	CandidatePoolAllowed          bool            `json:"candidate_pool_allowed"`
	PersonalizedRankingAllowed    bool            `json:"personalized_ranking_allowed"`
	StrongRecommendationEligible  bool            `json:"strong_recommendation_eligible"`
	RecommendationPermissionLevel string          `json:"recommendation_permission_level"`
	AIMode                        string          `json:"ai_mode"`
	BlockerCodes                  []string        `json:"blocker_codes"`
	Extra                         json.RawMessage `json:"-"`
}

type CompetitionCatalogValidationIssue struct {
	Level         string `json:"level"`
	Code          string `json:"code"`
	CompetitionID string `json:"competition_id,omitempty"`
	Field         string `json:"field,omitempty"`
	Message       string `json:"message"`
}

type CompetitionCatalogValidationResult struct {
	Status               string                              `json:"status"`
	ComputedPackageHash  string                              `json:"computed_package_hash"`
	ComputedRecordHashes map[string]string                   `json:"computed_record_hashes"`
	Issues               []CompetitionCatalogValidationIssue `json:"issues"`
}

package dto

import "time"

// CompetitionCategoryDTO 是学生端可见的最小赛事分类投影。
type CompetitionCategoryDTO struct {
	ID   uint   `json:"id"`
	Name string `json:"name"`
	Slug string `json:"slug"`
	Icon string `json:"icon,omitempty"`
}

// CompetitionPublicDTO 只包含学生目录所需的公开字段。
type CompetitionPublicDTO struct {
	ID                      uint                    `json:"id"`
	CompetitionID           string                  `json:"competition_id"`
	Title                   string                  `json:"title"`
	Summary                 string                  `json:"summary"`
	Category                *CompetitionCategoryDTO `json:"primary_category,omitempty"`
	Tags                    []string                `json:"tags"`
	CompetitionLevel        string                  `json:"competition_level"`
	SchoolRecognitionStatus string                  `json:"school_recognition_status"`
	SchoolRecognitionGrade  string                  `json:"school_recognition_grade"`
	CompetitionRating       string                  `json:"competition_rating"`
	RegistrationTimeText    string                  `json:"registration_time_text"`
	EventTimeText           string                  `json:"event_time_text"`
	TimeStatus              string                  `json:"time_status"`
	ParticipationType       string                  `json:"participation_type"`
	TeamSizeMin             int                     `json:"team_size_min"`
	TeamSizeMax             int                     `json:"team_size_max"`
	OfficialURL             string                  `json:"official_url"`
	RegistrationStart       *time.Time              `json:"registration_start,omitempty"`
	RegistrationEnd         *time.Time              `json:"registration_end,omitempty"`
	EventStart              *time.Time              `json:"event_start,omitempty"`
	EventEnd                *time.Time              `json:"event_end,omitempty"`
	UpdatedAt               time.Time               `json:"updated_at"`
}

// MatchDimensionsDTO 使用离散状态表达匹配依据，不向学生暴露伪精确总分。
type MatchDimensionsDTO struct {
	Eligibility string `json:"eligibility"`
	Major       string `json:"major"`
	College     string `json:"college"`
	Grade       string `json:"grade"`
	Goal        string `json:"goal"`
	Direction   string `json:"direction"`
	Skill       string `json:"skill"`
	Role        string `json:"role"`
	Time        string `json:"time"`
	Training    string `json:"training"`
}

// RecommendationGateDTO 是可公开的目录权限门，不包含内部阻断码。
type RecommendationGateDTO struct {
	CandidatePoolAllowed         bool   `json:"candidate_pool_allowed"`
	PersonalizedRankingAllowed   bool   `json:"personalized_ranking_allowed"`
	StrongRecommendationEligible bool   `json:"strong_recommendation_eligible"`
	PermissionLevel              string `json:"recommendation_permission_level"`
	AIMode                       string `json:"ai_mode"`
}

// CompetitionCandidateDTO 是候选接口逐赛事响应。
type CompetitionCandidateDTO struct {
	CompetitionPublicDTO
	ImportanceScore  int                   `json:"-"`
	CatalogOrder     int                   `json:"-"`
	GroupKey         string                `json:"group_key"`
	RuleOrder        int                   `json:"rule_order"`
	MatchDimensions  MatchDimensionsDTO    `json:"match_dimensions"`
	CoreReason       string                `json:"core_reason"`
	Cautions         []string              `json:"cautions"`
	Questions        []string              `json:"questions_to_confirm"`
	EvidenceSubgrade string                `json:"evidence_subgrade"`
	DatasetVersion   string                `json:"dataset_version"`
	RecordHash       string                `json:"record_hash"`
	Gates            RecommendationGateDTO `json:"gates"`
}

type CompetitionCandidateGroupDTO struct {
	Key   string                    `json:"key"`
	Label string                    `json:"label"`
	Count int                       `json:"count"`
	Items []CompetitionCandidateDTO `json:"items"`
}

type CompetitionCatalogSummaryDTO struct {
	DatasetVersion             string `json:"dataset_version"`
	PackageHash                string `json:"package_hash"`
	Mode                       string `json:"mode"`
	PersonalizedRankingAllowed bool   `json:"personalized_ranking_allowed"`
}

type CompetitionCandidateResultDTO struct {
	ProfileReady         bool                           `json:"profile_ready"`
	PreferenceConfigured bool                           `json:"preference_configured"`
	Catalog              CompetitionCatalogSummaryDTO   `json:"catalog"`
	Groups               []CompetitionCandidateGroupDTO `json:"groups"`
	Total                int                            `json:"total"`
	Page                 int                            `json:"page"`
	PageSize             int                            `json:"page_size"`
}

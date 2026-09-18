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
	ImportanceScore       int                `json:"-"`
	CatalogOrder          int                `json:"-"`
	GroupKey              string             `json:"group_key"`
	RuleOrder             int                `json:"rule_order"`
	HasPendingInformation bool               `json:"has_pending_information"`
	MatchDimensions       MatchDimensionsDTO `json:"match_dimensions"`
	CoreReason            string             `json:"core_reason"`
	Cautions              []string           `json:"cautions"`
	Questions             []string           `json:"questions_to_confirm"`
	EvidenceSubgrade      string             `json:"evidence_subgrade"`
	DatasetVersion        string             `json:"dataset_version"`

	// 以下为匹配结果。按既有约定「不向学生暴露伪精确总分」，
	// 只暴露离散档位、离散依据与命中的专业簇，分值仅供内部排序。
	MatchTier       string   `json:"match_tier,omitempty"`
	MatchBasis      string   `json:"match_basis,omitempty"`
	MatchedClusters []string `json:"matched_clusters,omitempty"`
	MatchScore      int      `json:"-"`

	// 以下字段只用于 Go 到 Hy3 的受控上下文，不进入学生候选响应。
	RecordHash         string                `json:"-"`
	Gates              RecommendationGateDTO `json:"-"`
	ManualRatingReason string                `json:"-"`
	MajorFitSummary    string                `json:"-"`
	EvidenceSummary    string                `json:"-"`
	RiskTags           []string              `json:"-"`
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
	// HasMore 由服务端判定，替代客户端按 total 与去重条数推断（旧实现会提前停止加载）。
	HasMore bool `json:"has_more"`
	// ReasonCode 说明结果为空或受限的原因，避免前端只能显示空白。
	ReasonCode string `json:"reason_code,omitempty"`
	// AlgorithmVersion 随响应返回，便于埋点按算法版本切分指标。
	AlgorithmVersion string `json:"algorithm_version,omitempty"`
}

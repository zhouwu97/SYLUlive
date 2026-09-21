package models

import (
	"time"

	"gorm.io/datatypes"
)

// 竞赛候选链路的信号类型。与客户端埋点一一对应，写入前必须过白名单校验。
const (
	CompetitionSignalFitTabExposure = "fit_tab_exposure"
	CompetitionSignalImpression     = "candidate_impression"
	CompetitionSignalMatchReason    = "match_reason_open"
	CompetitionSignalClick          = "candidate_click"
	CompetitionSignalCalendarAdd    = "calendar_add"
)

// CompetitionCandidateSignals 是竞赛候选链路的曝光与交互明细。
//
// 形状对齐 Feed 的 feed_impressions：明细按 algorithm_version 切分，
// 便于按版本对比新旧算法（这也是「先 shadow 再灰度」能给出判据的前提）。
// 之所以要先有这张表才做客户端埋点：没有曝光分母就无法算 CTR，
// 也无法区分「没推荐到」与「推荐了但没人点」——两者要修的东西完全不同。
type CompetitionCandidateSignals struct {
	ID uint `gorm:"primaryKey" json:"id"`

	UserID uint   `gorm:"index:idx_competition_signal_user,priority:1;not null" json:"user_id"`
	Kind   string `gorm:"size:24;index:idx_competition_signal_user,priority:2;not null" json:"kind"`

	// SessionKey 是同一次「适合我」浏览的会话标识，用于曝光去重：
	// 同一会话内滚动导致同一条赛事反复进入视口，只应记一次曝光。
	SessionKey string `gorm:"size:64;index:idx_competition_signal_session,priority:1" json:"session_key"`

	EventID       uint   `gorm:"index;not null" json:"event_id"`
	CompetitionID string `gorm:"size:64" json:"competition_id"`

	AlgorithmVersion string `gorm:"size:32;index" json:"algorithm_version"`
	MatchTier        string `gorm:"size:16" json:"match_tier"`
	MatchBasis       string `gorm:"size:24" json:"match_basis"`
	// Position 是 0 基展示位次，用于位置偏差分析（越靠前点击率越高是位置效应，不是质量）。
	Position int `gorm:"not null;default:0" json:"position"`

	CreatedAt time.Time `gorm:"index:idx_competition_signal_user,priority:3" json:"created_at"`
}

func (CompetitionCandidateSignals) TableName() string {
	return "competition_candidate_signals"
}

// CompetitionRankTrace 竞赛候选排序追踪（采样写入，用于离线调参与解释）。
//
// 与 FeedRankTrace 同构：保存「这一位为什么排在这里」的分项明细。
// 只采样写入（比例由配置控制），且采样判定必须确定性——禁止在请求路径引入随机数。
type CompetitionRankTrace struct {
	ID uint `gorm:"primaryKey" json:"id"`

	UserID uint   `gorm:"index:idx_competition_rank_trace_user,priority:1;not null" json:"user_id"`
	RunKey string `gorm:"size:64;index:idx_competition_rank_trace_user,priority:2" json:"run_key"`

	EventID       uint   `gorm:"not null" json:"event_id"`
	CompetitionID string `gorm:"size:64" json:"competition_id"`
	Position      int    `gorm:"not null;default:0" json:"position"`

	MatchScore int  `gorm:"not null;default:0" json:"match_score"`
	Rankable   bool `gorm:"not null;default:false" json:"rankable"`

	// Breakdown 是六项分项明细（major / preference / goal / time / value / penalty），
	// 可复算是硬要求：给定同一画像与同一目录记录，六项与总分必须逐字节一致。
	Breakdown datatypes.JSON `json:"breakdown"`

	MatchTier        string `gorm:"size:16" json:"match_tier"`
	MatchBasis       string `gorm:"size:24" json:"match_basis"`
	AlgorithmVersion string `gorm:"size:32" json:"algorithm_version"`

	CreatedAt time.Time `json:"created_at"`
}

func (CompetitionRankTrace) TableName() string {
	return "competition_rank_traces"
}

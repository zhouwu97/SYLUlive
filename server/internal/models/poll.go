package models

import "time"

const (
	PollCategoryCampusLife = "campus_life"
	PollCategoryStudy      = "study"
	PollCategoryActivity   = "activity"
	PollCategoryOther      = "other"

	PollSelectionSingle   = "single"
	PollSelectionMultiple = "multiple"

	PollResultsAlways    = "always"
	PollResultsAfterVote = "after_vote"
	PollResultsAfterEnd  = "after_end"

	PollStatusActive  = "active"
	PollStatusClosed  = "closed"
	PollStatusDeleted = "deleted"
)

// Poll 保存投票规则及聚合计数，通用帖子内容仍由 Post 承载。
type Poll struct {
	ID                uint       `gorm:"primaryKey" json:"id"`
	PostID            uint       `gorm:"not null;uniqueIndex" json:"post_id"`
	Category          string     `gorm:"size:32;not null;index" json:"category"`
	SelectionMode     string     `gorm:"size:16;not null" json:"selection_mode"`
	MaxChoices        int        `gorm:"not null;default:1" json:"max_choices"`
	ResultsVisibility string     `gorm:"size:24;not null" json:"results_visibility"`
	AllowChange       bool       `gorm:"not null;default:true" json:"allow_change"`
	IsAnonymous       bool       `gorm:"not null;default:true" json:"is_anonymous"`
	Status            string     `gorm:"size:16;not null;default:'active';index" json:"status"`
	EndsAt            time.Time  `gorm:"not null;index" json:"ends_at"`
	ClosedAt          *time.Time `json:"closed_at"`
	ClosedBy          uint       `gorm:"index" json:"closed_by"`
	ParticipantCount  int        `gorm:"not null;default:0" json:"participant_count"`
	ChoiceCount       int        `gorm:"not null;default:0" json:"choice_count"`
	LastVoteAt        *time.Time `gorm:"index" json:"last_vote_at"`
	CreatedAt         time.Time  `json:"created_at"`
	UpdatedAt         time.Time  `json:"updated_at"`

	Post    Post         `gorm:"foreignKey:PostID" json:"-"`
	Options []PollOption `gorm:"foreignKey:PollID" json:"options,omitempty"`
}

// PollOption 保存投票选项与冗余票数，票数可由选票明细重新计算。
type PollOption struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	PollID    uint      `gorm:"not null;index;uniqueIndex:idx_poll_options_poll_sort,priority:1" json:"poll_id"`
	Text      string    `gorm:"size:80;not null" json:"text"`
	SortOrder int       `gorm:"not null;uniqueIndex:idx_poll_options_poll_sort,priority:2" json:"sort_order"`
	VoteCount int       `gorm:"not null;default:0" json:"vote_count"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// PollBallot 表示一个用户对一个投票的最终选票。
type PollBallot struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	PollID    uint      `gorm:"not null;uniqueIndex:idx_poll_ballots_poll_user,priority:1" json:"poll_id"`
	UserID    uint      `gorm:"not null;uniqueIndex:idx_poll_ballots_poll_user,priority:2;index" json:"user_id"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`

	Choices []PollBallotChoice `gorm:"foreignKey:BallotID" json:"choices,omitempty"`
}

// PollBallotChoice 保存选票与选项的多对多关系。
type PollBallotChoice struct {
	ID       uint `gorm:"primaryKey" json:"id"`
	BallotID uint `gorm:"not null;uniqueIndex:idx_poll_ballot_choices_ballot_option,priority:1" json:"ballot_id"`
	OptionID uint `gorm:"not null;uniqueIndex:idx_poll_ballot_choices_ballot_option,priority:2;index" json:"option_id"`
}

type PollOptionDTO struct {
	ID        uint     `json:"id"`
	Text      string   `json:"text"`
	SortOrder int      `json:"sort_order"`
	VoteCount *int     `json:"vote_count,omitempty"`
	Ratio     *float64 `json:"ratio,omitempty"`
	IsChosen  bool     `json:"is_chosen"`
}

// PollSummaryDTO 是普通客户端可见的投票摘要，隐藏结果时票数指针保持 nil。
type PollSummaryDTO struct {
	ID                uint            `json:"id"`
	PostID            uint            `json:"post_id"`
	Category          string          `json:"category"`
	SelectionMode     string          `json:"selection_mode"`
	MaxChoices        int             `json:"max_choices"`
	ResultsVisibility string          `json:"results_visibility"`
	AllowChange       bool            `json:"allow_change"`
	Status            string          `json:"status"`
	EffectiveStatus   string          `json:"effective_status"`
	EndsAt            time.Time       `json:"ends_at"`
	RemainingSeconds  int64           `json:"remaining_seconds"`
	ParticipantCount  int             `json:"participant_count"`
	ChoiceCount       *int            `json:"choice_count,omitempty"`
	HasVoted          bool            `json:"has_voted"`
	ResultsVisible    bool            `json:"results_visible"`
	CanVote           bool            `json:"can_vote"`
	CanChange         bool            `json:"can_change"`
	IsOwner           bool            `json:"is_owner"`
	Options           []PollOptionDTO `json:"options"`
}

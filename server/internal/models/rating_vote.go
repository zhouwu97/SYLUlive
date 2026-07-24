package models

import "time"

// TeacherRatingVote 教师评价投票
type TeacherRatingVote struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	RatingID  uint      `gorm:"index;not null;uniqueIndex:uq_teacher_rating_vote" json:"rating_id"`
	UserID    uint      `gorm:"index;not null;uniqueIndex:uq_teacher_rating_vote" json:"user_id"`
	VoteType  string    `gorm:"size:10;not null;check:vote_type IN ('up', 'down')" json:"vote_type"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// MajorRatingVote 专业评价投票
type MajorRatingVote struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	RatingID  uint      `gorm:"index;not null;uniqueIndex:uq_major_rating_vote" json:"rating_id"`
	UserID    uint      `gorm:"index;not null;uniqueIndex:uq_major_rating_vote" json:"user_id"`
	VoteType  string    `gorm:"size:10;not null;check:vote_type IN ('up', 'down')" json:"vote_type"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

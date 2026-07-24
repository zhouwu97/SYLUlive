package services

import (
	"errors"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// VoteResult 投票结果
type VoteResult struct {
	HelpfulCount   int
	UnhelpfulCount int
	MyVote         string
}

// ToggleRatingVote 处理评价的赞/踩投票事务
func ToggleRatingVote(
	db *gorm.DB,
	ratingType string, // "teacher" or "major"
	ratingID uint,
	userID uint,
	vote string, // "up", "down", or "none"
) (*VoteResult, error) {
	if vote != "up" && vote != "down" && vote != "none" {
		return nil, errors.New("无效的投票类型")
	}

	var result VoteResult
	err := db.Transaction(func(tx *gorm.DB) error {
		var (
			tableName      string
			voteTableName  string
			ratingIDColumn string
		)

		if ratingType == "teacher" {
			tableName = "teacher_ratings"
			voteTableName = "teacher_rating_votes"
			ratingIDColumn = "rating_id"
		} else if ratingType == "major" {
			tableName = "major_ratings"
			voteTableName = "major_rating_votes"
			ratingIDColumn = "rating_id"
		} else {
			return errors.New("未知的评价类型")
		}

		// 1. 锁住评价记录
		var rating struct {
			ID             uint
			UserID         uint
			HelpfulCount   int
			UnhelpfulCount int
			Status         string
		}

		if err := tx.Table(tableName).
			Clauses(clause.Locking{Strength: "UPDATE"}).
			Select("id, user_id, helpful_count, unhelpful_count, status").
			Where("id = ? AND deleted_at IS NULL", ratingID).
			First(&rating).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return errors.New("评价不存在或已删除")
			}
			return err
		}

		if rating.Status != "normal" {
			return errors.New("无法对该状态的评价进行投票")
		}

		if rating.UserID == userID {
			return errors.New("不能给自己的评价投票")
		}

		// 2. 查找当前用户的投票记录
		var currentVote string
		var voteID uint
		row := tx.Table(voteTableName).
			Select("id, vote_type").
			Where(ratingIDColumn+" = ? AND user_id = ?", ratingID, userID).
			Row()
		err := row.Scan(&voteID, &currentVote)
		if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) && err.Error() != "sql: no rows in result set" {
			return err
		}

		// 3. 计算投票变化
		helpfulDiff := 0
		unhelpfulDiff := 0
		newVote := vote

		if currentVote == "up" {
			if vote == "up" || vote == "none" {
				newVote = "none"
				helpfulDiff = -1
			} else if vote == "down" {
				newVote = "down"
				helpfulDiff = -1
				unhelpfulDiff = 1
			}
		} else if currentVote == "down" {
			if vote == "down" || vote == "none" {
				newVote = "none"
				unhelpfulDiff = -1
			} else if vote == "up" {
				newVote = "up"
				unhelpfulDiff = -1
				helpfulDiff = 1
			}
		} else { // currentVote == ""
			if vote == "up" {
				newVote = "up"
				helpfulDiff = 1
			} else if vote == "down" {
				newVote = "down"
				unhelpfulDiff = 1
			} else {
				newVote = "none"
			}
		}

		// 防止出现负数 (理论上不会，但安全起见)
		rating.HelpfulCount += helpfulDiff
		rating.UnhelpfulCount += unhelpfulDiff
		if rating.HelpfulCount < 0 {
			rating.HelpfulCount = 0
		}
		if rating.UnhelpfulCount < 0 {
			rating.UnhelpfulCount = 0
		}

		// 4. 更新评价记录计数
		if helpfulDiff != 0 || unhelpfulDiff != 0 {
			if err := tx.Table(tableName).
				Where("id = ?", ratingID).
				Updates(map[string]interface{}{
					"helpful_count":   rating.HelpfulCount,
					"unhelpful_count": rating.UnhelpfulCount,
				}).Error; err != nil {
				return err
			}
		}

		// 5. 更新投票记录表
		if newVote == "none" {
			if voteID != 0 {
				if err := tx.Table(voteTableName).Where("id = ?", voteID).Delete(nil).Error; err != nil {
					return err
				}
			}
		} else {
			if voteID != 0 {
				if err := tx.Table(voteTableName).Where("id = ?", voteID).Update("vote_type", newVote).Error; err != nil {
					return err
				}
			} else {
				if err := tx.Table(voteTableName).Create(map[string]interface{}{
					ratingIDColumn: ratingID,
					"user_id":      userID,
					"vote_type":    newVote,
				}).Error; err != nil {
					return err
				}
			}
		}

		result.HelpfulCount = rating.HelpfulCount
		result.UnhelpfulCount = rating.UnhelpfulCount
		result.MyVote = newVote

		return nil
	})

	if err != nil {
		return nil, err
	}
	return &result, nil
}

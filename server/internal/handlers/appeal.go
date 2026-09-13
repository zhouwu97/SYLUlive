package handlers

import (
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// AppealHandler 申诉处理器
type AppealHandler struct {
	db *gorm.DB
}

// NewAppealHandler 创建申诉处理器
func NewAppealHandler(db *gorm.DB) *AppealHandler {
	return &AppealHandler{db: db}
}

// CreateAppeal 创建申诉
func (h *AppealHandler) Create(c *gin.Context) {
	userID, _ := c.Get("user_id")
	postIDStr := c.Param("id")
	postID, err := strconv.ParseUint(postIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子ID"})
		return
	}

	// 检查帖子是否已被删除
	var post models.Post
	if err := h.db.First(&post, postID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}

	if post.Status != models.PostStatusDeleted {
		c.JSON(http.StatusBadRequest, gin.H{"error": "帖子未被删除，无需申诉"})
		return
	}

	// 检查是否是帖子作者
	if post.AuthorID != userID.(uint) {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		return
	}

	var input struct {
		Reason string `json:"appellant_reason"`
	}
	if err := c.ShouldBindJSON(&input); err != nil && !errors.Is(err, io.EOF) {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	input.Reason = strings.TrimSpace(input.Reason)
	if input.Reason == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请填写申诉理由"})
		return
	}

	// 检查是否已有待处理的申诉
	var existingAppeal models.Appeal
	if h.db.Where("post_id = ? AND status = ?", postID, models.AppealStatusPending).First(&existingAppeal).Error == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "已有待处理的申诉"})
		return
	}

	// 查找处理此举报的管理员（需要admin_reason）
	var report models.Report
	if h.db.Where("target_type = ? AND target_id = ? AND status = ?", "post", postID, models.ReportStatusHandled).First(&report).Error != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "未找到处理此帖子的管理员记录"})
		return
	}

	if report.HandlerID == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "此举报尚未被处理"})
		return
	}

	deadline := time.Now().Add(72 * time.Hour)
	appeal := models.Appeal{
		ReportID:        &report.ID,
		PostID:          uint(postID),
		AppellantID:     userID.(uint),
		AdminID:         *report.HandlerID,
		AppellantReason: input.Reason,
		AdminReason:     report.DeleteReason,
		Status:          models.AppealStatusPending,
		VotingDeadline:  &deadline,
	}

	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Create(&appeal).Error; err != nil {
			return err
		}
		return NewAppealHandler(tx).selectJury(appeal.ID, post.AuthorID, appeal.AdminID)
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建申诉失败"})
		return
	}

	if err := h.db.Preload("Appellant").Preload("Admin").Preload("Post").First(&appeal, appeal.ID).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取申诉失败"})
		return
	}
	c.JSON(http.StatusCreated, appealResponse(appeal))
}

// selectJury 随机选择陪审员
func (h *AppealHandler) selectJury(appealID, appellantID, adminID uint) error {
	excluded := []uint{appellantID, adminID}
	var appeal models.Appeal
	if err := h.db.First(&appeal, appealID).Error; err != nil {
		return err
	}
	if appeal.ReportID != nil {
		var report models.Report
		if err := h.db.First(&report, *appeal.ReportID).Error; err == nil {
			excluded = append(excluded, report.ReporterID)
		}
	}
	var candidates []models.User
	// 只从高诚信普通用户中抽取，排除申诉人、原处理管理员与原举报人。
	if err := h.db.Where("id NOT IN ? AND report_count = 0 AND credit_score > 90 AND role = ?", excluded, models.RoleUser).
		Find(&candidates).Error; err != nil {
		return err
	}

	const minimumJury = 5
	if len(candidates) < minimumJury {
		now := time.Now()
		return h.db.Model(&models.Appeal{}).Where("id = ?", appealID).Updates(map[string]interface{}{
			"status":         models.AppealStatusReview,
			"required_votes": minimumJury,
			"result":         "合格陪审员不足，转人工复核",
			"closed_reason":  "insufficient_jury",
			"closed_at":      &now,
		}).Error
	}

	// 目标陪审池为 7 人，有效法定人数固定为 5 人。
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	rng.Shuffle(len(candidates), func(i, j int) { candidates[i], candidates[j] = candidates[j], candidates[i] })

	count := 7
	if len(candidates) < count {
		count = len(candidates)
	}

	for i := 0; i < count; i++ {
		vote := models.AppealVote{
			AppealID: appealID,
			VoterID:  candidates[i].ID,
			Vote:     "",
		}
		if err := h.db.Create(&vote).Error; err != nil {
			return err
		}
	}
	return h.db.Model(&models.Appeal{}).Where("id = ?", appealID).Update("required_votes", minimumJury).Error
}

// GetList 获取申诉列表
func (h *AppealHandler) GetList(c *gin.Context) {
	userID := c.GetUint("user_id")
	role, _ := c.Get("role")
	status := c.Query("status")

	query := h.db.Model(&models.Appeal{}).Preload("Appellant").Preload("Admin").Preload("Post")
	if role != string(models.RoleSuperAdmin) {
		query = query.Where("appellant_id = ? OR admin_id = ? OR id IN (?)", userID, userID,
			h.db.Model(&models.AppealVote{}).Select("appeal_id").Where("voter_id = ?", userID))
	}
	if status != "" {
		query = query.Where("status = ?", status)
	}
	query = query.Order("created_at DESC")

	var appeals []models.Appeal
	if err := query.Find(&appeals).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取申诉列表失败"})
		return
	}

	responses := make([]models.AppealResponse, 0, len(appeals))
	for _, appeal := range appeals {
		responses = append(responses, h.appealResponseForUser(appeal, userID))
	}
	c.JSON(http.StatusOK, responses)
}

// GetOne 获取申诉详情
func (h *AppealHandler) GetOne(c *gin.Context) {
	userID, _ := c.Get("user_id")
	appealIDStr := c.Param("id")
	appealID, err := strconv.ParseUint(appealIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的申诉ID"})
		return
	}

	var appeal models.Appeal
	if err := h.db.Preload("Appellant").Preload("Admin").Preload("Post").First(&appeal, appealID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "申诉不存在"})
		return
	}
	role, _ := c.Get("role")
	allowed := role == string(models.RoleSuperAdmin) || appeal.AppellantID == userID.(uint) || appeal.AdminID == userID.(uint)
	if !allowed {
		var assigned int64
		if err := h.db.Model(&models.AppealVote{}).Where("appeal_id = ? AND voter_id = ?", appeal.ID, userID).Count(&assigned).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "检查申诉权限失败"})
			return
		}
		allowed = assigned > 0
	}
	if !allowed {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权查看此申诉"})
		return
	}

	// 进行中的案件只返回当前用户自己的投票状态；陪审员身份与投票内容必须保密。
	var votes []models.AppealVote
	if err := h.db.Where("appeal_id = ?", appealID).Preload("Voter").Find(&votes).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取投票数据失败"})
		return
	}

	// 检查当前用户是否已投票
	hasVoted := false
	for _, v := range votes {
		if v.VoterID == userID.(uint) && v.Vote != "" {
			hasVoted = true
			break
		}
	}

	response := h.appealResponseForUser(appeal, userID.(uint))
	response.HasVoted = hasVoted
	for _, vote := range votes {
		if vote.VoterID == userID.(uint) && vote.Vote != "" {
			response.MyVote = vote.Vote
		}
		if appeal.Status != models.AppealStatusPending {
			if vote.Vote == "support" {
				response.SupportCount++
			} else if vote.Vote == "oppose" {
				response.OpposeCount++
			}
		}
	}
	response.CastCount = response.SupportCount + response.OpposeCount
	c.JSON(http.StatusOK, gin.H{
		"appeal":    response,
		"votes":     []models.AppealVoteResponse{},
		"has_voted": hasVoted,
	})
}

// VoteInput 投票输入
type VoteInput struct {
	Vote    string `json:"vote" binding:"required"` // support/oppose
	Comment string `json:"comment"`
}

// Vote 投票
func (h *AppealHandler) Vote(c *gin.Context) {
	userID, _ := c.Get("user_id")
	appealIDStr := c.Param("id")
	appealID, err := strconv.ParseUint(appealIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的申诉ID"})
		return
	}

	var input VoteInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	if input.Vote != "support" && input.Vote != "oppose" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的投票选项"})
		return
	}

	err = h.db.Transaction(func(tx *gorm.DB) error {
		// 检查申诉是否存在并锁定
		var appeal models.Appeal
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&appeal, appealID).Error; err != nil {
			return err
		}

		if appeal.Status != models.AppealStatusPending {
			return fmt.Errorf("申诉已处理完毕，不能再投票")
		}

		// 检查是否是有效的陪审员
		var vote models.AppealVote
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("appeal_id = ? AND voter_id = ?", appealID, userID).First(&vote).Error; err != nil {
			return fmt.Errorf("您不是此申诉的陪审员")
		}

		if vote.Vote != "" {
			return fmt.Errorf("您已经投过票了")
		}

		if err := tx.Model(&vote).Updates(map[string]interface{}{
			"vote":    input.Vote,
			"comment": input.Comment,
		}).Error; err != nil {
			return err
		}

		// 达到法定票数即可结案，不再永久等待所有陪审员。
		var votes []models.AppealVote
		if err := tx.Where("appeal_id = ?", appealID).Find(&votes).Error; err != nil {
			return err
		}

		castCount := 0
		supportCount := 0
		opposeCount := 0
		for _, v := range votes {
			if v.Vote == "support" {
				supportCount++
				castCount++
			} else if v.Vote == "oppose" {
				opposeCount++
				castCount++
			}
		}

		requiredVotes := appeal.RequiredVotes
		if requiredVotes <= 0 {
			requiredVotes = len(votes)
		}
		deadlineReached := appeal.VotingDeadline != nil && !time.Now().Before(*appeal.VotingDeadline)
		if castCount < requiredVotes && !deadlineReached {
			return nil
		}
		if supportCount == opposeCount {
			now := time.Now()
			appeal.Status = models.AppealStatusReview
			appeal.Result = fmt.Sprintf("支持票: %d, 反对票: %d, 平票，转人工复核", supportCount, opposeCount)
			appeal.ClosedAt = &now
			appeal.ClosedReason = "tie_review_required"
			return tx.Save(&appeal).Error
		}

		now := time.Now()
		if supportCount > opposeCount {
			appeal.Status = models.AppealStatusPass
			appeal.Result = fmt.Sprintf("支持票: %d, 反对票: %d, 申诉成功", supportCount, opposeCount)
			if err := tx.Model(&models.Post{}).Where("id = ?", appeal.PostID).Update("status", models.PostStatusNormal).Error; err != nil {
				return err
			}

			// 管理员经验-3（不低于0）
			var admin models.User
			if err := tx.First(&admin, appeal.AdminID).Error; err == nil {
				newExp := admin.AdminExp - 3
				if newExp < 0 {
					newExp = 0
				}
				if err := tx.Model(&admin).Update("admin_exp", newExp).Error; err != nil {
					return err
				}
			}
		} else {
			appeal.Status = models.AppealStatusReject
			appeal.Result = fmt.Sprintf("支持票: %d, 反对票: %d, 申诉失败", supportCount, opposeCount)

			// 管理员经验+5
			if err := tx.Model(&models.User{}).Where("id = ?", appeal.AdminID).Update("admin_exp", gorm.Expr("admin_exp + 5")).Error; err != nil {
				return err
			}
		}

		appeal.ClosedAt = &now
		if deadlineReached {
			appeal.ClosedReason = "voting_deadline_reached"
		} else {
			appeal.ClosedReason = "required_votes_reached"
		}
		return tx.Save(&appeal).Error
	})

	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "投票成功"})
}

func appealUserResponse(user models.User) models.PublicAppealUserResponse {
	return models.PublicAppealUserResponse{ID: user.ID, Nickname: user.Nickname, Avatar: user.Avatar}
}

func appealResponse(appeal models.Appeal) models.AppealResponse {
	return models.AppealResponse{
		ID: appeal.ID, ReportID: appeal.ReportID, PostID: appeal.PostID,
		AppellantReason: appeal.AppellantReason, AdminReason: appeal.AdminReason,
		Status: appeal.Status, Result: appeal.Result, VotingDeadline: appeal.VotingDeadline,
		RequiredVotes: appeal.RequiredVotes, ClosedReason: appeal.ClosedReason,
		CreatedAt: appeal.CreatedAt, ClosedAt: appeal.ClosedAt,
		Appellant: appealUserResponse(appeal.Appellant), Admin: appealUserResponse(appeal.Admin),
		Post: models.AppealPostResponse{ID: appeal.Post.ID, Title: appeal.Post.Title, Content: appeal.Post.Content, Status: appeal.Post.Status},
	}
}

// appealResponseForUser 只把当前请求者确实有权知道的投票状态写入 DTO。
func (h *AppealHandler) appealResponseForUser(appeal models.Appeal, userID uint) models.AppealResponse {
	response := appealResponse(appeal)
	response.IsAppellant = appeal.AppellantID == userID
	response.IsAdmin = appeal.AdminID == userID
	var assigned models.AppealVote
	if err := h.db.Where("appeal_id = ? AND voter_id = ?", appeal.ID, userID).First(&assigned).Error; err == nil {
		response.CanVote = appeal.Status == models.AppealStatusPending && assigned.Vote == ""
		response.MyVote = assigned.Vote
		response.HasVoted = assigned.Vote != ""
	}
	return response
}

func appealVoteResponse(vote models.AppealVote) models.AppealVoteResponse {
	return models.AppealVoteResponse{
		ID: vote.ID, AppealID: vote.AppealID, Vote: vote.Vote, Comment: vote.Comment,
		CreatedAt: vote.CreatedAt, Voter: appealUserResponse(vote.Voter),
	}
}

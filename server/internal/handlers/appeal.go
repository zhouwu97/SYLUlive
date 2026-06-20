package handlers

import (
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"strconv"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
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

	appeal := models.Appeal{
		PostID:      uint(postID),
		AppellantID: userID.(uint),
		AdminID:     *report.HandlerID,
		AdminReason: report.DeleteReason,
		Status:      models.AppealStatusPending,
	}

	if err := h.db.Create(&appeal).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建申诉失败"})
		return
	}

	// 随机选择10名高诚信非当事人陪审员
	h.selectJury(appeal.ID, post.AuthorID)

	c.JSON(http.StatusCreated, appeal)
}

// selectJury 随机选择陪审员
func (h *AppealHandler) selectJury(appealID uint, excludeUserID uint) {
	var candidates []models.User
	// 近90天举报数为0且诚信度>90%的普通用户（排除管理员和超管）
	if err := h.db.Where("id != ? AND report_count = 0 AND credit_score > 90 AND role = ?", excludeUserID, models.RoleUser).
		Find(&candidates).Error; err != nil {
		log.Printf("[DB_ERROR] selectJury Find candidates failed: %v", err)
	}

	if len(candidates) < 10 {
		// 如果候选人不足，随机选择
		if err := h.db.Where("id != ?", excludeUserID).Limit(10).Find(&candidates).Error; err != nil {
			log.Printf("[DB_ERROR] selectJury Find fallback candidates failed: %v", err)
		}
	}

	// 如果还是没有候选人（系统里只有发帖人和超级管理员等情况），则自动分配超级管理员
	if len(candidates) == 0 {
		if err := h.db.Where("role = ?", models.RoleSuperAdmin).First(&candidates).Error; err != nil {
			log.Printf("[DB_WARN] selectJury failed to find fallback super_admin: %v", err)
		}
	}

	// 随机选择最多10人
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	rng.Shuffle(len(candidates), func(i, j int) { candidates[i], candidates[j] = candidates[j], candidates[i] })

	count := 10
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
			log.Printf("[DB_ERROR] Failed to create appeal vote: %v", err)
			return
		}
	}
}

// GetList 获取申诉列表
func (h *AppealHandler) GetList(c *gin.Context) {
	status := c.Query("status")

	query := h.db.Model(&models.Appeal{}).Preload("Appellant").Preload("Admin").Preload("Post")
	if status != "" {
		query = query.Where("status = ?", status)
	}
	query.Order("created_at DESC")

	var appeals []models.Appeal
	if err := query.Find(&appeals).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取申诉列表失败"})
		return
	}

	c.JSON(http.StatusOK, appeals)
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

	// 获取投票信息
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

	c.JSON(http.StatusOK, gin.H{
		"appeal":    appeal,
		"votes":     votes,
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
		if err := tx.First(&appeal, appealID).Error; err != nil {
			return err
		}

		if appeal.Status != models.AppealStatusPending {
			return fmt.Errorf("申诉已处理完毕，不能再投票")
		}

		// 检查是否是有效的陪审员
		var vote models.AppealVote
		if err := tx.Where("appeal_id = ? AND voter_id = ?", appealID, userID).First(&vote).Error; err != nil {
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

		// 检查是否所有陪审员都已投票
		var votes []models.AppealVote
		if err := tx.Where("appeal_id = ?", appealID).Find(&votes).Error; err != nil {
			return err
		}

		allVoted := true
		supportCount := 0
		opposeCount := 0
		for _, v := range votes {
			if v.Vote == "" {
				allVoted = false
				break
			}
			if v.Vote == "support" {
				supportCount++
			} else if v.Vote == "oppose" {
				opposeCount++
			}
		}

		if !allVoted {
			return nil
		}

		now := time.Now()
		if supportCount > opposeCount {
			appeal.Status = models.AppealStatusPass
			appeal.Result = fmt.Sprintf("支持票: %d, 反对票: %d, 申诉成功", supportCount, opposeCount)
			tx.Model(&models.Post{}).Where("id = ?", appeal.PostID).Update("status", models.PostStatusNormal)

			// 管理员经验-3（不低于0）
			var admin models.User
			if err := tx.First(&admin, appeal.AdminID).Error; err == nil {
				newExp := admin.AdminExp - 3
				if newExp < 0 {
					newExp = 0
				}
				tx.Model(&admin).Update("admin_exp", newExp)
			}
		} else {
			appeal.Status = models.AppealStatusReject
			appeal.Result = fmt.Sprintf("支持票: %d, 反对票: %d, 申诉失败", supportCount, opposeCount)

			// 管理员经验+5
			tx.Model(&models.User{}).Where("id = ?", appeal.AdminID).Update("admin_exp", gorm.Expr("admin_exp + 5"))
		}

		appeal.ClosedAt = &now
		return tx.Save(&appeal).Error
	})

	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "投票成功"})
}

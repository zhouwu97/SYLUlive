package handlers

import (
	"fmt"
	"math/rand"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
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
	// 近90天举报数为0且诚信度>90%的用户
	h.db.Where("id != ? AND report_count = 0 AND credit_score > 90", excludeUserID).
		Find(&candidates)

	if len(candidates) < 10 {
		// 如果候选人不足，随机选择
		h.db.Where("id != ?", excludeUserID).Limit(10).Find(&candidates)
	}

	// 随机选择最多10人
	rand.Seed(time.Now().UnixNano())
	rand.Shuffle(len(candidates), func(i, j int) { candidates[i], candidates[j] = candidates[j], candidates[i] })

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
		h.db.Create(&vote)
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
	query.Find(&appeals)

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
	h.db.Where("appeal_id = ?", appealID).Preload("Voter").Find(&votes)

	// 检查当前用户是否已投票
	hasVoted := false
	for _, v := range votes {
		if v.VoterID == userID.(uint) && v.Vote != "" {
			hasVoted = true
			break
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"appeal":     appeal,
		"votes":      votes,
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

// 获取投票类型(support/oppose) - 从URL路径获取
	voteType := c.Param("vote")
	if voteType != "support" && voteType != "oppose" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的投票选项"})
		return
	}

	var input VoteInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 检查是否是有效的陪审员
	var vote models.AppealVote
	if err := h.db.Where("appeal_id = ? AND voter_id = ?", appealID, userID).First(&vote).Error; err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": "您不是此申诉的陪审员"})
		return
	}

	if vote.Vote != "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "您已经投过票了"})
		return
	}

	h.db.Model(&vote).Updates(map[string]interface{}{
		"vote":    voteType,
		"comment": input.Comment,
	})

	// 检查是否所有陪审员都已投票
	h.checkAndCloseAppeal(uint(appealID))

	c.JSON(http.StatusOK, gin.H{"message": "投票成功"})
}

// checkAndCloseAppeal 检查并关闭申诉
func (h *AppealHandler) checkAndCloseAppeal(appealID uint) {
	var votes []models.AppealVote
	h.db.Where("appeal_id = ?", appealID).Find(&votes)

	allVoted := true
	for _, v := range votes {
		if v.Vote == "" {
			allVoted = false
			break
		}
	}

	if !allVoted {
		return
	}

	// 统计票数
	supportCount := 0
	opposeCount := 0
	for _, v := range votes {
		if v.Vote == "support" {
			supportCount++
		} else if v.Vote == "oppose" {
			opposeCount++
		}
	}

	var appeal models.Appeal
	h.db.First(&appeal, appealID)
	now := time.Now()

	if supportCount > opposeCount {
		// 申诉成功，恢复帖子
		appeal.Status = models.AppealStatusPass
		appeal.Result = fmt.Sprintf("支持票: %d, 反对票: %d, 申诉成功", supportCount, opposeCount)
		h.db.Model(&models.Post{}).Where("id = ?", appeal.PostID).Update("status", models.PostStatusNormal)

		// 管理员经验-3
		h.db.Model(&models.User{}).Where("id = ?", appeal.AdminID).Update("admin_exp", gorm.Expr("admin_exp - 3"))
	} else {
		// 申诉失败
		appeal.Status = models.AppealStatusReject
		appeal.Result = fmt.Sprintf("支持票: %d, 反对票: %d, 申诉失败", supportCount, opposeCount)

		// 管理员经验+5
		h.db.Model(&models.User{}).Where("id = ?", appeal.AdminID).Update("admin_exp", gorm.Expr("admin_exp + 5"))
	}

	appeal.ClosedAt = &now
	h.db.Save(&appeal)
}
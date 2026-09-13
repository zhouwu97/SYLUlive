package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// AppealHandler 申诉处理器
type AppealHandler struct {
	db        *gorm.DB
	uploadDir string
}

var errOriginalAdminCannotReview = errors.New("原处理管理员不能复核自己的治理案件")

// NewAppealHandler 创建申诉处理器
func NewAppealHandler(db *gorm.DB) *AppealHandler {
	return &AppealHandler{db: db}
}

func (h *AppealHandler) SetUploadDir(uploadDir string) {
	h.uploadDir = uploadDir
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
	if h.db.Where("target_type = ? AND target_id = ? AND status = ?", "post", postID, models.ReportStatusHandled).Order("handled_at DESC").First(&report).Error != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "未找到处理此帖子的管理员记录"})
		return
	}

	if report.HandlerID == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "此举报尚未被处理"})
		return
	}

	deadline := time.Now().Add(72 * time.Hour)
	appeal := models.Appeal{
		ReportID:             &report.ID,
		TargetType:           "post",
		TargetID:             uint(postID),
		PostID:               uint(postID),
		AppellantID:          userID.(uint),
		AdminID:              *report.HandlerID,
		AppellantReason:      input.Reason,
		EvidenceSnapshot:     report.TargetSnapshot,
		OriginalPostStatus:   originalPostStatus(report.TargetSnapshot, post.Status),
		OriginalTargetStatus: string(originalPostStatus(report.TargetSnapshot, post.Status)),
		AdminReason:          report.DeleteReason,
		Status:               models.AppealStatusPending,
		VotingDeadline:       &deadline,
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
	_ = CreateAppealNotification(h.db, appeal.AppellantID, appeal.ID,
		models.NotificationTypeAppealCreated, "你的申诉已创建，公众法庭将开始复核。", fmt.Sprintf("appeal-created:%d", appeal.ID))

	if err := h.db.Preload("Appellant").Preload("Admin").Preload("Post").First(&appeal, appeal.ID).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取申诉失败"})
		return
	}
	c.JSON(http.StatusCreated, appealResponse(appeal))
}

// CreateByReport 以具体治理决定创建申诉，避免按帖子匹配到历史举报记录。
func (h *AppealHandler) CreateByReport(c *gin.Context) {
	userID := c.GetUint("user_id")
	reportID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的举报ID"})
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
	var report models.Report
	if err := h.db.First(&report, reportID).Error; err != nil || report.Status != models.ReportStatusHandled || (report.TargetType != "post" && report.TargetType != "reply") || report.HandlerID == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该治理决定暂不可申诉"})
		return
	}
	var post models.Post
	var targetAuthorID uint
	var originalTargetStatus string
	if report.TargetType == "post" {
		if err := h.db.First(&post, report.TargetID).Error; err != nil {
			c.JSON(http.StatusNotFound, gin.H{"error": "被治理内容不存在"})
			return
		}
		targetAuthorID = post.AuthorID
		originalTargetStatus = string(originalPostStatus(report.TargetSnapshot, post.Status))
	} else {
		var reply models.Reply
		if err := h.db.First(&reply, report.TargetID).Error; err != nil {
			c.JSON(http.StatusNotFound, gin.H{"error": "被治理评论不存在"})
			return
		}
		if err := h.db.First(&post, reply.PostID).Error; err != nil {
			c.JSON(http.StatusNotFound, gin.H{"error": "评论所属帖子不存在"})
			return
		}
		targetAuthorID = reply.AuthorID
		originalTargetStatus = originalSnapshotStatus(report.TargetSnapshot, string(reply.Status))
	}
	if targetAuthorID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "只有被治理内容的作者可以申诉"})
		return
	}
	var existing models.Appeal
	if err := h.db.Where("report_id = ?", report.ID).First(&existing).Error; err == nil {
		c.JSON(http.StatusConflict, gin.H{"error": "该治理决定已经提交过申诉"})
		return
	}
	deadline := time.Now().Add(72 * time.Hour)
	appeal := models.Appeal{ReportID: &report.ID, TargetType: report.TargetType, TargetID: report.TargetID, PostID: post.ID, AppellantID: userID, AdminID: *report.HandlerID, AppellantReason: input.Reason, EvidenceSnapshot: report.TargetSnapshot, OriginalPostStatus: originalPostStatus(report.TargetSnapshot, post.Status), OriginalTargetStatus: originalTargetStatus, AdminReason: report.DeleteReason, Status: models.AppealStatusPending, VotingDeadline: &deadline}
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Create(&appeal).Error; err != nil {
			return err
		}
		return NewAppealHandler(tx).selectJury(appeal.ID, targetAuthorID, appeal.AdminID)
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建申诉失败"})
		return
	}
	_ = CreateAppealNotification(h.db, appeal.AppellantID, appeal.ID, models.NotificationTypeAppealCreated, "你的申诉已创建，公众法庭将开始复核。", fmt.Sprintf("appeal-created:%d", appeal.ID))
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
		return h.db.Model(&models.Appeal{}).Where("id = ?", appealID).Updates(map[string]interface{}{
			"status":         models.AppealStatusReview,
			"required_votes": minimumJury,
			"result":         "合格陪审员不足，转人工复核",
			"closed_reason":  "insufficient_jury",
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
		if err := CreateAppealNotification(h.db, candidates[i].ID, appealID,
			models.NotificationTypeAppealJury, "你已被随机选为公众法庭陪审员，请在截止前完成评议。", fmt.Sprintf("appeal-jury:%d:%d", appealID, candidates[i].ID)); err != nil {
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

// GetPublicList 只公开已结案且有明确结果的匿名公示。
func (h *AppealHandler) GetPublicList(c *gin.Context) {
	var appeals []models.Appeal
	if err := h.db.Where("status IN ?", []models.AppealStatus{models.AppealStatusPass, models.AppealStatusReject}).
		Preload("Post").Order("closed_at DESC").Limit(50).Find(&appeals).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取结案公示失败"})
		return
	}
	public := make([]models.PublicAppealResponse, 0, len(appeals))
	for _, appeal := range appeals {
		var counts struct {
			SupportCount int
			OpposeCount  int
		}
		h.db.Model(&models.AppealVote{}).Select("COALESCE(SUM(CASE WHEN vote = 'support' THEN 1 ELSE 0 END), 0) AS support_count, COALESCE(SUM(CASE WHEN vote = 'oppose' THEN 1 ELSE 0 END), 0) AS oppose_count").Where("appeal_id = ?", appeal.ID).Scan(&counts)
		source := "jury"
		if appeal.ClosedReason == "manual_review" {
			source = "manual_review"
		}
		public = append(public, models.PublicAppealResponse{ID: appeal.ID, PostTitle: "社区内容治理复核", Status: appeal.Status, Result: publicAppealResult(appeal.Status), ResolutionSource: source, ClosedReason: appeal.ClosedReason, ClosedAt: appeal.ClosedAt, CreatedAt: appeal.CreatedAt, SupportCount: counts.SupportCount, OpposeCount: counts.OpposeCount})
	}
	c.JSON(http.StatusOK, public)
}

func publicAppealResult(status models.AppealStatus) string {
	if status == models.AppealStatusPass {
		return "申诉通过"
	}
	return "维持原处理"
}

// GetEvidenceFile 仅向案件参与者返回被冻结快照中的图片，避免直接暴露已删除内容的公开 URL。
func (h *AppealHandler) GetEvidenceFile(c *gin.Context) {
	appealID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.Status(http.StatusNotFound)
		return
	}
	fileID, err := strconv.ParseUint(c.Param("file_id"), 10, 64)
	if err != nil || h.uploadDir == "" {
		c.Status(http.StatusNotFound)
		return
	}
	var appeal models.Appeal
	if err := h.db.First(&appeal, appealID).Error; err != nil || !h.canViewEvidence(c, appeal) {
		c.Status(http.StatusNotFound)
		return
	}
	var snapshot struct {
		ImageFileIDs []uint `json:"image_file_ids"`
	}
	if json.Unmarshal([]byte(appeal.EvidenceSnapshot), &snapshot) != nil {
		c.Status(http.StatusNotFound)
		return
	}
	allowed := false
	for _, id := range snapshot.ImageFileIDs {
		if id == uint(fileID) {
			allowed = true
			break
		}
	}
	if !allowed {
		c.Status(http.StatusNotFound)
		return
	}
	var file models.File
	if err := h.db.First(&file, fileID).Error; err != nil {
		c.Status(http.StatusNotFound)
		return
	}
	path, err := services.ResolveUploadPath(h.uploadDir, file.Path)
	if err != nil {
		c.Status(http.StatusNotFound)
		return
	}
	c.Header("Cache-Control", "private, no-store")
	c.Header("Content-Type", file.MimeType)
	c.File(path)
}

func (h *AppealHandler) canViewEvidence(c *gin.Context, appeal models.Appeal) bool {
	userID := c.GetUint("user_id")
	if userID == appeal.AppellantID || userID == appeal.AdminID || (appeal.ReviewedByID != nil && userID == *appeal.ReviewedByID) {
		return true
	}
	if role, _ := c.Get("role"); role == string(models.RoleSuperAdmin) || (role == string(models.RoleAdmin) && appeal.Status == models.AppealStatusReview) {
		return true
	}
	var count int64
	h.db.Model(&models.AppealVote{}).Where("appeal_id = ? AND voter_id = ?", appeal.ID, userID).Count(&count)
	return count > 0
}

// AdminGetReviewList 获取平票、陪审人数不足等需要人工介入的案件。
func (h *AppealHandler) AdminGetReviewList(c *gin.Context) {
	userID := c.GetUint("user_id")
	var appeals []models.Appeal
	if err := h.db.Where("status = ? AND admin_id <> ?", models.AppealStatusReview, userID).
		Preload("Appellant").Preload("Admin").Preload("Post").Order("created_at ASC").Find(&appeals).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取待复核案件失败"})
		return
	}
	responses := make([]models.AppealResponse, 0, len(appeals))
	for _, appeal := range appeals {
		responses = append(responses, h.appealResponseForUser(appeal, userID))
	}
	c.JSON(http.StatusOK, responses)
}

// AdminResolveReview 由管理员对 review_required 案件作最终决定。
func (h *AppealHandler) AdminResolveReview(c *gin.Context) {
	appealID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的申诉ID"})
		return
	}
	var input struct {
		Decision string `json:"decision"`
		Reason   string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&input); err != nil || (input.Decision != "pass" && input.Decision != "reject") {
		c.JSON(http.StatusBadRequest, gin.H{"error": "decision 必须是 pass 或 reject"})
		return
	}
	input.Reason = strings.TrimSpace(input.Reason)
	if input.Reason == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请填写人工复核理由"})
		return
	}
	var appeal models.Appeal
	reviewerID := c.GetUint("user_id")
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&appeal, appealID).Error; err != nil {
			return err
		}
		if appeal.Status != models.AppealStatusReview {
			return fmt.Errorf("该案件不在待人工复核状态")
		}
		if appeal.AdminID == reviewerID {
			return errOriginalAdminCannotReview
		}
		now := time.Now()
		appeal.ReviewedByID = &reviewerID
		appeal.ReviewReason = input.Reason
		appeal.ReviewedAt = &now
		appeal.Status = models.AppealStatus(input.Decision)
		appeal.Result = input.Reason
		appeal.ClosedAt = &now
		appeal.ClosedReason = "manual_review"
		if input.Decision == "pass" {
			if err := applyAppealPass(tx, appeal); err != nil {
				return err
			}
			if err := tx.Model(&models.User{}).Where("id = ?", appeal.AdminID).
				Update("admin_exp", gorm.Expr("CASE WHEN admin_exp >= 3 THEN admin_exp - 3 ELSE 0 END")).Error; err != nil {
				return err
			}
		} else if err := tx.Model(&models.User{}).Where("id = ?", appeal.AdminID).
			Update("admin_exp", gorm.Expr("admin_exp + 5")).Error; err != nil {
			return err
		}
		if err := tx.Create(&models.AdminActionLog{
			AdminID: reviewerID, Action: "review_appeal", TargetType: "appeal", TargetID: appeal.ID,
			Detail: fmt.Sprintf("人工复核申诉：决定=%s，理由=%s，原治理管理员=%d", input.Decision, input.Reason, appeal.AdminID),
		}).Error; err != nil {
			return err
		}
		return tx.Save(&appeal).Error
	}); err != nil {
		if errors.Is(err, errOriginalAdminCannotReview) {
			c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	message := "人工复核已完成，请查看公众法庭案件结果。"
	_ = CreateAppealNotification(h.db, appeal.AppellantID, appeal.ID, models.NotificationTypeAppealResult, message, fmt.Sprintf("appeal-result:%d:appellant", appeal.ID))
	_ = CreateAppealNotification(h.db, appeal.AdminID, appeal.ID, models.NotificationTypeAppealResult, message, fmt.Sprintf("appeal-result:%d:admin", appeal.ID))
	var jury []models.AppealVote
	if h.db.Where("appeal_id = ? AND recused = ?", appeal.ID, false).Find(&jury).Error == nil {
		for _, vote := range jury {
			_ = CreateAppealNotification(h.db, vote.VoterID, appeal.ID, models.NotificationTypeAppealResult,
				"你参与的公众法庭案件已完成人工复核，请查看最终结果。", fmt.Sprintf("appeal-result:%d:jury:%d", appeal.ID, vote.VoterID))
		}
	}
	c.JSON(http.StatusOK, gin.H{"message": "人工复核已完成", "appeal": appealResponse(appeal)})
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

		if vote.Recused || vote.Vote != "" {
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
		if requiredVotes < 5 {
			requiredVotes = 5
		}
		deadlineReached := appeal.VotingDeadline != nil && !time.Now().Before(*appeal.VotingDeadline)
		if castCount < requiredVotes && !deadlineReached {
			return nil
		}
		if castCount < requiredVotes {
			appeal.Status = models.AppealStatusReview
			appeal.Result = fmt.Sprintf("仅收到 %d 票，未达到法定人数 %d，转人工复核", castCount, requiredVotes)
			appeal.ClosedReason = "insufficient_votes"
			return tx.Save(&appeal).Error
		}
		if supportCount == opposeCount {
			appeal.Status = models.AppealStatusReview
			appeal.Result = fmt.Sprintf("支持票: %d, 反对票: %d, 平票，转人工复核", supportCount, opposeCount)
			appeal.ClosedReason = "tie_review_required"
			return tx.Save(&appeal).Error
		}

		now := time.Now()
		if supportCount > opposeCount {
			appeal.Status = models.AppealStatusPass
			appeal.Result = fmt.Sprintf("支持票: %d, 反对票: %d, 申诉成功", supportCount, opposeCount)
			if err := applyAppealPass(tx, appeal); err != nil {
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
	var closedAppeal models.Appeal
	if h.db.Select("id", "appellant_id", "admin_id", "status").First(&closedAppeal, appealID).Error == nil && closedAppeal.Status != models.AppealStatusPending {
		message := "公众法庭案件已结案，请查看复核结果。"
		notificationType := models.NotificationTypeAppealResult
		notificationKey := "appeal-result"
		if closedAppeal.Status == models.AppealStatusReview {
			message = "公众法庭案件需要人工复核，请等待管理员处理。"
			notificationType = models.NotificationTypeAppealReviewRequired
			notificationKey = "appeal-review-required"
		}
		_ = CreateAppealNotification(h.db, closedAppeal.AppellantID, closedAppeal.ID, notificationType, message, fmt.Sprintf("%s:%d:appellant", notificationKey, closedAppeal.ID))
		_ = CreateAppealNotification(h.db, closedAppeal.AdminID, closedAppeal.ID, notificationType, message, fmt.Sprintf("%s:%d:admin", notificationKey, closedAppeal.ID))
		if closedAppeal.Status == models.AppealStatusPass || closedAppeal.Status == models.AppealStatusReject {
			var jury []models.AppealVote
			if h.db.Where("appeal_id = ? AND recused = ?", appealID, false).Find(&jury).Error == nil {
				for _, assigned := range jury {
					_ = CreateAppealNotification(h.db, assigned.VoterID, uint(appealID), models.NotificationTypeAppealResult,
						message, fmt.Sprintf("appeal-result:%d:jury:%d", appealID, assigned.VoterID))
				}
			}
		}
	}

	c.JSON(http.StatusOK, gin.H{"message": "投票成功"})
}

// Recuse 允许陪审员在投票前申请回避，回避不会暴露给其他陪审员。
func (h *AppealHandler) Recuse(c *gin.Context) {
	userID := c.GetUint("user_id")
	appealID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的申诉ID"})
		return
	}
	var input struct {
		Reason string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请说明回避原因"})
		return
	}
	input.Reason = strings.TrimSpace(input.Reason)
	if input.Reason == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请说明回避原因"})
		return
	}
	var vote models.AppealVote
	var appeal models.Appeal
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&appeal, appealID).Error; err != nil {
			return err
		}
		if appeal.Status != models.AppealStatusPending || (appeal.VotingDeadline != nil && !time.Now().Before(*appeal.VotingDeadline)) {
			return fmt.Errorf("案件已结束，当前不能申请回避")
		}
		if err := tx.Where("appeal_id = ? AND voter_id = ?", appealID, userID).First(&vote).Error; err != nil {
			return err
		}
		if vote.Vote != "" || vote.Recused {
			return fmt.Errorf("当前状态不能申请回避")
		}
		return tx.Model(&vote).Updates(map[string]interface{}{"recused": true, "recuse_reason": input.Reason}).Error
	}); err != nil {
		if strings.Contains(err.Error(), "案件已结束") || strings.Contains(err.Error(), "当前状态") {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusForbidden, gin.H{"error": "你不是本案陪审员"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已申请回避"})
}

func appealUserResponse(user models.User) models.PublicAppealUserResponse {
	return models.PublicAppealUserResponse{ID: user.ID, Nickname: user.Nickname, Avatar: user.Avatar}
}

func appealResponse(appeal models.Appeal) models.AppealResponse {
	return models.AppealResponse{
		ID: appeal.ID, ReportID: appeal.ReportID, TargetType: appeal.TargetType, TargetID: appeal.TargetID, PostID: appeal.PostID,
		AppellantReason: appeal.AppellantReason, EvidenceSnapshot: appeal.EvidenceSnapshot,
		OriginalPostStatus: appeal.OriginalPostStatus, OriginalTargetStatus: appeal.OriginalTargetStatus,
		AdminReason: appeal.AdminReason,
		Status:      appeal.Status, Result: appeal.Result, VotingDeadline: appeal.VotingDeadline,
		RequiredVotes: appeal.RequiredVotes, ClosedReason: appeal.ClosedReason,
		CreatedAt: appeal.CreatedAt, ClosedAt: appeal.ClosedAt,
		ReviewedByID: appeal.ReviewedByID, ReviewReason: appeal.ReviewReason, ReviewedAt: appeal.ReviewedAt,
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
		response.CanVote = appeal.Status == models.AppealStatusPending && assigned.Vote == "" && !assigned.Recused
		response.CanRecuse = appeal.Status == models.AppealStatusPending && assigned.Vote == "" && !assigned.Recused
		response.IsRecused = assigned.Recused
		response.MyVote = assigned.Vote
		response.HasVoted = assigned.Vote != ""
		if appeal.Status == models.AppealStatusPending && !response.IsAppellant && !response.IsAdmin {
			// 陪审阶段不向陪审员下发当事人和原管理员身份，避免熟人投票与身份偏见。
			response.Appellant = models.PublicAppealUserResponse{}
			response.Admin = models.PublicAppealUserResponse{}
		}
	}
	return response
}

func appealVoteResponse(vote models.AppealVote) models.AppealVoteResponse {
	return models.AppealVoteResponse{
		ID: vote.ID, AppealID: vote.AppealID, Vote: vote.Vote, Comment: vote.Comment,
		CreatedAt: vote.CreatedAt, Voter: appealUserResponse(vote.Voter), Recused: vote.Recused,
	}
}

func originalPostStatus(snapshot string, fallback models.PostStatus) models.PostStatus {
	var payload struct {
		OriginalStatus models.PostStatus `json:"original_status"`
	}
	if json.Unmarshal([]byte(snapshot), &payload) == nil && payload.OriginalStatus != "" {
		return payload.OriginalStatus
	}
	if fallback == models.PostStatusDeleted {
		return models.PostStatusNormal
	}
	return fallback
}

func originalSnapshotStatus(snapshot, fallback string) string {
	var payload struct {
		OriginalStatus string `json:"original_status"`
	}
	if json.Unmarshal([]byte(snapshot), &payload) == nil && payload.OriginalStatus != "" {
		return payload.OriginalStatus
	}
	if fallback == string(models.PostStatusDeleted) || fallback == string(models.ReplyStatusDeleted) {
		return string(models.PostStatusNormal)
	}
	return fallback
}

// applyAppealPass 恢复治理前状态，同时撤销原举报对作者信誉计数的影响。
// 只有仍为 handled 的原举报会执行回滚，避免重复结案时重复扣减计数。
func applyAppealPass(tx *gorm.DB, appeal models.Appeal) error {
	if appeal.TargetType == "reply" {
		originalStatus := appeal.OriginalTargetStatus
		if originalStatus == "" {
			originalStatus = string(models.ReplyStatusNormal)
		}
		if err := tx.Model(&models.Reply{}).Where("id = ?", appeal.TargetID).Update("status", originalStatus).Error; err != nil {
			return err
		}
		if err := recalculatePostReplyStats(tx, appeal.PostID); err != nil {
			return err
		}
	} else {
		originalStatus := appeal.OriginalPostStatus
		if originalStatus == "" {
			originalStatus = models.PostStatusNormal
		}
		if err := tx.Model(&models.Post{}).Where("id = ?", appeal.PostID).Update("status", originalStatus).Error; err != nil {
			return err
		}
	}
	if appeal.ReportID == nil {
		return nil
	}
	var report models.Report
	if err := tx.First(&report, *appeal.ReportID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil
		}
		return err
	}
	if report.Status != models.ReportStatusHandled {
		return nil
	}
	if err := tx.Model(&report).Updates(map[string]interface{}{"status": models.ReportStatusOverturned, "result": "申诉通过，撤销原治理决定"}).Error; err != nil {
		return err
	}
	if report.TargetAuthorID != nil {
		return tx.Model(&models.User{}).Where("id = ?", *report.TargetAuthorID).
			Update("report_count", gorm.Expr("CASE WHEN report_count > 0 THEN report_count - 1 ELSE 0 END")).Error
	}
	return nil
}

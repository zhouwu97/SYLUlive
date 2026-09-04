package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"shenliyuan/internal/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

type WaterTeamHandler struct {
	db *gorm.DB
}

func NewWaterTeamHandler(db *gorm.DB) *WaterTeamHandler {
	return &WaterTeamHandler{db: db}
}

// createTeamNotification 按业务事件去重写入组队通知。
func createTeamNotification(db *gorm.DB, userID, fromUID, recruitmentID, postID uint, notificationType, dedupKey, content string) {
	var count int64
	if err := db.Model(&models.Notification{}).
		Where("user_id = ? AND type = ? AND dedup_key = ?", userID, notificationType, dedupKey).
		Count(&count).Error; err != nil || count > 0 {
		return
	}
	db.Create(&models.Notification{
		UserID: userID, Type: notificationType, Content: content,
		RelatedID: recruitmentID, PostID: postID, FromUID: fromUID, DedupKey: dedupKey,
	})
}

// NotifyDeadlineSoon 为三天内截止、仍在招募中的发起人创建一次提醒。
func (h *WaterTeamHandler) NotifyDeadlineSoon() {
	now := time.Now()
	var rows []struct {
		RecruitmentID uint
		PostID        uint
		OwnerID       uint
		Title         string
	}
	if err := h.db.Table("water_team_recruitments").
		Select("water_team_recruitments.id AS recruitment_id, water_team_recruitments.post_id, posts.author_id AS owner_id, posts.title").
		Joins("JOIN posts ON posts.id = water_team_recruitments.post_id").
		Where("water_team_recruitments.status = ? AND water_team_recruitments.accepted_count < water_team_recruitments.needed_count", models.RecruitmentStatusRecruiting).
		Where("water_team_recruitments.deadline IS NOT NULL AND water_team_recruitments.deadline > ? AND water_team_recruitments.deadline <= ?", now, now.Add(72*time.Hour)).
		Where("posts.status != ?", models.PostStatusDeleted).
		Scan(&rows).Error; err != nil {
		return
	}
	for _, row := range rows {
		createTeamNotification(h.db, row.OwnerID, 0, row.RecruitmentID, row.PostID, "team_deadline_soon", fmt.Sprintf("team_deadline_soon:%d", row.RecruitmentID), "你的组队《"+row.Title+"》即将截止")
	}
}

// currentUserOr401 获取当前登录用户
func (h *WaterTeamHandler) currentUserOr401(c *gin.Context) (uint, bool) {
	val, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录", "code": "authentication_required"})
		return 0, false
	}
	userID, ok := val.(uint)
	if !ok || userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "无效的用户身份", "code": "authentication_required"})
		return 0, false
	}
	return userID, true
}

type UpdateTeamRecruitmentStatusRequest struct {
	Status string `json:"status" binding:"required"`
}
type ApplyTeamRecruitmentRequest struct {
	Message      string `json:"message"`
	Availability string `json:"availability"`
}

// Apply POST /api/water/team/recruitments/:id/apply
func (h *WaterTeamHandler) Apply(c *gin.Context) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	idStr := c.Param("id")
	recruitmentID, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的招募ID"})
		return
	}

	var req ApplyTeamRecruitmentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体格式错误"})
		return
	}
	req.Message = strings.TrimSpace(req.Message)
	req.Availability = strings.TrimSpace(req.Availability)

	if len([]rune(req.Message)) < 5 || len([]rune(req.Message)) > 500 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "申请留言请控制在5~500字"})
		return
	}
	if len([]rune(req.Availability)) > 200 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "可参与时间最多200字"})
		return
	}

	var responseApp models.WaterTeamApplication
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var recruitment models.WaterTeamRecruitment
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Preload("Post").First(&recruitment, recruitmentID).Error; err != nil {
			return fmt.Errorf("recruitment_not_found")
		}

		if recruitment.Post.AuthorID == userID {
			return fmt.Errorf("cannot_apply_own")
		}

		if recruitment.Post.Status == models.PostStatusDeleted {
			return fmt.Errorf("post_deleted")
		}

		if recruitment.Post.WaterTagID == nil {
			return fmt.Errorf("invalid_tag")
		}

		var tag models.WaterSectionTag
		if err := tx.First(&tag, *recruitment.Post.WaterTagID).Error; err != nil {
			return fmt.Errorf("invalid_tag")
		}

		if tag.ContentMode != models.WaterTagModeTeamRecruitment {
			return fmt.Errorf("tag_disabled")
		}

		var section models.WaterSection
		if err := tx.First(&section, tag.SectionID).Error; err != nil {
			return fmt.Errorf("invalid_section")
		}

		if section.Status != "active" {
			return fmt.Errorf("section_inactive")
		}

		// Check if user is muted
		permSvc := services.NewWaterPermissionService(tx)
		if permSvc.IsMuted(section.ID, userID) {
			return fmt.Errorf("user_muted")
		}

		now := time.Now()
		effectiveStatus := models.EffectiveRecruitmentStatus(recruitment, now)
		if effectiveStatus != models.RecruitmentStatusRecruiting {
			return fmt.Errorf("recruitment_not_available")
		}

		var existing models.WaterTeamApplication
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("recruitment_id = ? AND applicant_id = ?", recruitment.ID, userID).First(&existing).Error
		if err == nil {
			if existing.Status == models.ApplicationStatusPending {
				return fmt.Errorf("already_applied")
			}
			if existing.Status == models.ApplicationStatusAccepted {
				return fmt.Errorf("already_joined")
			}
			// Re-apply if rejected/cancelled
			if err := tx.Model(&existing).Updates(map[string]interface{}{
				"status":       models.ApplicationStatusPending,
				"message":      req.Message,
				"availability": req.Availability,
				"reviewed_at":  nil,
				"owner_reply":  "",
			}).Error; err != nil {
				return err
			}

			if err := tx.First(&existing, existing.ID).Error; err != nil {
				return err
			}

			responseApp = existing
			return nil
		}

		app := models.WaterTeamApplication{
			RecruitmentID: recruitment.ID,
			PostID:        recruitment.PostID,
			ApplicantID:   userID,
			OwnerID:       recruitment.Post.AuthorID,
			Message:       req.Message,
			Availability:  req.Availability,
			Status:        models.ApplicationStatusPending,
		}

		if err := tx.Create(&app).Error; err != nil {
			return err
		}
		responseApp = app
		return nil
	})

	if err != nil {
		switch err.Error() {
		case "recruitment_not_found":
			c.JSON(http.StatusNotFound, gin.H{"error": "招募信息不存在"})
		case "cannot_apply_own":
			c.JSON(http.StatusBadRequest, gin.H{"error": "不能申请自己的招募"})
		case "post_deleted":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该帖子已被删除或屏蔽"})
		case "invalid_tag", "tag_disabled":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该标签不支持组队招募"})
		case "invalid_section", "section_inactive":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该版块已归档或不存在"})
		case "user_muted":
			c.JSON(http.StatusForbidden, gin.H{"error": "你已被该版块禁言，无法申请"})
		case "recruitment_not_available":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该招募目前不接受申请"})
		case "already_applied":
			c.JSON(http.StatusConflict, gin.H{"error": "您已经申请过该招募"})
		case "already_joined":
			c.JSON(http.StatusConflict, gin.H{"error": "您已加入该招募"})
		default:
			if utils.IsPostgresUniqueViolation(err) {
				c.JSON(http.StatusConflict, gin.H{"error": "您已经申请过该招募"})
				return
			}
			c.JSON(http.StatusInternalServerError, gin.H{"error": "提交申请失败"})
		}
		return
	}
	createTeamNotification(h.db, responseApp.OwnerID, userID, responseApp.RecruitmentID, responseApp.PostID, "team_application", fmt.Sprintf("team_application:%d:%d", responseApp.ID, responseApp.UpdatedAt.UnixNano()), "有人申请加入你的组队")

	c.JSON(http.StatusCreated, responseApp)
}

// ============================================================================
// 独立组队 API — /api/team/...
// 这些接口不再依赖 water_tag content_mode 判断，直接使用独立路由和业务对象。
// ============================================================================

// CreateTeamRecruitmentRequest 创建招募请求（独立于 Post 创建）
type CreateTeamRecruitmentRequest struct {
	Category     string   `json:"category" binding:"required"`
	Title        string   `json:"title" binding:"required"`
	Description  string   `json:"description" binding:"required"`
	NeededCount  int      `json:"needed_count" binding:"required"`
	Roles        []string `json:"roles"`
	Deadline     string   `json:"deadline"`
	ImageFileIDs []uint   `json:"image_file_ids"`
}

// UpdateTeamRecruitmentRequest 编辑招募请求
type UpdateTeamRecruitmentRequest struct {
	Category     string   `json:"category"`
	Title        string   `json:"title"`
	Description  string   `json:"description"`
	NeededCount  int      `json:"needed_count"`
	Roles        []string `json:"roles"`
	Deadline     *string  `json:"deadline"`
	ImageFileIDs []uint   `json:"image_file_ids"`
}

// TeamRecruitmentListItem 列表项（轻量，不含完整 post 内容）
type TeamRecruitmentListItem struct {
	ID                      uint       `json:"id"`
	PostID                  uint       `json:"post_id"`
	Category                string     `json:"category"`
	Title                   string     `json:"title"`
	Description             string     `json:"description"`
	AuthorID                uint       `json:"author_id"`
	AuthorName              string     `json:"author_name"`
	AuthorAvatar            string     `json:"author_avatar"`
	NeededCount             int        `json:"needed_count"`
	AcceptedCount           int        `json:"accepted_count"`
	RemainingCount          int        `json:"remaining_count"`
	Roles                   []string   `json:"roles"`
	Deadline                *time.Time `json:"deadline"`
	Status                  string     `json:"status"`
	EffectiveStatus         string     `json:"effective_status"`
	FirstImageURL           string     `json:"first_image_url"`
	ApplicationCount        int64      `json:"application_count"`
	PendingApplicationCount int64      `json:"pending_application_count"`
	CreatedAt               time.Time  `json:"created_at"`
	UpdatedAt               time.Time  `json:"updated_at"`

	// 登录用户专属
	MyApplicationStatus *string `json:"my_application_status,omitempty"`
	MyApplicationID     *uint   `json:"my_application_id,omitempty"`
	IsOwner             bool    `json:"is_owner"`
	CanApply            bool    `json:"can_apply"`
	CanManage           bool    `json:"can_manage"`
}

// TeamRecruitmentDetail 详情（含完整 post 内容）
type TeamRecruitmentDetail struct {
	ID                      uint           `json:"id"`
	PostID                  uint           `json:"post_id"`
	Category                string         `json:"category"`
	Title                   string         `json:"title"`
	Description             string         `json:"description"`
	Author                  UserBrief      `json:"author"`
	Images                  []PostImageDTO `json:"images"`
	NeededCount             int            `json:"needed_count"`
	AcceptedCount           int            `json:"accepted_count"`
	RemainingCount          int            `json:"remaining_count"`
	Roles                   []string       `json:"roles"`
	Deadline                *time.Time     `json:"deadline"`
	Status                  string         `json:"status"`
	EffectiveStatus         string         `json:"effective_status"`
	ApplicationCount        int64          `json:"application_count"`
	PendingApplicationCount int64          `json:"pending_application_count"`
	ViewCount               int            `json:"view_count"`
	ReplyCount              int            `json:"reply_count"`
	CreatedAt               time.Time      `json:"created_at"`
	UpdatedAt               time.Time      `json:"updated_at"`

	// 登录用户专属
	MyApplicationStatus *string `json:"my_application_status,omitempty"`
	MyApplicationID     *uint   `json:"my_application_id,omitempty"`
	IsOwner             bool    `json:"is_owner"`
	CanApply            bool    `json:"can_apply"`
	CanManage           bool    `json:"can_manage"`
}

// UserBrief 用户简要信息
type UserBrief struct {
	ID     uint   `json:"id"`
	Name   string `json:"name"`
	Avatar string `json:"avatar"`
	Bio    string `json:"bio"`
}

// PostImageDTO 图片传输对象
type PostImageDTO struct {
	ID     uint   `json:"id"`
	FileID uint   `json:"file_id"`
	URL    string `json:"url"`
}

// ensureTeamTag 查找系统内部的 team_recruitment 标签（用于底层创建 Post）。
// 标签对普通水帖已停用，因此这里不能检查 is_enabled。
func (h *WaterTeamHandler) ensureTeamTag(tx *gorm.DB, sectionSlug string) (uint, uint, error) {
	var section models.WaterSection
	if err := tx.Where("slug = ? AND status = ?", sectionSlug, "active").First(&section).Error; err != nil {
		return 0, 0, fmt.Errorf("未找到对应版块")
	}
	var tag models.WaterSectionTag
	if err := tx.Where("section_id = ? AND content_mode = ?",
		section.ID, models.WaterTagModeTeamRecruitment).First(&tag).Error; err != nil {
		return 0, 0, fmt.Errorf("组队标签不可用")
	}
	return section.ID, tag.ID, nil
}

// parseTeamDeadline 解析截止时间字符串
func parseTeamDeadline(deadlineStr string) (*time.Time, error) {
	deadlineStr = strings.TrimSpace(deadlineStr)
	if deadlineStr == "" {
		return nil, nil
	}
	t, err := time.Parse(time.RFC3339, deadlineStr)
	if err != nil {
		return nil, fmt.Errorf("截止时间格式错误")
	}
	if !t.After(time.Now()) {
		return nil, fmt.Errorf("截止时间必须在将来")
	}
	return &t, nil
}

// validateTeamRoles 验证方向列表
func validateTeamRoles(roles []string) ([]string, error) {
	if len(roles) == 0 {
		return nil, nil // 允许空
	}
	if len(roles) > 8 {
		return nil, fmt.Errorf("最多8个方向")
	}
	seen := map[string]struct{}{}
	valid := make([]string, 0, len(roles))
	for _, r := range roles {
		r = strings.TrimSpace(r)
		if r == "" {
			continue
		}
		if len([]rune(r)) > 20 {
			return nil, fmt.Errorf("单个方向最多20字符")
		}
		if _, ok := seen[r]; ok {
			continue
		}
		seen[r] = struct{}{}
		valid = append(valid, r)
	}
	return valid, nil
}

// validateTeamImageFiles 校验组队图片引用，避免关联不存在或非图片文件。
func validateTeamImageFiles(tx *gorm.DB, fileIDs []uint, ownerID uint) error {
	if len(fileIDs) > 9 {
		return &teamInputError{message: "最多上传9张图片"}
	}
	if len(fileIDs) == 0 {
		return nil
	}
	seen := make(map[uint]struct{}, len(fileIDs))
	for _, fileID := range fileIDs {
		if fileID == 0 {
			return &teamInputError{message: "图片文件不存在"}
		}
		if _, exists := seen[fileID]; exists {
			return &teamInputError{message: "图片不能重复选择"}
		}
		seen[fileID] = struct{}{}
	}
	var files []models.File
	if err := tx.Where("id IN ?", fileIDs).Find(&files).Error; err != nil {
		return err
	}
	if len(files) != len(seen) {
		return &teamInputError{message: "图片文件不存在"}
	}
	for _, file := range files {
		if !strings.HasPrefix(strings.ToLower(file.MimeType), "image/") {
			return &teamInputError{message: "仅支持图片文件"}
		}
		if file.AccessScope == models.FileAccessPublic || file.UploaderID == ownerID {
			continue
		}
		var grants int64
		if err := tx.Model(&models.FileUploadGrant{}).
			Where("file_id = ? AND user_id = ?", file.ID, ownerID).
			Count(&grants).Error; err != nil {
			return err
		}
		if grants == 0 {
			return &teamInputError{message: "无权引用该图片文件"}
		}
	}
	return nil
}

type teamInputError struct {
	message string
}

func (e *teamInputError) Error() string {
	return e.message
}

// applyRecruitmentStatusFilter 统一数据库筛选与有效状态的优先级。
func applyRecruitmentStatusFilter(query *gorm.DB, status string, now time.Time) *gorm.DB {
	switch status {
	case models.RecruitmentStatusClosed:
		return query.Where("water_team_recruitments.status = ?", models.RecruitmentStatusClosed)
	case models.RecruitmentStatusExpired:
		return query.Where("water_team_recruitments.status != ?", models.RecruitmentStatusClosed).
			Where("water_team_recruitments.deadline IS NOT NULL AND water_team_recruitments.deadline <= ?", now)
	case models.RecruitmentStatusFull:
		return query.Where("water_team_recruitments.status != ?", models.RecruitmentStatusClosed).
			Where("(water_team_recruitments.deadline IS NULL OR water_team_recruitments.deadline > ?)", now).
			Where("water_team_recruitments.accepted_count >= water_team_recruitments.needed_count")
	case models.RecruitmentStatusRecruiting:
		return query.Where("water_team_recruitments.status = ?", models.RecruitmentStatusRecruiting).
			Where("(water_team_recruitments.deadline IS NULL OR water_team_recruitments.deadline > ?)", now).
			Where("water_team_recruitments.accepted_count < water_team_recruitments.needed_count")
	default:
		return query
	}
}

func canReapplyTeamApplication(status string) bool {
	return status == models.ApplicationStatusRejected ||
		status == models.ApplicationStatusCancelled ||
		status == models.ApplicationStatusWithdrawn ||
		status == models.ApplicationStatusRemoved
}

// ListTeamRecruitments GET /api/team/recruitments
func (h *WaterTeamHandler) ListTeamRecruitments(c *gin.Context) {
	category := c.Query("category")
	statusFilter := c.Query("status")
	keyword := strings.TrimSpace(c.Query("keyword"))
	role := c.Query("role")
	sort := c.DefaultQuery("sort", "recommended")
	availableOnly := c.Query("available_only") == "true"
	pageStr := c.DefaultQuery("page", "1")
	limitStr := c.DefaultQuery("limit", "20")

	page, _ := strconv.Atoi(pageStr)
	limit, _ := strconv.Atoi(limitStr)
	if page < 1 {
		page = 1
	}
	if limit < 1 || limit > 50 {
		limit = 20
	}
	offset := (page - 1) * limit

	now := time.Now()

	query := h.db.Model(&models.WaterTeamRecruitment{}).
		Joins("JOIN posts ON posts.id = water_team_recruitments.post_id").
		Joins("JOIN users ON users.id = posts.author_id").
		Where("posts.status != ?", models.PostStatusDeleted)

	if category != "" {
		query = query.Where("water_team_recruitments.category = ?", category)
	}
	if keyword != "" {
		like := "%" + keyword + "%"
		query = query.Where("(posts.title ILIKE ? OR posts.content ILIKE ? OR water_team_recruitments.roles_json ILIKE ?)", like, like, like)
	}
	if role != "" {
		query = query.Where("water_team_recruitments.roles_json ILIKE ?", "%\""+role+"\"%")
	}

	if statusFilter == "deadline_soon" {
		query = query.Where("water_team_recruitments.status = ?", models.RecruitmentStatusRecruiting).
			Where("water_team_recruitments.deadline IS NOT NULL AND water_team_recruitments.deadline > ? AND water_team_recruitments.deadline <= ?",
				now, now.Add(72*time.Hour)).
			Where("water_team_recruitments.accepted_count < water_team_recruitments.needed_count")
	} else if statusFilter != "" {
		query = applyRecruitmentStatusFilter(query, statusFilter, now)
	}
	if availableOnly {
		query = applyRecruitmentStatusFilter(query, models.RecruitmentStatusRecruiting, now)
	}

	// 排序必须在数据库端完成，否则分页后在客户端排序会产生错位。
	deadlineSoonOrder := "CASE WHEN water_team_recruitments.deadline IS NOT NULL AND water_team_recruitments.deadline > CURRENT_TIMESTAMP AND water_team_recruitments.deadline <= CURRENT_TIMESTAMP + INTERVAL '3 days' THEN 0 ELSE 1 END ASC"
	if h.db.Dialector.Name() == "sqlite" {
		deadlineSoonOrder = "CASE WHEN water_team_recruitments.deadline IS NOT NULL AND water_team_recruitments.deadline > CURRENT_TIMESTAMP AND water_team_recruitments.deadline <= datetime(CURRENT_TIMESTAMP, '+3 days') THEN 0 ELSE 1 END ASC"
	}
	switch sort {
	case "latest":
		query = query.Order("water_team_recruitments.created_at DESC")
	case "deadline":
		query = query.Order("CASE WHEN water_team_recruitments.deadline IS NULL THEN 1 ELSE 0 END ASC").
			Order("water_team_recruitments.deadline ASC").
			Order("water_team_recruitments.created_at DESC")
	default:
		// PostgreSQL 与 SQLite 都能执行的固定排序表达式；避免 GORM 对带变量 Order 的错误括号处理。
		query = query.Order("CASE WHEN water_team_recruitments.status = 'recruiting' AND water_team_recruitments.accepted_count < water_team_recruitments.needed_count AND (water_team_recruitments.deadline IS NULL OR water_team_recruitments.deadline > CURRENT_TIMESTAMP) THEN 0 WHEN water_team_recruitments.status = 'full' THEN 2 WHEN water_team_recruitments.status = 'closed' THEN 3 ELSE 1 END ASC").
			Order(deadlineSoonOrder).
			Order("water_team_recruitments.created_at DESC")
	}

	var total int64
	query.Session(&gorm.Session{}).Count(&total)

	var recruitments []struct {
		models.WaterTeamRecruitment
		PostTitle      string
		PostContent    string
		PostStatus     string
		PostViewCount  int
		PostReplyCount int
		AuthorID       uint
		AuthorName     string
		AuthorAvatar   string
	}
	if err := query.Select("water_team_recruitments.*, posts.title as post_title, posts.content as post_content, posts.status as post_status, posts.view_count as post_view_count, posts.reply_count as post_reply_count, users.id as author_id, users.nickname as author_name, users.avatar as author_avatar").
		Offset(offset).Limit(limit).
		Find(&recruitments).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取组队列表失败"})
		return
	}

	// 一次查询首图、文件、申请数和当前用户申请状态，避免列表中的 N+1 查询。
	postIDs := make([]uint, 0, len(recruitments))
	recruitmentIDs := make([]uint, 0, len(recruitments))
	for _, r := range recruitments {
		postIDs = append(postIDs, r.PostID)
		recruitmentIDs = append(recruitmentIDs, r.ID)
	}
	firstImageByPost := make(map[uint]string)
	if len(postIDs) > 0 {
		var images []models.PostImage
		h.db.Where("post_id IN ?", postIDs).Order("post_id ASC, sort_order ASC").Find(&images)
		fileIDs := make([]uint, 0, len(images))
		for _, image := range images {
			if _, exists := firstImageByPost[image.PostID]; !exists {
				fileIDs = append(fileIDs, image.FileID)
			}
		}
		var files []models.File
		filePathByID := make(map[uint]string)
		if len(fileIDs) > 0 {
			h.db.Where("id IN ?", fileIDs).Find(&files)
			for _, file := range files {
				filePathByID[file.ID] = file.Path
			}
		}
		for _, image := range images {
			if _, exists := firstImageByPost[image.PostID]; !exists {
				firstImageByPost[image.PostID] = filePathByID[image.FileID]
			}
		}
	}
	applicationCountByRecruitment := make(map[uint]int64)
	pendingCountByRecruitment := make(map[uint]int64)
	if len(recruitmentIDs) > 0 {
		var rows []struct {
			RecruitmentID uint
			Count         int64
			PendingCount  int64
		}
		h.db.Model(&models.WaterTeamApplication{}).
			Select("recruitment_id, COUNT(*) AS count, SUM(CASE WHEN status = ? THEN 1 ELSE 0 END) AS pending_count", models.ApplicationStatusPending).
			Where("recruitment_id IN ?", recruitmentIDs).Group("recruitment_id").Scan(&rows)
		for _, row := range rows {
			applicationCountByRecruitment[row.RecruitmentID] = row.Count
			pendingCountByRecruitment[row.RecruitmentID] = row.PendingCount
		}
	}
	myApplicationByRecruitment := make(map[uint]models.WaterTeamApplication)
	if userID, ok := c.Get("user_id"); ok && len(recruitmentIDs) > 0 {
		var apps []models.WaterTeamApplication
		h.db.Where("applicant_id = ? AND recruitment_id IN ?", userID.(uint), recruitmentIDs).Find(&apps)
		for _, app := range apps {
			myApplicationByRecruitment[app.RecruitmentID] = app
		}
	}

	// 填充列表项
	items := make([]TeamRecruitmentListItem, 0, len(recruitments))
	for i := range recruitments {
		r := &recruitments[i]

		var roles []string
		if r.RolesJSON != "" {
			json.Unmarshal([]byte(r.RolesJSON), &roles)
		}
		if roles == nil {
			roles = []string{}
		}

		effectiveStatus := models.EffectiveRecruitmentStatus(r.WaterTeamRecruitment, now)

		remaining := r.NeededCount - r.AcceptedCount
		if remaining < 0 {
			remaining = 0
		}

		item := TeamRecruitmentListItem{
			ID:                      r.ID,
			PostID:                  r.PostID,
			Category:                r.Category,
			Title:                   r.PostTitle,
			Description:             truncateContent(r.PostContent, 120),
			AuthorID:                r.AuthorID,
			AuthorName:              r.AuthorName,
			AuthorAvatar:            r.AuthorAvatar,
			NeededCount:             r.NeededCount,
			AcceptedCount:           r.AcceptedCount,
			RemainingCount:          remaining,
			Roles:                   roles,
			Deadline:                r.Deadline,
			Status:                  r.Status,
			EffectiveStatus:         effectiveStatus,
			FirstImageURL:           firstImageByPost[r.PostID],
			ApplicationCount:        applicationCountByRecruitment[r.ID],
			PendingApplicationCount: pendingCountByRecruitment[r.ID],
			CreatedAt:               r.CreatedAt,
			UpdatedAt:               r.UpdatedAt,
		}

		// 登录用户专属字段
		if userID, ok := c.Get("user_id"); ok {
			uid := userID.(uint)
			item.IsOwner = r.AuthorID == uid
			item.CanManage = item.IsOwner
			item.CanApply = !item.IsOwner && effectiveStatus == models.RecruitmentStatusRecruiting

			if !item.IsOwner {
				if app, exists := myApplicationByRecruitment[r.ID]; exists {
					item.MyApplicationStatus = &app.Status
					item.MyApplicationID = &app.ID
					item.CanApply = canReapplyTeamApplication(app.Status)
				}
			}
		}

		items = append(items, item)
	}

	c.JSON(http.StatusOK, gin.H{
		"items":     items,
		"total":     total,
		"page":      page,
		"page_size": limit,
		"limit":     limit,
		"has_more":  int64(offset+len(items)) < total,
	})
}

// GetTeamRecruitment GET /api/team/recruitments/:id
func (h *WaterTeamHandler) GetTeamRecruitment(c *gin.Context) {
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的招募ID"})
		return
	}

	var recruitment models.WaterTeamRecruitment
	if err := h.db.Preload("Post").Preload("Post.Author").Preload("Post.Images").Preload("Post.Images.File").First(&recruitment, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "招募信息不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取招募信息失败"})
		return
	}

	if recruitment.Post.Status == models.PostStatusDeleted {
		c.JSON(http.StatusNotFound, gin.H{"error": "该帖子已被删除"})
		return
	}

	now := time.Now()

	var roles []string
	if recruitment.RolesJSON != "" {
		json.Unmarshal([]byte(recruitment.RolesJSON), &roles)
	}
	if roles == nil {
		roles = []string{}
	}

	effectiveStatus := models.EffectiveRecruitmentStatus(recruitment, now)
	remaining := recruitment.NeededCount - recruitment.AcceptedCount
	if remaining < 0 {
		remaining = 0
	}

	var counts struct {
		ApplicationCount        int64
		PendingApplicationCount int64
	}
	h.db.Model(&models.WaterTeamApplication{}).
		Select("COUNT(*) AS application_count, SUM(CASE WHEN status = ? THEN 1 ELSE 0 END) AS pending_application_count", models.ApplicationStatusPending).
		Where("recruitment_id = ?", recruitment.ID).Scan(&counts)

	// 图片
	images := make([]PostImageDTO, 0, len(recruitment.Post.Images))
	for _, img := range recruitment.Post.Images {
		images = append(images, PostImageDTO{ID: img.ID, FileID: img.FileID, URL: img.File.Path})
	}

	detail := TeamRecruitmentDetail{
		ID:          recruitment.ID,
		PostID:      recruitment.PostID,
		Category:    recruitment.Category,
		Title:       recruitment.Post.Title,
		Description: recruitment.Post.Content,
		Author: UserBrief{
			ID:     recruitment.Post.Author.ID,
			Name:   recruitment.Post.Author.Nickname,
			Avatar: recruitment.Post.Author.Avatar,
		},
		Images:                  images,
		NeededCount:             recruitment.NeededCount,
		AcceptedCount:           recruitment.AcceptedCount,
		RemainingCount:          remaining,
		Roles:                   roles,
		Deadline:                recruitment.Deadline,
		Status:                  recruitment.Status,
		EffectiveStatus:         effectiveStatus,
		ApplicationCount:        counts.ApplicationCount,
		PendingApplicationCount: counts.PendingApplicationCount,
		ViewCount:               recruitment.Post.ViewCount,
		ReplyCount:              recruitment.Post.ReplyCount,
		CreatedAt:               recruitment.CreatedAt,
		UpdatedAt:               recruitment.UpdatedAt,
	}

	// 登录用户专属
	if userID, ok := c.Get("user_id"); ok {
		uid := userID.(uint)
		detail.IsOwner = recruitment.Post.AuthorID == uid
		detail.CanManage = detail.IsOwner
		detail.CanApply = !detail.IsOwner && effectiveStatus == models.RecruitmentStatusRecruiting

		if !detail.IsOwner {
			var app models.WaterTeamApplication
			if err := h.db.Where("recruitment_id = ? AND applicant_id = ?", recruitment.ID, uid).First(&app).Error; err == nil {
				detail.MyApplicationStatus = &app.Status
				detail.MyApplicationID = &app.ID
				detail.CanApply = canReapplyTeamApplication(app.Status)
			}
		}
	}

	// 增加浏览数
	h.db.Model(&models.Post{}).Where("id = ?", recruitment.PostID).
		UpdateColumn("view_count", gorm.Expr("view_count + 1"))

	c.JSON(http.StatusOK, detail)
}

// CreateTeamRecruitment POST /api/team/recruitments
func (h *WaterTeamHandler) CreateTeamRecruitment(c *gin.Context) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	var req CreateTeamRecruitmentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体格式错误"})
		return
	}

	// 验证分类
	if !models.ValidTeamCategories[req.Category] {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的组队类型"})
		return
	}

	// 验证标题
	req.Title = strings.TrimSpace(req.Title)
	if len([]rune(req.Title)) < 2 || len([]rune(req.Title)) > 100 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "标题需在2-100字之间"})
		return
	}

	// 验证说明
	req.Description = strings.TrimSpace(req.Description)
	if len([]rune(req.Description)) < 10 || len([]rune(req.Description)) > 5000 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "说明需在10-5000字之间"})
		return
	}

	// 验证人数
	if req.NeededCount < 1 || req.NeededCount > 20 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "招募人数需在1-20之间"})
		return
	}

	// 验证方向
	roles, err := validateTeamRoles(req.Roles)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	rolesJSON, _ := json.Marshal(roles)

	// 解析截止时间
	deadline, err := parseTeamDeadline(req.Deadline)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if err := validateTeamImageFiles(h.db, req.ImageFileIDs, userID); err != nil {
		var inputErr *teamInputError
		if errors.As(err, &inputErr) {
			c.JSON(http.StatusBadRequest, gin.H{"error": inputErr.Error()})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "校验图片失败"})
		}
		return
	}

	// 分类是组队大厅的业务分类；底层统一关联比赛竞赛版块的内部标签。
	sectionSlug := "competition"

	var detail TeamRecruitmentDetail
	err = h.db.Transaction(func(tx *gorm.DB) error {
		if err := services.ClaimPublicImageFiles(tx, req.ImageFileIDs); err != nil {
			return err
		}
		// 找到系统内部 team_recruitment 标签
		sectionID, tagID, tagErr := h.ensureTeamTag(tx, sectionSlug)
		if tagErr != nil {
			return tagErr
		}

		// 检查禁言
		permSvc := services.NewWaterPermissionService(tx)
		if permSvc.IsMuted(sectionID, userID) {
			return fmt.Errorf("user_muted")
		}

		// 创建 Post
		post := models.Post{
			Title:      req.Title,
			Content:    req.Description,
			BoardID:    models.BoardShuitie,
			AuthorID:   userID,
			PostType:   sectionSlug,
			WaterTagID: &tagID,
			Status:     models.PostStatusNormal,
		}
		if err := tx.Create(&post).Error; err != nil {
			return err
		}

		// 创建 WaterTeamRecruitment
		recruitment := models.WaterTeamRecruitment{
			PostID:      post.ID,
			SectionID:   sectionID,
			TagID:       tagID,
			Category:    req.Category,
			NeededCount: req.NeededCount,
			RolesJSON:   string(rolesJSON),
			Deadline:    deadline,
			Status:      models.RecruitmentStatusRecruiting,
		}
		if err := tx.Create(&recruitment).Error; err != nil {
			return err
		}

		// 关联图片
		if len(req.ImageFileIDs) > 0 {
			for i, fileID := range req.ImageFileIDs {
				postImage := models.PostImage{
					PostID:    post.ID,
					FileID:    fileID,
					SortOrder: i,
				}
				if err := tx.Create(&postImage).Error; err != nil {
					return err
				}
			}
		}

		// 重新加载完整数据
		if err := tx.Preload("Author").Preload("Images").Preload("Images.File").Scopes(withPostImageVariants).First(&post, post.ID).Error; err != nil {
			return err
		}

		// 构建返回的 detail
		remaining := req.NeededCount
		if remaining < 0 {
			remaining = 0
		}

		images := make([]PostImageDTO, 0, len(post.Images))
		for _, img := range post.Images {
			images = append(images, PostImageDTO{ID: img.ID, FileID: img.FileID, URL: img.File.Path})
		}

		detail = TeamRecruitmentDetail{
			ID:          recruitment.ID,
			PostID:      recruitment.PostID,
			Category:    recruitment.Category,
			Title:       post.Title,
			Description: post.Content,
			Author: UserBrief{
				ID:     post.Author.ID,
				Name:   post.Author.Nickname,
				Avatar: post.Author.Avatar,
			},
			Images:           images,
			NeededCount:      recruitment.NeededCount,
			AcceptedCount:    recruitment.AcceptedCount,
			RemainingCount:   remaining,
			Roles:            roles,
			Deadline:         recruitment.Deadline,
			Status:           recruitment.Status,
			EffectiveStatus:  models.RecruitmentStatusRecruiting,
			ApplicationCount: 0,
			ViewCount:        0,
			ReplyCount:       0,
			CreatedAt:        recruitment.CreatedAt,
			UpdatedAt:        recruitment.UpdatedAt,
			IsOwner:          true,
			CanManage:        true,
			CanApply:         false,
		}

		return nil
	})

	if err != nil {
		switch err.Error() {
		case "user_muted":
			c.JSON(http.StatusForbidden, gin.H{"error": "你已被禁言，暂时无法发布组队"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "创建组队失败: " + err.Error()})
		}
		return
	}

	// 发放经验（简单版）
	awards := make([]models.ExpAward, 0)
	if awarded, globalAward, expErr := services.AwardDailyGlobalExp(h.db, userID, services.GlobalActionPostDaily, services.GlobalExpPostDaily, "post", detail.PostID); expErr == nil && awarded && globalAward != nil {
		awards = append(awards, *globalAward)
	}

	c.JSON(http.StatusCreated, gin.H{
		"recruitment": detail,
		"exp_awards":  awards,
	})
}

// UpdateTeamRecruitment PATCH /api/team/recruitments/:id
func (h *WaterTeamHandler) UpdateTeamRecruitment(c *gin.Context) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的招募ID"})
		return
	}

	var req UpdateTeamRecruitmentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体格式错误"})
		return
	}

	err = h.db.Transaction(func(tx *gorm.DB) error {
		var recruitment models.WaterTeamRecruitment
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&recruitment, id).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return fmt.Errorf("recruitment_not_found")
			}
			return err
		}
		var post models.Post
		if err := tx.First(&post, recruitment.PostID).Error; err != nil {
			return err
		}
		if post.AuthorID != userID {
			return fmt.Errorf("unauthorized")
		}
		var acceptedCount int64
		if err := tx.Model(&models.WaterTeamApplication{}).
			Where("recruitment_id = ? AND status = ?", recruitment.ID, models.ApplicationStatusAccepted).
			Count(&acceptedCount).Error; err != nil {
			return err
		}
		if err := validateTeamImageFiles(tx, req.ImageFileIDs, userID); req.ImageFileIDs != nil && err != nil {
			return err
		}
		if req.ImageFileIDs != nil {
			if err := services.ClaimPublicImageFiles(tx, req.ImageFileIDs); err != nil {
				return err
			}
		}

		updates := map[string]interface{}{}
		postUpdates := map[string]interface{}{}
		nextNeededCount := recruitment.NeededCount
		nextDeadline := recruitment.Deadline

		if req.Category != "" {
			if !models.ValidTeamCategories[req.Category] {
				return fmt.Errorf("invalid_category")
			}
			updates["category"] = req.Category
		}

		if req.Title != "" {
			req.Title = strings.TrimSpace(req.Title)
			if len([]rune(req.Title)) < 2 || len([]rune(req.Title)) > 100 {
				return fmt.Errorf("title_too_short")
			}
			postUpdates["title"] = req.Title
		}

		if req.Description != "" {
			req.Description = strings.TrimSpace(req.Description)
			if len([]rune(req.Description)) < 10 || len([]rune(req.Description)) > 5000 {
				return fmt.Errorf("desc_invalid")
			}
			postUpdates["content"] = req.Description
		}

		if req.NeededCount > 0 {
			if req.NeededCount < 1 || req.NeededCount > 20 {
				return fmt.Errorf("count_invalid")
			}
			if int64(req.NeededCount) < acceptedCount {
				return fmt.Errorf("count_below_accepted")
			}
			nextNeededCount = req.NeededCount
			updates["needed_count"] = nextNeededCount
		}

		if req.Roles != nil {
			roles, err := validateTeamRoles(req.Roles)
			if err != nil {
				return err
			}
			rolesJSON, _ := json.Marshal(roles)
			updates["roles_json"] = string(rolesJSON)
		}

		if req.Deadline != nil {
			deadline, err := parseTeamDeadline(*req.Deadline)
			if err != nil {
				return err
			}
			nextDeadline = deadline
			updates["deadline"] = deadline
		}

		// 名额变化后同步原始状态，避免有空位却仍显示“已满员”。
		updates["accepted_count"] = acceptedCount
		if recruitment.Status != models.RecruitmentStatusClosed {
			if int64(nextNeededCount) <= acceptedCount {
				updates["status"] = models.RecruitmentStatusFull
			} else if recruitment.Status == models.RecruitmentStatusFull &&
				(nextDeadline == nil || nextDeadline.After(time.Now())) {
				updates["status"] = models.RecruitmentStatusRecruiting
			}
		}

		if len(updates) > 0 {
			if err := tx.Model(&recruitment).Updates(updates).Error; err != nil {
				return err
			}
		}
		if len(postUpdates) > 0 {
			if err := tx.Model(&models.Post{}).Where("id = ?", recruitment.PostID).Updates(postUpdates).Error; err != nil {
				return err
			}
		}

		// 更新图片（全量替换）
		if req.ImageFileIDs != nil {
			if err := tx.Where("post_id = ?", recruitment.PostID).Delete(&models.PostImage{}).Error; err != nil {
				return err
			}
			for i, fileID := range req.ImageFileIDs {
				postImage := models.PostImage{
					PostID:    recruitment.PostID,
					FileID:    fileID,
					SortOrder: i,
				}
				if err := tx.Create(&postImage).Error; err != nil {
					return err
				}
			}
		}

		return nil
	})

	if err != nil {
		message := err.Error()
		switch message {
		case "recruitment_not_found":
			c.JSON(http.StatusNotFound, gin.H{"error": "招募信息不存在"})
			return
		case "unauthorized":
			c.JSON(http.StatusForbidden, gin.H{"error": "无权编辑"})
			return
		case "count_below_accepted":
			message = "招募人数不能少于已加入人数"
		}
		c.JSON(http.StatusBadRequest, gin.H{"error": message})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "更新成功"})
}

// DeleteTeamRecruitment DELETE /api/team/recruitments/:id
// 组队记录和申请用于保留成员关系与审计历史，用户删除时仅关闭招募并软删除底层帖子。
func (h *WaterTeamHandler) DeleteTeamRecruitment(c *gin.Context) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的招募ID"})
		return
	}

	err = h.db.Transaction(func(tx *gorm.DB) error {
		var recruitment models.WaterTeamRecruitment
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&recruitment, id).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return fmt.Errorf("recruitment_not_found")
			}
			return err
		}

		var post models.Post
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&post, recruitment.PostID).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return fmt.Errorf("recruitment_not_found")
			}
			return err
		}
		if post.AuthorID != userID {
			return fmt.Errorf("unauthorized")
		}
		if post.Status == models.PostStatusDeleted {
			return fmt.Errorf("recruitment_not_found")
		}

		if err := tx.Model(&recruitment).Update("status", models.RecruitmentStatusClosed).Error; err != nil {
			return err
		}
		return tx.Model(&post).Update("status", models.PostStatusDeleted).Error
	})

	if err != nil {
		switch err.Error() {
		case "recruitment_not_found":
			c.JSON(http.StatusNotFound, gin.H{"error": "招募信息不存在"})
		case "unauthorized":
			c.JSON(http.StatusForbidden, gin.H{"error": "只能删除自己发起的组队"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "删除组队失败"})
		}
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "删除成功"})
}

// GetMyTeamRecruitments GET /api/team/recruitments/mine
func (h *WaterTeamHandler) GetMyTeamRecruitments(c *gin.Context) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	pageStr := c.DefaultQuery("page", "1")
	limitStr := c.DefaultQuery("limit", "20")
	statusFilter := c.Query("status")

	page, _ := strconv.Atoi(pageStr)
	limit, _ := strconv.Atoi(limitStr)
	if page < 1 {
		page = 1
	}
	if limit < 1 || limit > 50 {
		limit = 20
	}
	offset := (page - 1) * limit

	now := time.Now()

	query := h.db.Model(&models.WaterTeamRecruitment{}).
		Joins("JOIN posts ON posts.id = water_team_recruitments.post_id").
		Where("posts.author_id = ? AND posts.status != ?", userID, models.PostStatusDeleted)

	if statusFilter != "" {
		query = applyRecruitmentStatusFilter(query, statusFilter, now)
	}

	var total int64
	query.Session(&gorm.Session{}).Count(&total)

	var recruitments []models.WaterTeamRecruitment
	if err := query.Select("water_team_recruitments.*").
		Order("water_team_recruitments.created_at DESC").
		Offset(offset).Limit(limit).Find(&recruitments).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取我的招募列表失败"})
		return
	}
	postIDs := make([]uint, 0, len(recruitments))
	recruitmentIDs := make([]uint, 0, len(recruitments))
	for _, recruitment := range recruitments {
		postIDs = append(postIDs, recruitment.PostID)
		recruitmentIDs = append(recruitmentIDs, recruitment.ID)
	}
	postsByID := make(map[uint]models.Post, len(postIDs))
	if len(postIDs) > 0 {
		var posts []models.Post
		if err := h.db.Preload("Author").Preload("Images", func(db *gorm.DB) *gorm.DB {
			return db.Order("sort_order ASC")
		}).Preload("Images.File").Scopes(withPostImageVariants).Where("id IN ?", postIDs).Find(&posts).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取我的招募列表失败"})
			return
		}
		for _, post := range posts {
			postsByID[post.ID] = post
		}
	}
	totalCountByRecruitment := make(map[uint]int64)
	pendingCountByRecruitment := make(map[uint]int64)
	if len(recruitmentIDs) > 0 {
		var rows []struct {
			RecruitmentID uint
			Count         int64
			PendingCount  int64
		}
		h.db.Model(&models.WaterTeamApplication{}).
			Select("recruitment_id, COUNT(*) AS count, SUM(CASE WHEN status = ? THEN 1 ELSE 0 END) AS pending_count", models.ApplicationStatusPending).
			Where("recruitment_id IN ?", recruitmentIDs).Group("recruitment_id").Scan(&rows)
		for _, row := range rows {
			totalCountByRecruitment[row.RecruitmentID] = row.Count
			pendingCountByRecruitment[row.RecruitmentID] = row.PendingCount
		}
	}

	items := make([]TeamRecruitmentListItem, 0, len(recruitments))
	for i := range recruitments {
		r := &recruitments[i]

		var roles []string
		if r.RolesJSON != "" {
			json.Unmarshal([]byte(r.RolesJSON), &roles)
		}
		if roles == nil {
			roles = []string{}
		}

		effectiveStatus := models.EffectiveRecruitmentStatus(*r, now)
		remaining := r.NeededCount - r.AcceptedCount
		if remaining < 0 {
			remaining = 0
		}

		post, exists := postsByID[r.PostID]
		if !exists {
			continue
		}
		firstImageURL := ""
		if len(post.Images) > 0 {
			firstImageURL = post.Images[0].File.Path
		}

		items = append(items, TeamRecruitmentListItem{
			ID:                      r.ID,
			PostID:                  r.PostID,
			Category:                r.Category,
			Title:                   post.Title,
			Description:             truncateContent(post.Content, 120),
			AuthorID:                post.AuthorID,
			AuthorName:              post.Author.Nickname,
			AuthorAvatar:            post.Author.Avatar,
			NeededCount:             r.NeededCount,
			AcceptedCount:           r.AcceptedCount,
			RemainingCount:          remaining,
			Roles:                   roles,
			Deadline:                r.Deadline,
			Status:                  r.Status,
			EffectiveStatus:         effectiveStatus,
			FirstImageURL:           firstImageURL,
			ApplicationCount:        totalCountByRecruitment[r.ID],
			PendingApplicationCount: pendingCountByRecruitment[r.ID],
			CreatedAt:               r.CreatedAt,
			IsOwner:                 true,
			CanManage:               true,
			CanApply:                false,
		})
	}

	c.JSON(http.StatusOK, gin.H{
		"items":     items,
		"total":     total,
		"page":      page,
		"page_size": limit,
		"limit":     limit,
		"has_more":  int64(offset+len(items)) < total,
	})
}

// truncateContent 截取纯文本预览
func truncateContent(content string, maxRunes int) string {
	runes := []rune(content)
	if len(runes) <= maxRunes {
		return content
	}
	return string(runes[:maxRunes]) + "……"
}

type ReviewTeamApplicationRequest struct {
	Reply string `json:"reply"`
}

// Accept POST /api/water/team/applications/:id/accept
func (h *WaterTeamHandler) Accept(c *gin.Context) {
	h.reviewApplication(c, models.ApplicationStatusAccepted)
}

// Reject POST /api/water/team/applications/:id/reject
func (h *WaterTeamHandler) Reject(c *gin.Context) {
	h.reviewApplication(c, models.ApplicationStatusRejected)
}

func (h *WaterTeamHandler) reviewApplication(c *gin.Context, newStatus string) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	idStr := c.Param("id")
	appID, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的申请ID"})
		return
	}

	var req ReviewTeamApplicationRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体格式错误"})
		return
	}
	req.Reply = strings.TrimSpace(req.Reply)
	if len([]rune(req.Reply)) > 500 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "队长回复最多500字"})
		return
	}

	var initialApp models.WaterTeamApplication
	if err := h.db.First(&initialApp, appID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "申请不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取申请失败"})
		return
	}

	var reviewedAt time.Time
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var recruitment models.WaterTeamRecruitment
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&recruitment, initialApp.RecruitmentID).Error; err != nil {
			return err
		}

		var app models.WaterTeamApplication
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&app, appID).Error; err != nil {
			return fmt.Errorf("app_not_found")
		}

		if app.RecruitmentID != recruitment.ID {
			return fmt.Errorf("invalid_assoc")
		}

		if app.OwnerID != userID {
			return fmt.Errorf("unauthorized")
		}

		if app.Status != models.ApplicationStatusPending {
			return fmt.Errorf("invalid_status")
		}

		if newStatus == models.ApplicationStatusAccepted {
			now := time.Now()
			effectiveStatus := models.EffectiveRecruitmentStatus(recruitment, now)
			if effectiveStatus != models.RecruitmentStatusRecruiting {
				return fmt.Errorf("recruitment_not_available")
			}
		}

		now := time.Now()
		reviewedAt = now
		if err := tx.Model(&app).Updates(map[string]interface{}{
			"status":      newStatus,
			"reviewed_at": now,
			"owner_reply": req.Reply,
		}).Error; err != nil {
			return err
		}

		if newStatus == models.ApplicationStatusAccepted {
			var acceptedCount int64
			if err := tx.Model(&models.WaterTeamApplication{}).
				Where("recruitment_id = ? AND status = ?", recruitment.ID, models.ApplicationStatusAccepted).
				Count(&acceptedCount).Error; err != nil {
				return err
			}

			if acceptedCount > int64(recruitment.NeededCount) {
				return fmt.Errorf("recruitment_not_available")
			}

			status := models.RecruitmentStatusRecruiting
			if acceptedCount >= int64(recruitment.NeededCount) {
				status = models.RecruitmentStatusFull
			}

			return tx.Model(&recruitment).Updates(map[string]interface{}{
				"accepted_count": acceptedCount,
				"status":         status,
			}).Error
		}

		return nil
	})

	if err != nil {
		switch err.Error() {
		case "app_not_found":
			c.JSON(http.StatusNotFound, gin.H{"error": "申请不存在"})
		case "unauthorized":
			c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		case "invalid_status":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该申请已被处理"})
		case "recruitment_not_available":
			c.JSON(http.StatusBadRequest, gin.H{"error": "名额已满或招募已结束"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "处理失败"})
		}
		return
	}
	resultContent := "你的组队申请已通过"
	if newStatus == models.ApplicationStatusRejected {
		resultContent = "你的组队申请未通过"
	}
	createTeamNotification(h.db, initialApp.ApplicantID, userID, initialApp.RecruitmentID, initialApp.PostID, "team_application_result", fmt.Sprintf("team_application_result:%d:%d", initialApp.ID, reviewedAt.UnixNano()), resultContent)

	c.JSON(http.StatusOK, gin.H{"message": "处理成功"})
}

// Cancel POST /api/water/team/applications/:id/cancel
func (h *WaterTeamHandler) Cancel(c *gin.Context) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	idStr := c.Param("id")
	appID, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的申请ID"})
		return
	}

	err = h.db.Transaction(func(tx *gorm.DB) error {
		var app models.WaterTeamApplication
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&app, appID).Error; err != nil {
			return fmt.Errorf("app_not_found")
		}

		if app.ApplicantID != userID {
			return fmt.Errorf("unauthorized")
		}

		if app.Status != models.ApplicationStatusPending {
			return fmt.Errorf("invalid_status")
		}

		app.Status = models.ApplicationStatusCancelled
		if err := tx.Save(&app).Error; err != nil {
			return err
		}

		return nil
	})

	if err != nil {
		switch err.Error() {
		case "app_not_found":
			c.JSON(http.StatusNotFound, gin.H{"error": "申请不存在"})
		case "unauthorized":
			c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		case "invalid_status":
			c.JSON(http.StatusBadRequest, gin.H{"error": "状态无效"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "取消失败"})
		}
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "已取消"})
}

// Leave 允许已加入成员主动退出队伍。
func (h *WaterTeamHandler) Leave(c *gin.Context) {
	h.changeAcceptedApplication(c, false)
}

// Remove 允许队长移除已加入成员。
func (h *WaterTeamHandler) Remove(c *gin.Context) {
	h.changeAcceptedApplication(c, true)
}

func (h *WaterTeamHandler) changeAcceptedApplication(c *gin.Context, byOwner bool) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}
	appID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的申请ID"})
		return
	}

	var initialApp models.WaterTeamApplication
	if err := h.db.First(&initialApp, appID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "申请不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取申请失败"})
		return
	}

	newStatus := models.ApplicationStatusWithdrawn
	if byOwner {
		newStatus = models.ApplicationStatusRemoved
	}
	eventAt := time.Now()
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var recruitment models.WaterTeamRecruitment
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&recruitment, initialApp.RecruitmentID).Error; err != nil {
			return err
		}
		var app models.WaterTeamApplication
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&app, appID).Error; err != nil {
			return fmt.Errorf("app_not_found")
		}
		if app.RecruitmentID != recruitment.ID {
			return fmt.Errorf("invalid_assoc")
		}
		if (byOwner && app.OwnerID != userID) || (!byOwner && app.ApplicantID != userID) {
			return fmt.Errorf("unauthorized")
		}
		if app.Status != models.ApplicationStatusAccepted {
			return fmt.Errorf("invalid_status")
		}
		eventAt = time.Now()
		if err := tx.Model(&app).Updates(map[string]interface{}{
			"status":      newStatus,
			"reviewed_at": eventAt,
		}).Error; err != nil {
			return err
		}
		var acceptedCount int64
		if err := tx.Model(&models.WaterTeamApplication{}).
			Where("recruitment_id = ? AND status = ?", recruitment.ID, models.ApplicationStatusAccepted).
			Count(&acceptedCount).Error; err != nil {
			return err
		}
		status := recruitment.Status
		if status != models.RecruitmentStatusClosed {
			status = models.RecruitmentStatusRecruiting
			if acceptedCount >= int64(recruitment.NeededCount) {
				status = models.RecruitmentStatusFull
			}
		}
		return tx.Model(&recruitment).Updates(map[string]interface{}{
			"accepted_count": acceptedCount,
			"status":         status,
		}).Error
	})
	if err != nil {
		switch err.Error() {
		case "app_not_found":
			c.JSON(http.StatusNotFound, gin.H{"error": "申请不存在"})
		case "unauthorized":
			c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		case "invalid_status":
			c.JSON(http.StatusBadRequest, gin.H{"error": "只有已加入成员可以执行此操作"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "成员状态更新失败"})
		}
		return
	}

	if byOwner {
		createTeamNotification(h.db, initialApp.ApplicantID, userID, initialApp.RecruitmentID, initialApp.PostID, "team_member_removed", fmt.Sprintf("team_member_removed:%d:%d", initialApp.ID, eventAt.UnixNano()), "你已被移出组队")
	} else {
		createTeamNotification(h.db, initialApp.OwnerID, userID, initialApp.RecruitmentID, initialApp.PostID, "team_member_left", fmt.Sprintf("team_member_left:%d:%d", initialApp.ID, eventAt.UnixNano()), "有成员退出了你的组队")
	}
	c.JSON(http.StatusOK, gin.H{"message": "成员状态已更新"})
}

// GetMyApplications GET /api/water/team/my_applications
func (h *WaterTeamHandler) GetMyApplications(c *gin.Context) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	var apps []models.WaterTeamApplication
	if err := h.db.Preload("Recruitment").Preload("Post").Preload("Post.Author").
		Joins("JOIN posts ON posts.id = water_team_applications.post_id").
		Where("water_team_applications.applicant_id = ? AND posts.status != ?", userID, models.PostStatusDeleted).
		Order("water_team_applications.created_at desc").Find(&apps).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取申请列表失败"})
		return
	}

	c.JSON(http.StatusOK, apps)
}

// GetRecruitmentApplications GET /api/water/team/recruitments/:id/applications
func (h *WaterTeamHandler) GetRecruitmentApplications(c *gin.Context) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	idStr := c.Param("id")
	recruitmentID, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的招募ID"})
		return
	}

	var recruitment models.WaterTeamRecruitment
	if err := h.db.Preload("Post").First(&recruitment, recruitmentID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "招募信息不存在"})
		return
	}

	if recruitment.Post.AuthorID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		return
	}

	var apps []models.WaterTeamApplication
	if err := h.db.Preload("Applicant").Where("recruitment_id = ?", recruitmentID).Order("created_at desc").Find(&apps).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取申请列表失败"})
		return
	}

	c.JSON(http.StatusOK, apps)
}

// UpdateRecruitmentStatus PATCH /api/water/team/recruitments/:id/status
func (h *WaterTeamHandler) UpdateRecruitmentStatus(c *gin.Context) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	idStr := c.Param("id")
	recruitmentID, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的招募ID"})
		return
	}

	var req UpdateTeamRecruitmentStatusRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体格式错误"})
		return
	}

	if req.Status != string(models.RecruitmentStatusClosed) && req.Status != string(models.RecruitmentStatusRecruiting) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的招募状态"})
		return
	}

	var responsePost models.Post
	var initialRecruitment models.WaterTeamRecruitment
	if err := h.db.First(&initialRecruitment, recruitmentID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "未找到该招募信息"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取招募信息失败"})
		return
	}

	err = h.db.Transaction(func(tx *gorm.DB) error {
		var post models.Post
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&post, initialRecruitment.PostID).Error; err != nil {
			return fmt.Errorf("post_not_found")
		}

		var recruitment models.WaterTeamRecruitment
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&recruitment, recruitmentID).Error; err != nil {
			return fmt.Errorf("recruitment_not_found")
		}

		if recruitment.PostID != post.ID {
			return fmt.Errorf("mismatch")
		}

		if post.AuthorID != userID {
			return fmt.Errorf("unauthorized")
		}

		if post.Status == models.PostStatusDeleted {
			return fmt.Errorf("post_deleted")
		}

		if req.Status == string(models.RecruitmentStatusClosed) {
			if recruitment.Status != models.RecruitmentStatusRecruiting && recruitment.Status != models.RecruitmentStatusFull {
				return fmt.Errorf("cannot_close")
			}
			recruitment.Status = models.RecruitmentStatusClosed
		} else if req.Status == string(models.RecruitmentStatusRecruiting) {
			if recruitment.Status != models.RecruitmentStatusClosed {
				return fmt.Errorf("cannot_reopen")
			}

			if post.WaterTagID == nil {
				return fmt.Errorf("invalid_tag")
			}

			var tag models.WaterSectionTag
			if err := tx.First(&tag, *post.WaterTagID).Error; err != nil {
				return fmt.Errorf("invalid_tag")
			}

			if tag.ContentMode != models.WaterTagModeTeamRecruitment {
				return fmt.Errorf("tag_disabled")
			}

			var section models.WaterSection
			if err := tx.First(&section, tag.SectionID).Error; err != nil {
				return fmt.Errorf("invalid_section")
			}

			if section.Status != "active" {
				return fmt.Errorf("section_inactive")
			}

			if recruitment.Deadline != nil && recruitment.Deadline.Before(time.Now()) {
				return fmt.Errorf("deadline_passed")
			}

			var acceptedCount int64
			if err := tx.Model(&models.WaterTeamApplication{}).Where("recruitment_id = ? AND status = ?", recruitment.ID, models.ApplicationStatusAccepted).Count(&acceptedCount).Error; err != nil {
				return err
			}

			recruitment.AcceptedCount = int(acceptedCount)
			if recruitment.AcceptedCount >= recruitment.NeededCount {
				return fmt.Errorf("already_full")
			}

			recruitment.Status = models.RecruitmentStatusRecruiting
		}

		if err := tx.Save(&recruitment).Error; err != nil {
			return err
		}

		if err := tx.Preload("Author").Preload("Images").Preload("Images.File").Scopes(withPostImageVariants).First(&responsePost, post.ID).Error; err != nil {
			return err
		}

		return nil
	})

	if err != nil {
		switch err.Error() {
		case "recruitment_not_found":
			c.JSON(http.StatusNotFound, gin.H{"error": "招募信息不存在"})
		case "post_not_found":
			c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		case "unauthorized":
			c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		case "post_deleted":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该帖子已被删除或屏蔽"})
		case "cannot_close":
			c.JSON(http.StatusBadRequest, gin.H{"error": "当前状态无法关闭"})
		case "cannot_reopen":
			c.JSON(http.StatusBadRequest, gin.H{"error": "当前状态无法重新开启"})
		case "invalid_tag", "tag_disabled":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该标签不支持组队招募"})
		case "invalid_section", "section_inactive":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该版块已归档或不存在"})
		case "deadline_passed":
			c.JSON(http.StatusBadRequest, gin.H{"error": "截止时间已过，请先修改截止时间"})
		case "already_full":
			c.JSON(http.StatusBadRequest, gin.H{"error": "名额已满，无法重新开启"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "处理失败"})
		}
		return
	}

	postHandler := &PostHandler{db: h.db}
	responsePosts := []models.Post{responsePost}
	postHandler.hydratePosts(c, responsePosts, time.Now())

	c.JSON(http.StatusOK, gin.H{"post": responsePosts[0]})
}

package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strings"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// WaterSectionHandler 水帖版块处理器
type WaterSectionHandler struct {
	db      *gorm.DB
	permSvc *services.WaterPermissionService
}

// NewWaterSectionHandler 构造版块处理器
func NewWaterSectionHandler(db *gorm.DB) *WaterSectionHandler {
	return &WaterSectionHandler{
		db:      db,
		permSvc: services.NewWaterPermissionService(db),
	}
}

// waterSectionTagResponse 版块内标签响应体
type waterSectionTagResponse struct {
	ID          uint   `json:"id"`
	Slug        string `json:"slug"`
	Name        string `json:"name"`
	Description string `json:"description"`
	SortOrder   int    `json:"sort_order"`
	IsDefault   bool   `json:"is_default"`
	IsEnabled   bool   `json:"is_enabled"`
}

// waterSectionResponse 版块响应体
type waterSectionResponse struct {
	ID                uint                      `json:"id"`
	Slug              string                    `json:"slug"`
	Title             string                    `json:"title"`
	Subtitle          string                    `json:"subtitle"`
	Description       string                    `json:"description"`
	IconKey           string                    `json:"icon_key"`
	ColorHex          string                    `json:"color_hex"`
	PublishActionText string                    `json:"publish_action_text"`
	EmptyTitle        string                    `json:"empty_title"`
	EmptyDescription  string                    `json:"empty_description"`
	StarterQuestions  []string                  `json:"starter_questions"`
	NoticeText        string                    `json:"notice_text"`
	SensitiveLevel    string                    `json:"sensitive_level"`
	DefaultSort       string                    `json:"default_sort"`
	SortOrder         int                       `json:"sort_order"`
	Status            string                    `json:"status"`
	Tags              []waterSectionTagResponse `json:"tags"`
}

type updateWaterSectionRequest struct {
	Title             *string   `json:"title"`
	Subtitle          *string   `json:"subtitle"`
	Description       *string   `json:"description"`
	IconKey           *string   `json:"icon_key"`
	ColorHex          *string   `json:"color_hex"`
	PublishActionText *string   `json:"publish_action_text"`
	EmptyTitle        *string   `json:"empty_title"`
	EmptyDescription  *string   `json:"empty_description"`
	StarterQuestions  *[]string `json:"starter_questions"`
	NoticeText        *string   `json:"notice_text"`
	DefaultSort       *string   `json:"default_sort"`
	Reason            string    `json:"reason"`
}

type waterSectionEditSnapshot struct {
	Title             string   `json:"title"`
	Subtitle          string   `json:"subtitle"`
	Description       string   `json:"description"`
	IconKey           string   `json:"icon_key"`
	ColorHex          string   `json:"color_hex"`
	PublishActionText string   `json:"publish_action_text"`
	EmptyTitle        string   `json:"empty_title"`
	EmptyDescription  string   `json:"empty_description"`
	StarterQuestions  []string `json:"starter_questions"`
	NoticeText        string   `json:"notice_text"`
	DefaultSort       string   `json:"default_sort"`
}

var waterSectionColorPattern = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)

// toTagResponse 把 WaterSectionTag 转成响应体
func toTagResponse(tag models.WaterSectionTag) waterSectionTagResponse {
	return waterSectionTagResponse{
		ID:          tag.ID,
		Slug:        tag.Slug,
		Name:        tag.Name,
		Description: tag.Description,
		SortOrder:   tag.SortOrder,
		IsDefault:   tag.IsDefault,
		IsEnabled:   tag.IsEnabled,
	}
}

// toSectionResponse 把 WaterSection 转成响应体，解析 StarterQuestionsJSON
func toSectionResponse(section models.WaterSection) waterSectionResponse {
	resp := waterSectionResponse{
		ID:                section.ID,
		Slug:              section.Slug,
		Title:             section.Title,
		Subtitle:          section.Subtitle,
		Description:       section.Description,
		IconKey:           section.IconKey,
		ColorHex:          section.ColorHex,
		PublishActionText: section.PublishActionText,
		EmptyTitle:        section.EmptyTitle,
		EmptyDescription:  section.EmptyDescription,
		StarterQuestions:  []string{},
		NoticeText:        section.NoticeText,
		SensitiveLevel:    section.SensitiveLevel,
		DefaultSort:       section.DefaultSort,
		SortOrder:         section.SortOrder,
		Status:            section.Status,
	}
	if section.StarterQuestionsJSON != "" {
		var qs []string
		if err := json.Unmarshal([]byte(section.StarterQuestionsJSON), &qs); err == nil {
			resp.StarterQuestions = qs
		}
	}
	resp.Tags = make([]waterSectionTagResponse, 0, len(section.Tags))
	for _, tag := range section.Tags {
		resp.Tags = append(resp.Tags, toTagResponse(tag))
	}
	return resp
}

func waterSectionSnapshot(section models.WaterSection) waterSectionEditSnapshot {
	questions := []string{}
	if section.StarterQuestionsJSON != "" {
		_ = json.Unmarshal([]byte(section.StarterQuestionsJSON), &questions)
	}
	return waterSectionEditSnapshot{
		Title:             section.Title,
		Subtitle:          section.Subtitle,
		Description:       section.Description,
		IconKey:           section.IconKey,
		ColorHex:          section.ColorHex,
		PublishActionText: section.PublishActionText,
		EmptyTitle:        section.EmptyTitle,
		EmptyDescription:  section.EmptyDescription,
		StarterQuestions:  questions,
		NoticeText:        section.NoticeText,
		DefaultSort:       section.DefaultSort,
	}
}

func runeLen(s string) int {
	return len([]rune(s))
}

func validateMaxLen(value string, max int, fieldName string) string {
	if runeLen(value) > max {
		return fmt.Sprintf("%s最多 %d 字", fieldName, max)
	}
	return ""
}

func validateWaterSectionDefaultSort(value string) bool {
	switch value {
	case "all", "time", "latest", "featured", "following", "recommend":
		return true
	default:
		return false
	}
}

func (h *WaterSectionHandler) currentUserOr401(c *gin.Context) (*models.User, bool) {
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未登录"})
		return nil, false
	}
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "用户不存在"})
		return nil, false
	}
	return &user, true
}

func (h *WaterSectionHandler) writeEditSectionLog(sectionID, operatorID uint, reason string, snapshot string) {
	log := models.WaterModerationLog{
		SectionID:  sectionID,
		OperatorID: operatorID,
		Action:     models.ModActionEditSection,
		TargetType: "section",
		TargetID:   sectionID,
		Reason:     reason,
		Snapshot:   snapshot,
	}
	if err := h.db.Create(&log).Error; err != nil {
		fmt.Printf("[WaterSection] write edit log failed: %v\n", err)
	}
}

// List GET /api/water/sections
// 返回所有 active 版块，按 sort_order 升序；每个版块只带 enabled 标签。
func (h *WaterSectionHandler) List(c *gin.Context) {
	var sections []models.WaterSection
	if err := h.db.
		Where("status = ?", "active").
		Preload("Tags", "is_enabled = ?", true).
		Order("sort_order ASC").
		Find(&sections).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取版块列表失败"})
		return
	}
	resp := make([]waterSectionResponse, 0, len(sections))
	for _, section := range sections {
		resp = append(resp, toSectionResponse(section))
	}
	c.JSON(http.StatusOK, gin.H{"sections": resp})
}

// Get GET /api/water/sections/:slug
// 返回单个 active 版块；不存在或非 active 返回 404。
func (h *WaterSectionHandler) Get(c *gin.Context) {
	slug := c.Param("slug")
	if slug == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少版块标识"})
		return
	}
	var section models.WaterSection
	err := h.db.
		Where("slug = ? AND status = ?", slug, "active").
		Preload("Tags", "is_enabled = ?", true).
		First(&section).Error
	if err == gorm.ErrRecordNotFound {
		c.JSON(http.StatusNotFound, gin.H{"error": "版块不存在"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取版块失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"section": toSectionResponse(section)})
}

// Update PATCH /api/water/sections/:slug
// 编辑版块展示文案；仅 admin/super_admin 或本版块 can_edit_section=true 的版主可操作。
func (h *WaterSectionHandler) Update(c *gin.Context) {
	operator, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	slug := c.Param("slug")
	if slug == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少版块标识"})
		return
	}

	var section models.WaterSection
	err := h.db.Where("slug = ? AND status = ?", slug, "active").First(&section).Error
	if err == gorm.ErrRecordNotFound {
		c.JSON(http.StatusNotFound, gin.H{"error": "版块不存在"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取版块失败"})
		return
	}

	if !h.permSvc.CanEditSection(section.ID, operator) {
		c.JSON(http.StatusForbidden, gin.H{"error": "没有编辑版块展示的权限"})
		return
	}

	var req updateWaterSectionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体格式错误"})
		return
	}

	changed := false
	before := waterSectionSnapshot(section)

	if req.Title != nil {
		title := strings.TrimSpace(*req.Title)
		if title == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "标题不能为空"})
			return
		}
		if msg := validateMaxLen(title, 64, "标题"); msg != "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": msg})
			return
		}
		section.Title = title
		changed = true
	}
	if req.Subtitle != nil {
		subtitle := strings.TrimSpace(*req.Subtitle)
		if msg := validateMaxLen(subtitle, 200, "副标题"); msg != "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": msg})
			return
		}
		section.Subtitle = subtitle
		changed = true
	}
	if req.Description != nil {
		description := strings.TrimSpace(*req.Description)
		if msg := validateMaxLen(description, 1000, "描述"); msg != "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": msg})
			return
		}
		section.Description = description
		changed = true
	}
	if req.IconKey != nil {
		iconKey := strings.TrimSpace(*req.IconKey)
		if msg := validateMaxLen(iconKey, 64, "图标"); msg != "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": msg})
			return
		}
		section.IconKey = iconKey
		changed = true
	}
	if req.ColorHex != nil {
		colorHex := strings.TrimSpace(*req.ColorHex)
		if colorHex != "" && !waterSectionColorPattern.MatchString(colorHex) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "颜色必须为空或符合 #RRGGBB"})
			return
		}
		section.ColorHex = colorHex
		changed = true
	}
	if req.PublishActionText != nil {
		text := strings.TrimSpace(*req.PublishActionText)
		if msg := validateMaxLen(text, 40, "发布按钮文案"); msg != "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": msg})
			return
		}
		section.PublishActionText = text
		changed = true
	}
	if req.EmptyTitle != nil {
		emptyTitle := strings.TrimSpace(*req.EmptyTitle)
		if msg := validateMaxLen(emptyTitle, 100, "空状态标题"); msg != "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": msg})
			return
		}
		section.EmptyTitle = emptyTitle
		changed = true
	}
	if req.EmptyDescription != nil {
		emptyDescription := strings.TrimSpace(*req.EmptyDescription)
		if msg := validateMaxLen(emptyDescription, 300, "空状态描述"); msg != "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": msg})
			return
		}
		section.EmptyDescription = emptyDescription
		changed = true
	}
	if req.StarterQuestions != nil {
		questions := make([]string, 0, len(*req.StarterQuestions))
		if len(*req.StarterQuestions) > 10 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "引导问题最多 10 条"})
			return
		}
		for _, q := range *req.StarterQuestions {
			question := strings.TrimSpace(q)
			if msg := validateMaxLen(question, 80, "引导问题"); msg != "" {
				c.JSON(http.StatusBadRequest, gin.H{"error": msg})
				return
			}
			questions = append(questions, question)
		}
		questionsJSON, err := json.Marshal(questions)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "保存引导问题失败"})
			return
		}
		section.StarterQuestionsJSON = string(questionsJSON)
		changed = true
	}
	if req.NoticeText != nil {
		noticeText := strings.TrimSpace(*req.NoticeText)
		if msg := validateMaxLen(noticeText, 1000, "公告文案"); msg != "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": msg})
			return
		}
		section.NoticeText = noticeText
		changed = true
	}
	if req.DefaultSort != nil {
		defaultSort := strings.TrimSpace(*req.DefaultSort)
		if !validateWaterSectionDefaultSort(defaultSort) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "默认排序不合法"})
			return
		}
		section.DefaultSort = defaultSort
		changed = true
	}
	if !changed {
		c.JSON(http.StatusBadRequest, gin.H{"error": "没有可更新字段"})
		return
	}

	if err := h.db.Save(&section).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存版块失败"})
		return
	}
	after := waterSectionSnapshot(section)
	snapshot, _ := json.Marshal(gin.H{"before": before, "after": after})
	reason := strings.TrimSpace(req.Reason)
	if reason == "" {
		reason = "编辑版块展示"
	}
	h.writeEditSectionLog(section.ID, operator.ID, reason, string(snapshot))

	if err := h.db.Preload("Tags", "is_enabled = ?", true).First(&section, section.ID).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取版块失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"section": toSectionResponse(section)})
}

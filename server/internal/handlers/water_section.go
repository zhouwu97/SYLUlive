package handlers

import (
	"encoding/json"
	"net/http"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// WaterSectionHandler 水帖版块处理器
type WaterSectionHandler struct {
	db *gorm.DB
}

// NewWaterSectionHandler 构造版块处理器
func NewWaterSectionHandler(db *gorm.DB) *WaterSectionHandler {
	return &WaterSectionHandler{db: db}
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
	Tags              []waterSectionTagResponse  `json:"tags"`
}

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
		PublishActionText:  section.PublishActionText,
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
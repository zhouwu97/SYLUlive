package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"errors"
	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5/pgconn"
	"gorm.io/gorm"

	"shenliyuan/internal/config"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"shenliyuan/internal/utils"
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

type waterSectionTagResponse struct {
	ID          uint   `json:"id"`
	Slug        string `json:"slug"`
	Name        string `json:"name"`
	Description string `json:"description"`
	ContentMode string `json:"content_mode"`
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
	AvatarURL         string                    `json:"avatar_url"`
	ColorHex          string                    `json:"color_hex"`
	CoverURL          string                    `json:"cover_url"`           // 版块背景图（兼容）
	CoverPortraitURL  string                    `json:"cover_portrait_url"`  // 手机版块背景 3:4
	CoverLandscapeURL string                    `json:"cover_landscape_url"` // 横向封面 16:9
	CoverSquareURL    string                    `json:"cover_square_url"`    // 方形入口 1:1
	CoverBlurColor    string                    `json:"cover_blur_color"`    // 加载前底色
	PublishActionText string                    `json:"publish_action_text"`
	EmptyTitle        string                    `json:"empty_title"`
	EmptyDescription  string                    `json:"empty_description"`
	StarterQuestions  []string                  `json:"starter_questions"`
	NoticeText        string                    `json:"notice_text"`
	SensitiveLevel    string                    `json:"sensitive_level"`
	DefaultSort       string                    `json:"default_sort"`
	SortOrder         int                       `json:"sort_order"`
	Status            string                    `json:"status"`
	IsFollowed        bool                      `json:"is_followed"`
	PostCount         int64                     `json:"post_count"`
	FollowerCount     int64                     `json:"follower_count"`
	MyLevel           *waterSectionMyLevelBrief `json:"my_level,omitempty"`
	Tags              []waterSectionTagResponse `json:"tags"`
}

// waterSectionMyLevelBrief 版块列表中返回的当前用户本版等级简要信息
type waterSectionMyLevelBrief struct {
	Level           int     `json:"level"`
	Title           string  `json:"title"`
	Exp             int     `json:"exp"`
	CurrentLevelExp int     `json:"current_level_exp"`
	NextLevelExp    int     `json:"next_level_exp"`
	ExpToNext       int     `json:"exp_to_next"`
	Progress        float64 `json:"progress"`
}

type updateWaterSectionRequest struct {
	Title             *string   `json:"title"`
	Subtitle          *string   `json:"subtitle"`
	Description       *string   `json:"description"`
	IconKey           *string   `json:"icon_key"`
	AvatarURL         *string   `json:"avatar_url"`
	ColorHex          *string   `json:"color_hex"`
	CoverURL          *string   `json:"cover_url"` // 兼容旧字段
	CoverPortraitURL  *string   `json:"cover_portrait_url"`
	CoverLandscapeURL *string   `json:"cover_landscape_url"`
	CoverSquareURL    *string   `json:"cover_square_url"`
	CoverBlurColor    *string   `json:"cover_blur_color"`
	PublishActionText *string   `json:"publish_action_text"`
	EmptyTitle        *string   `json:"empty_title"`
	EmptyDescription  *string   `json:"empty_description"`
	StarterQuestions  *[]string `json:"starter_questions"`
	NoticeText        *string   `json:"notice_text"`
	DefaultSort       *string   `json:"default_sort"`
	Reason            string    `json:"reason"`
}

type createWaterSectionTagRequest struct {
	Slug        string `json:"slug"`
	Name        string `json:"name"`
	Description string `json:"description"`
	ContentMode string `json:"content_mode"`
	SortOrder   int    `json:"sort_order"`
	IsDefault   bool   `json:"is_default"`
	Reason      string `json:"reason"`
}

type updateWaterSectionTagRequest struct {
	Name        *string `json:"name"`
	Description *string `json:"description"`
	SortOrder   *int    `json:"sort_order"`
	IsDefault   *bool   `json:"is_default"`
	Reason      string  `json:"reason"`
}

type updateWaterSectionTagStatusRequest struct {
	IsEnabled *bool  `json:"is_enabled"`
	Reason    string `json:"reason"`
}

type waterSectionEditSnapshot struct {
	Title             string   `json:"title"`
	Subtitle          string   `json:"subtitle"`
	Description       string   `json:"description"`
	IconKey           string   `json:"icon_key"`
	AvatarURL         string   `json:"avatar_url"`
	ColorHex          string   `json:"color_hex"`
	CoverURL          string   `json:"cover_url"`
	CoverPortraitURL  string   `json:"cover_portrait_url"`
	CoverLandscapeURL string   `json:"cover_landscape_url"`
	CoverSquareURL    string   `json:"cover_square_url"`
	CoverBlurColor    string   `json:"cover_blur_color"`
	PublishActionText string   `json:"publish_action_text"`
	EmptyTitle        string   `json:"empty_title"`
	EmptyDescription  string   `json:"empty_description"`
	StarterQuestions  []string `json:"starter_questions"`
	NoticeText        string   `json:"notice_text"`
	DefaultSort       string   `json:"default_sort"`
}

type waterSectionTagSnapshot struct {
	ID          uint   `json:"id"`
	SectionID   uint   `json:"section_id"`
	Slug        string `json:"slug"`
	Name        string `json:"name"`
	Description string `json:"description"`
	ContentMode string `json:"content_mode"`
	SortOrder   int    `json:"sort_order"`
	IsDefault   bool   `json:"is_default"`
	IsEnabled   bool   `json:"is_enabled"`
}

var waterSectionColorPattern = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)
var waterSectionTagSlugPattern = regexp.MustCompile(`^[a-z0-9_-]{1,64}$`)

func toTagResponse(tag models.WaterSectionTag) waterSectionTagResponse {
	return waterSectionTagResponse{
		ID:          tag.ID,
		Slug:        tag.Slug,
		Name:        tag.Name,
		Description: tag.Description,
		ContentMode: tag.ContentMode,
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
		AvatarURL:         section.AvatarURL,
		ColorHex:          section.ColorHex,
		CoverURL:          section.CoverURL,
		CoverPortraitURL:  section.CoverPortraitURL,
		CoverLandscapeURL: section.CoverLandscapeURL,
		CoverSquareURL:    section.CoverSquareURL,
		CoverBlurColor:    section.CoverBlurColor,
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
		AvatarURL:         section.AvatarURL,
		ColorHex:          section.ColorHex,
		CoverURL:          section.CoverURL,
		CoverPortraitURL:  section.CoverPortraitURL,
		CoverLandscapeURL: section.CoverLandscapeURL,
		CoverSquareURL:    section.CoverSquareURL,
		CoverBlurColor:    section.CoverBlurColor,
		PublishActionText: section.PublishActionText,
		EmptyTitle:        section.EmptyTitle,
		EmptyDescription:  section.EmptyDescription,
		StarterQuestions:  questions,
		NoticeText:        section.NoticeText,
		DefaultSort:       section.DefaultSort,
	}
}

func waterSectionTagSnapshotFrom(tag models.WaterSectionTag) waterSectionTagSnapshot {
	return waterSectionTagSnapshot{
		ID:          tag.ID,
		SectionID:   tag.SectionID,
		Slug:        tag.Slug,
		Name:        tag.Name,
		Description: tag.Description,
		ContentMode: tag.ContentMode,
		SortOrder:   tag.SortOrder,
		IsDefault:   tag.IsDefault,
		IsEnabled:   tag.IsEnabled,
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

func validateTagSlug(value string) string {
	if value == "" {
		return "标签标识不能为空"
	}
	if !waterSectionTagSlugPattern.MatchString(value) {
		return "标签标识只允许小写英文、数字、下划线、短横线"
	}
	return ""
}

func validateTagName(value string) string {
	if value == "" {
		return "标签名称不能为空"
	}
	if msg := validateMaxLen(value, 40, "标签名称"); msg != "" {
		return msg
	}
	return ""
}

func validateTagDescription(value string) string {
	return validateMaxLen(value, 200, "标签描述")
}

func (h *WaterSectionHandler) currentUserOr401(c *gin.Context) (*models.User, bool) {
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未登录", "code": "authentication_required"})
		return nil, false
	}
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "用户不存在", "code": "authentication_required"})
		return nil, false
	}
	return &user, true
}

func (h *WaterSectionHandler) getActiveSectionOr404(c *gin.Context) (*models.WaterSection, bool) {
	slug := c.Param("slug")
	if slug == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少版块标识"})
		return nil, false
	}
	var section models.WaterSection
	err := h.db.Where("slug = ? AND status = ?", slug, "active").First(&section).Error
	if err == gorm.ErrRecordNotFound {
		c.JSON(http.StatusNotFound, gin.H{"error": "版块不存在"})
		return nil, false
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取版块失败"})
		return nil, false
	}
	return &section, true
}

func (h *WaterSectionHandler) getTagInSectionOr404(c *gin.Context, sectionID uint) (*models.WaterSectionTag, bool) {
	tagID := c.Param("tag_id")
	var tag models.WaterSectionTag
	err := h.db.Where("id = ? AND section_id = ?", tagID, sectionID).First(&tag).Error
	if err == gorm.ErrRecordNotFound {
		c.JSON(http.StatusNotFound, gin.H{"error": "标签不存在"})
		return nil, false
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取标签失败"})
		return nil, false
	}
	return &tag, true
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

func (h *WaterSectionHandler) writeTagLog(sectionID, operatorID uint, action string, tagID uint, reason string, snapshot string) {
	log := models.WaterModerationLog{
		SectionID:  sectionID,
		OperatorID: operatorID,
		Action:     action,
		TargetType: "tag",
		TargetID:   tagID,
		Reason:     reason,
		Snapshot:   snapshot,
	}
	if err := h.db.Create(&log).Error; err != nil {
		fmt.Printf("[WaterSection] write tag log failed: %v\n", err)
	}
}

func (h *WaterSectionHandler) ensureCanManageTags(c *gin.Context, sectionID uint, operator *models.User) bool {
	if h.permSvc.CanManageTags(sectionID, operator) {
		return true
	}
	c.JSON(http.StatusForbidden, gin.H{"error": "没有管理标签的权限"})
	return false
}

func (h *WaterSectionHandler) tagValueExists(sectionID uint, column string, value string, excludeID uint) (bool, error) {
	query := h.db.Model(&models.WaterSectionTag{}).Where("section_id = ? AND "+column+" = ?", sectionID, value)
	if excludeID != 0 {
		query = query.Where("id <> ?", excludeID)
	}
	var count int64
	if err := query.Count(&count).Error; err != nil {
		return false, err
	}
	return count > 0, nil
}

func (h *WaterSectionHandler) fillIsFollowed(c *gin.Context, resps []waterSectionResponse) []waterSectionResponse {
	userIDVal, exists := c.Get("user_id")
	if !exists {
		return resps
	}
	uid, ok := userIDVal.(uint)
	if !ok || uid == 0 {
		// 可能是 float64 等类型，如果类型断言失败，尝试直接转换
		return resps
	}

	sectionIDs := make([]uint, len(resps))
	for i, r := range resps {
		sectionIDs[i] = r.ID
	}
	if len(sectionIDs) == 0 {
		return resps
	}

	var follows []models.WaterSectionFollow
	h.db.Where("user_id = ? AND section_id IN ?", uid, sectionIDs).Find(&follows)

	followMap := make(map[uint]bool)
	for _, f := range follows {
		followMap[f.SectionID] = true
	}

	for i := range resps {
		resps[i].IsFollowed = followMap[resps[i].ID]
	}
	return resps
}

// fillSectionStats 批量填充版块的帖子数和关注人数
func (h *WaterSectionHandler) fillSectionStats(resps []waterSectionResponse) []waterSectionResponse {
	if len(resps) == 0 {
		return resps
	}

	sectionIDs := make([]uint, len(resps))
	slugs := make([]string, len(resps))
	for i, r := range resps {
		sectionIDs[i] = r.ID
		slugs[i] = r.Slug
	}

	// 批量查询关注人数
	type followerCountResult struct {
		SectionID uint  `gorm:"column:section_id"`
		Count     int64 `gorm:"column:count"`
	}
	var followerCounts []followerCountResult
	h.db.Model(&models.WaterSectionFollow{}).
		Select("section_id, COUNT(*) as count").
		Where("section_id IN ?", sectionIDs).
		Group("section_id").
		Scan(&followerCounts)

	followerMap := make(map[uint]int64)
	for _, fc := range followerCounts {
		followerMap[fc.SectionID] = fc.Count
	}

	// 批量查询帖子数（按 post_type 匹配 section slug，board_id=1 为水帖版块）
	type postCountResult struct {
		PostType string `gorm:"column:post_type"`
		Count    int64  `gorm:"column:count"`
	}
	var postCounts []postCountResult
	h.db.Model(&models.Post{}).
		Select("post_type, COUNT(*) as count").
		Where("board_id = ? AND content_kind <> ? AND post_type IN ? AND status = ?", models.BoardShuitie, models.PostContentKindPoll, slugs, models.PostStatusNormal).
		Group("post_type").
		Scan(&postCounts)

	postCountMap := make(map[string]int64)
	for _, pc := range postCounts {
		postCountMap[pc.PostType] = pc.Count
	}

	for i := range resps {
		resps[i].FollowerCount = followerMap[resps[i].ID]
		resps[i].PostCount = postCountMap[resps[i].Slug]
	}
	return resps
}

// buildMyLevelBrief 构建当前用户在版块的等级简要信息
func (h *WaterSectionHandler) buildMyLevelBrief(sectionID uint, userID uint) *waterSectionMyLevelBrief {
	var stat models.WaterSectionUserStat
	err := h.db.Where("user_id = ? AND section_id = ?", userID, sectionID).First(&stat).Error
	if err != nil && err != gorm.ErrRecordNotFound {
		return nil
	}

	exp := 0
	if err == nil {
		exp = stat.Exp
	}

	level := services.CalculateWaterSectionLevel(exp)
	title := services.GetWaterSectionLevelTitle(h.db, sectionID, level)
	currentMin := services.WaterSectionLevelMinExp(level)
	nextExp := services.NextWaterSectionLevelExp(level)

	expToNext := 0
	progress := 0.0
	if nextExp > 0 {
		requiredExp := nextExp - currentMin
		progressExp := exp - currentMin
		if progressExp < 0 {
			progressExp = 0
		}
		if progressExp > requiredExp {
			progressExp = requiredExp
		}
		expToNext = requiredExp - progressExp
		if requiredExp > 0 {
			progress = float64(progressExp) / float64(requiredExp)
		} else {
			progress = 1.0
		}
	} else {
		// 满级
		progress = 1.0
	}

	return &waterSectionMyLevelBrief{
		Level:           level,
		Title:           title,
		Exp:             exp,
		CurrentLevelExp: currentMin,
		NextLevelExp:    nextExp,
		ExpToNext:       expToNext,
		Progress:        progress,
	}
}

// fillMyLevel 批量填充当前用户在各版块的等级信息
func (h *WaterSectionHandler) fillMyLevel(c *gin.Context, resps []waterSectionResponse) []waterSectionResponse {
	userIDVal, exists := c.Get("user_id")
	if !exists {
		return resps
	}
	uid, ok := userIDVal.(uint)
	if !ok || uid == 0 {
		return resps
	}

	sectionIDs := make([]uint, len(resps))
	for i, r := range resps {
		sectionIDs[i] = r.ID
	}
	if len(sectionIDs) == 0 {
		return resps
	}

	// 批量查询用户在各版块的统计
	var stats []models.WaterSectionUserStat
	h.db.Where("user_id = ? AND section_id IN ?", uid, sectionIDs).Find(&stats)

	statMap := make(map[uint]models.WaterSectionUserStat)
	for _, s := range stats {
		statMap[s.SectionID] = s
	}

	for i := range resps {
		sectionID := resps[i].ID
		stat, hasStat := statMap[sectionID]

		exp := 0
		if hasStat {
			exp = stat.Exp
		}

		level := services.CalculateWaterSectionLevel(exp)
		title := services.GetWaterSectionLevelTitle(h.db, sectionID, level)
		currentMin := services.WaterSectionLevelMinExp(level)
		nextExp := services.NextWaterSectionLevelExp(level)

		expToNext := 0
		progress := 0.0
		if nextExp > 0 {
			requiredExp := nextExp - currentMin
			progressExp := exp - currentMin
			if progressExp < 0 {
				progressExp = 0
			}
			if progressExp > requiredExp {
				progressExp = requiredExp
			}
			expToNext = requiredExp - progressExp
			if requiredExp > 0 {
				progress = float64(progressExp) / float64(requiredExp)
			} else {
				progress = 1.0
			}
		} else {
			progress = 1.0
		}

		resps[i].MyLevel = &waterSectionMyLevelBrief{
			Level:           level,
			Title:           title,
			Exp:             exp,
			CurrentLevelExp: currentMin,
			NextLevelExp:    nextExp,
			ExpToNext:       expToNext,
			Progress:        progress,
		}
	}
	return resps
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
	resp = h.fillIsFollowed(c, resp)
	resp = h.fillSectionStats(resp)
	resp = h.fillMyLevel(c, resp)
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

	includeDisabledTags := c.Query("include_disabled_tags") == "true"
	var section models.WaterSection
	query := h.db.Where("slug = ? AND status = ?", slug, "active")
	if includeDisabledTags {
		query = query.Preload("Tags")
	} else {
		query = query.Preload("Tags", "is_enabled = ?", true)
	}
	err := query.First(&section).Error
	if err == gorm.ErrRecordNotFound {
		c.JSON(http.StatusNotFound, gin.H{"error": "版块不存在"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取版块失败"})
		return
	}
	if includeDisabledTags {
		operator, ok := h.currentUserOr401(c)
		if !ok {
			return
		}
		if !h.ensureCanManageTags(c, section.ID, operator) {
			return
		}
	}
	resp := toSectionResponse(section)
	respArr := h.fillIsFollowed(c, []waterSectionResponse{resp})
	respArr = h.fillSectionStats(respArr)
	respArr = h.fillMyLevel(c, respArr)
	c.JSON(http.StatusOK, gin.H{"section": respArr[0]})
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
	if req.IconKey != nil || req.AvatarURL != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "图标请通过审核申请修改"})
		return
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
	if req.CoverURL != nil {
		coverURL := strings.TrimSpace(*req.CoverURL)
		if msg := validateMaxLen(coverURL, 500, "背景图地址"); msg != "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": msg})
			return
		}
		section.CoverURL = coverURL
		changed = true
	}
	if req.CoverPortraitURL != nil {
		coverPortraitURL := strings.TrimSpace(*req.CoverPortraitURL)
		if msg := validateMaxLen(coverPortraitURL, 500, "竖屏背景图地址"); msg != "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": msg})
			return
		}
		section.CoverPortraitURL = coverPortraitURL
		changed = true
	}
	if req.CoverLandscapeURL != nil {
		coverLandscapeURL := strings.TrimSpace(*req.CoverLandscapeURL)
		if msg := validateMaxLen(coverLandscapeURL, 500, "横版封面地址"); msg != "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": msg})
			return
		}
		section.CoverLandscapeURL = coverLandscapeURL
		changed = true
	}
	if req.CoverSquareURL != nil {
		coverSquareURL := strings.TrimSpace(*req.CoverSquareURL)
		if msg := validateMaxLen(coverSquareURL, 500, "方形封面地址"); msg != "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": msg})
			return
		}
		section.CoverSquareURL = coverSquareURL
		changed = true
	}
	if req.CoverBlurColor != nil {
		coverBlurColor := strings.TrimSpace(*req.CoverBlurColor)
		if coverBlurColor != "" && !waterSectionColorPattern.MatchString(coverBlurColor) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "占位颜色必须为空或符合 #RRGGBB"})
			return
		}
		section.CoverBlurColor = coverBlurColor
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
	if err := services.ClaimPublicImagePaths(h.db,
		section.CoverURL,
		section.CoverPortraitURL,
		section.CoverLandscapeURL,
		section.CoverSquareURL,
	); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "公开版块图片失败"})
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

// CreateTag POST /api/water/sections/:slug/tags
// 新增版块标签；不做全站标签，也不物理删除旧标签。
func (h *WaterSectionHandler) CreateTag(c *gin.Context) {
	operator, ok := h.currentUserOr401(c)
	if !ok {
		return
	}
	section, ok := h.getActiveSectionOr404(c)
	if !ok {
		return
	}
	if !h.ensureCanManageTags(c, section.ID, operator) {
		return
	}

	var req createWaterSectionTagRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体格式错误"})
		return
	}

	contentMode := strings.TrimSpace(req.ContentMode)
	if contentMode == "" {
		contentMode = models.WaterTagModeStandard
	}
	if contentMode != models.WaterTagModeStandard && contentMode != models.WaterTagModeTeamRecruitment {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的栏目类型"})
		return
	}

	slug := strings.TrimSpace(req.Slug)
	if contentMode == models.WaterTagModeTeamRecruitment {
		// 组队栏目后端自动分配固定标识
		slug = "team_recruitment"

		// 检查该版块是否已存在组队栏目
		var existingCount int64
		h.db.Model(&models.WaterSectionTag{}).
			Where("section_id = ? AND content_mode = ?", section.ID, models.WaterTagModeTeamRecruitment).
			Count(&existingCount)
		if existingCount > 0 {
			c.JSON(http.StatusConflict, gin.H{"error": "该版块已存在组队栏目，每个版块最多允许一个组队栏目"})
			return
		}
	} else {
		if msg := validateTagSlug(slug); msg != "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": msg})
			return
		}
	}

	name := strings.TrimSpace(req.Name)
	description := strings.TrimSpace(req.Description)

	if msg := validateTagName(name); msg != "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": msg})
		return
	}
	if msg := validateTagDescription(description); msg != "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": msg})
		return
	}

	// 只在非组队时检查 slug 冲突，如果是组队，可能由于覆盖会跟其它逻辑冲突，
	// 但如果 slug = "team_recruitment" 已经被用作普通标签，会在这里被发现
	if exists, err := h.tagValueExists(section.ID, "slug", slug, 0); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "检查标签标识失败"})
		return
	} else if exists {
		if contentMode == models.WaterTagModeTeamRecruitment {
			c.JSON(http.StatusConflict, gin.H{"error": "默认标识 team_recruitment 已被占用"})
		} else {
			c.JSON(http.StatusConflict, gin.H{"error": "标签标识已存在"})
		}
		return
	}

	if exists, err := h.tagValueExists(section.ID, "name", name, 0); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "检查标签名称失败"})
		return
	} else if exists {
		c.JSON(http.StatusConflict, gin.H{"error": "标签名称已存在"})
		return
	}

	tag := models.WaterSectionTag{
		SectionID:   section.ID,
		Slug:        slug,
		Name:        name,
		Description: description,
		ContentMode: contentMode,
		SortOrder:   req.SortOrder,
		IsDefault:   req.IsDefault,
		IsEnabled:   true,
	}
	if err := h.db.Create(&tag).Error; err != nil {
		var pgErr *pgconn.PgError
		if utils.IsPostgresUniqueViolation(err) {
			errors.As(err, &pgErr)
			if strings.Contains(pgErr.Message, "idx_water_section_single_team_tag") {
				c.JSON(http.StatusConflict, gin.H{"error": "该版块已存在组队栏目，每个版块最多允许一个组队栏目"})
			} else {
				c.JSON(http.StatusConflict, gin.H{"error": "该标识已被使用，请换一个英文缩写"})
			}
			return
		}

		if strings.Contains(err.Error(), "unique") || strings.Contains(err.Error(), "Duplicate") {
			c.JSON(http.StatusConflict, gin.H{"error": "该标识已被使用，请换一个英文缩写"})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "创建标签失败"})
		}
		return
	}

	snapshot, _ := json.Marshal(gin.H{"after": waterSectionTagSnapshotFrom(tag)})
	reason := strings.TrimSpace(req.Reason)
	if reason == "" {
		reason = "新增标签"
	}
	h.writeTagLog(section.ID, operator.ID, models.ModActionCreateTag, tag.ID, reason, string(snapshot))
	c.JSON(http.StatusCreated, gin.H{"tag": tag})
}

// UpdateTag PATCH /api/water/sections/:slug/tags/:tag_id
// 修改标签展示信息；本阶段不开放修改 slug。
func (h *WaterSectionHandler) UpdateTag(c *gin.Context) {
	operator, ok := h.currentUserOr401(c)
	if !ok {
		return
	}
	section, ok := h.getActiveSectionOr404(c)
	if !ok {
		return
	}
	if !h.ensureCanManageTags(c, section.ID, operator) {
		return
	}
	tag, ok := h.getTagInSectionOr404(c, section.ID)
	if !ok {
		return
	}

	var req updateWaterSectionTagRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体格式错误"})
		return
	}

	changed := false
	before := waterSectionTagSnapshotFrom(*tag)
	if req.Name != nil {
		name := strings.TrimSpace(*req.Name)
		if msg := validateTagName(name); msg != "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": msg})
			return
		}
		if exists, err := h.tagValueExists(section.ID, "name", name, tag.ID); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "检查标签名称失败"})
			return
		} else if exists {
			c.JSON(http.StatusConflict, gin.H{"error": "标签名称已存在"})
			return
		}
		tag.Name = name
		changed = true
	}
	if req.Description != nil {
		description := strings.TrimSpace(*req.Description)
		if msg := validateTagDescription(description); msg != "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": msg})
			return
		}
		tag.Description = description
		changed = true
	}
	if req.SortOrder != nil {
		tag.SortOrder = *req.SortOrder
		changed = true
	}
	if req.IsDefault != nil {
		tag.IsDefault = *req.IsDefault
		changed = true
	}
	if !changed {
		c.JSON(http.StatusBadRequest, gin.H{"error": "没有可更新字段"})
		return
	}

	if err := h.db.Save(tag).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存标签失败"})
		return
	}
	after := waterSectionTagSnapshotFrom(*tag)
	snapshot, _ := json.Marshal(gin.H{"before": before, "after": after})
	reason := strings.TrimSpace(req.Reason)
	if reason == "" {
		reason = "修改标签"
	}
	h.writeTagLog(section.ID, operator.ID, models.ModActionUpdateTag, tag.ID, reason, string(snapshot))
	c.JSON(http.StatusOK, gin.H{"tag": tag})
}

// UpdateTagStatus PATCH /api/water/sections/:slug/tags/:tag_id/status
// 启用或停用标签；旧帖子 water_tag_id 保持不变。
func (h *WaterSectionHandler) UpdateTagStatus(c *gin.Context) {
	operator, ok := h.currentUserOr401(c)
	if !ok {
		return
	}
	section, ok := h.getActiveSectionOr404(c)
	if !ok {
		return
	}
	if !h.ensureCanManageTags(c, section.ID, operator) {
		return
	}
	tag, ok := h.getTagInSectionOr404(c, section.ID)
	if !ok {
		return
	}

	var req updateWaterSectionTagStatusRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体格式错误"})
		return
	}
	if req.IsEnabled == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少标签状态"})
		return
	}
	if tag.IsEnabled == *req.IsEnabled {
		c.JSON(http.StatusOK, gin.H{"tag": tag})
		return
	}

	before := waterSectionTagSnapshotFrom(*tag)
	tag.IsEnabled = *req.IsEnabled
	if err := h.db.Save(tag).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存标签状态失败"})
		return
	}

	action := models.ModActionDisableTag
	defaultReason := "停用标签"
	if tag.IsEnabled {
		action = models.ModActionEnableTag
		defaultReason = "启用标签"
	}
	reason := strings.TrimSpace(req.Reason)
	if reason == "" {
		reason = defaultReason
	}
	after := waterSectionTagSnapshotFrom(*tag)
	snapshot, _ := json.Marshal(gin.H{"before": before, "after": after})
	h.writeTagLog(section.ID, operator.ID, action, tag.ID, reason, string(snapshot))
	c.JSON(http.StatusOK, gin.H{"tag": tag})
}

// Follow POST /api/water/sections/:slug/follow
// 关注版块
func (h *WaterSectionHandler) Follow(c *gin.Context) {
	operator, ok := h.currentUserOr401(c)
	if !ok {
		return
	}
	section, ok := h.getActiveSectionOr404(c)
	if !ok {
		return
	}

	follow := models.WaterSectionFollow{
		UserID:    operator.ID,
		SectionID: section.ID,
	}

	err := h.db.Where(models.WaterSectionFollow{UserID: operator.ID, SectionID: section.ID}).FirstOrCreate(&follow).Error
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "关注失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "关注成功"})
}

// Unfollow DELETE /api/water/sections/:slug/follow
// 取消关注版块
func (h *WaterSectionHandler) Unfollow(c *gin.Context) {
	operator, ok := h.currentUserOr401(c)
	if !ok {
		return
	}
	section, ok := h.getActiveSectionOr404(c)
	if !ok {
		return
	}

	err := h.db.Where("user_id = ? AND section_id = ?", operator.ID, section.ID).Delete(&models.WaterSectionFollow{}).Error
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "取消关注失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "取消关注成功"})
}

// GetFollowedSections GET /api/water/sections/followed
// 获取关注的版块列表
func (h *WaterSectionHandler) GetFollowedSections(c *gin.Context) {
	operator, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	var follows []models.WaterSectionFollow
	if err := h.db.Where("user_id = ?", operator.ID).Preload("Section").Preload("Section.Tags", "is_enabled = ?", true).Find(&follows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取关注列表失败"})
		return
	}

	resp := make([]waterSectionResponse, 0, len(follows))
	for _, f := range follows {
		if f.Section != nil && f.Section.Status == "active" {
			r := toSectionResponse(*f.Section)
			r.IsFollowed = true
			resp = append(resp, r)
		}
	}
	c.JSON(http.StatusOK, gin.H{"sections": resp})
}

// waterSectionLevelTitleResponse 版块等级称号响应体
type waterSectionLevelTitleResponse struct {
	Level    int    `json:"level"`
	Title    string `json:"title"`
	Custom   bool   `json:"custom"` // false 表示当前返回的是默认称号
	Position int    `json:"position,omitempty"`
}

type waterSectionMyLevelResponse struct {
	SectionID          uint   `json:"section_id"`
	SectionSlug        string `json:"section_slug"`
	SectionTitle       string `json:"section_title"`
	Level              int    `json:"level"`
	Title              string `json:"title"`
	Exp                int    `json:"exp"`
	CurrentLevelMinExp int    `json:"current_level_min_exp"`
	NextLevelExp       int    `json:"next_level_exp"`
	ProgressExp        int    `json:"progress_exp"`
	RequiredExp        int    `json:"required_exp"`
	PostCount          int    `json:"post_count"`
	ReplyCount         int    `json:"reply_count"`
	TodayPostAwarded   bool   `json:"today_post_awarded"`
	TodayReplyAwarded  bool   `json:"today_reply_awarded"`
	PostDailyExp       int    `json:"post_daily_exp"`
	ReplyDailyExp      int    `json:"reply_daily_exp"`
}

// GetMyLevel GET /api/water/sections/:slug/my-level
// 返回当前登录用户在该版块的等级、经验进度以及今日奖励领取状态。
func (h *WaterSectionHandler) GetMyLevel(c *gin.Context) {
	operator, ok := h.currentUserOr401(c)
	if !ok {
		return
	}
	section, ok := h.getActiveSectionOr404(c)
	if !ok {
		return
	}

	var stat models.WaterSectionUserStat
	err := h.db.Where("user_id = ? AND section_id = ?", operator.ID, section.ID).First(&stat).Error
	if err != nil && err != gorm.ErrRecordNotFound {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取版块等级失败"})
		return
	}
	exp := 0
	postCount := 0
	replyCount := 0
	if err == nil {
		exp = stat.Exp
		postCount = stat.PostCount
		replyCount = stat.ReplyCount
	}

	level := services.CalculateWaterSectionLevel(exp)
	title := services.GetWaterSectionLevelTitle(h.db, section.ID, level)
	currentMin := services.WaterSectionLevelMinExp(level)
	nextExp := services.NextWaterSectionLevelExp(level)
	requiredExp := 0
	progressExp := 0
	if nextExp > 0 {
		requiredExp = nextExp - currentMin
		progressExp = exp - currentMin
		if progressExp < 0 {
			progressExp = 0
		}
		if progressExp > requiredExp {
			progressExp = requiredExp
		}
	}

	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local)
	var logs []models.WaterSectionExpLog
	if err := h.db.
		Where("user_id = ? AND section_id = ? AND date = ? AND action IN ?",
			operator.ID, section.ID, today,
			[]string{models.WaterSectionExpActionPostDaily, models.WaterSectionExpActionReplyDaily}).
		Find(&logs).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取今日奖励状态失败"})
		return
	}
	todayPostAwarded := false
	todayReplyAwarded := false
	for _, log := range logs {
		switch log.Action {
		case models.WaterSectionExpActionPostDaily:
			todayPostAwarded = true
		case models.WaterSectionExpActionReplyDaily:
			todayReplyAwarded = true
		}
	}

	c.JSON(http.StatusOK, waterSectionMyLevelResponse{
		SectionID:          section.ID,
		SectionSlug:        section.Slug,
		SectionTitle:       section.Title,
		Level:              level,
		Title:              title,
		Exp:                exp,
		CurrentLevelMinExp: currentMin,
		NextLevelExp:       nextExp,
		ProgressExp:        progressExp,
		RequiredExp:        requiredExp,
		PostCount:          postCount,
		ReplyCount:         replyCount,
		TodayPostAwarded:   todayPostAwarded,
		TodayReplyAwarded:  todayReplyAwarded,
		PostDailyExp:       services.GlobalExpPostDaily,
		ReplyDailyExp:      services.GlobalExpReplyDaily,
	})
}

// GetLevelTitles GET /api/water/sections/:slug/level-titles
// 公开端点。返回当前版块 Lv.1-Lv.8 的称号列表，自定义缺失时使用默认值。
func (h *WaterSectionHandler) GetLevelTitles(c *gin.Context) {
	section, ok := h.getActiveSectionOr404(c)
	if !ok {
		return
	}

	var customs []models.WaterSectionLevelTitle
	if err := h.db.Where("section_id = ?", section.ID).Order("level ASC").Find(&customs).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取称号失败"})
		return
	}
	customByLevel := make(map[int]models.WaterSectionLevelTitle, len(customs))
	for _, t := range customs {
		customByLevel[t.Level] = t
	}

	out := make([]waterSectionLevelTitleResponse, 0, 8)
	for level := 1; level <= 8; level++ {
		if custom, ok := customByLevel[level]; ok && strings.TrimSpace(custom.Title) != "" {
			out = append(out, waterSectionLevelTitleResponse{
				Level: level, Title: custom.Title, Custom: true, Position: int(custom.ID),
			})
		} else {
			out = append(out, waterSectionLevelTitleResponse{
				Level: level, Title: services.DefaultWaterSectionLevelTitle(level), Custom: false,
			})
		}
	}
	c.JSON(http.StatusOK, gin.H{
		"section_id":   section.ID,
		"section_slug": section.Slug,
		"titles":       out,
	})
}

// waterSectionLevelTitleInput 称号编辑请求体
type waterSectionLevelTitleInput struct {
	Level int    `json:"level"`
	Title string `json:"title"`
	Reset bool   `json:"reset"`
}

// UpdateLevelTitles PATCH /api/water/sections/:slug/level-titles
// 编辑版块 Lv.1-Lv.8 的称号。
//
// 权限：admin / super_admin / 本版块版主 (CanEditSection=true)
// 校验：
//   - level 必须为 1-8
//   - title 为空或 reset=true 表示恢复默认称号
//   - 中文不超过 8 个字符（其它字符不超过 16 个字符）
//   - body 内同 level 唯一
//
// body: {"titles": [{"level":1,"title":"初来乍到"}, {"level":2,"reset":true}, ...]}
func (h *WaterSectionHandler) UpdateLevelTitles(c *gin.Context) {
	operator, ok := h.currentUserOr401(c)
	if !ok {
		return
	}
	section, ok := h.getActiveSectionOr404(c)
	if !ok {
		return
	}

	if !h.permSvc.CanEditSection(section.ID, operator) {
		c.JSON(http.StatusForbidden, gin.H{"error": "没有编辑版块的权限"})
		return
	}

	var body struct {
		Titles []waterSectionLevelTitleInput `json:"titles" binding:"required"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if len(body.Titles) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "至少提供一条称号"})
		return
	}

	seenLevels := make(map[int]struct{}, len(body.Titles))
	for _, in := range body.Titles {
		if in.Level < 1 || in.Level > 8 {
			c.JSON(http.StatusBadRequest, gin.H{"error": fmt.Sprintf("等级 %d 不在 1-8 范围内", in.Level)})
			return
		}
		if _, dup := seenLevels[in.Level]; dup {
			c.JSON(http.StatusBadRequest, gin.H{"error": fmt.Sprintf("等级 %d 重复输入", in.Level)})
			return
		}
		seenLevels[in.Level] = struct{}{}

		title := strings.TrimSpace(in.Title)
		if in.Reset || title == "" {
			continue
		}
		// 中文字符最多 8 个，其它字符放宽到 16 个 rune
		rCount := utf8.RuneCountInString(title)
		if rCount > 16 {
			c.JSON(http.StatusBadRequest, gin.H{"error": fmt.Sprintf("等级 %d 的称号长度超限（最多 16 个字符）", in.Level)})
			return
		}
		// 中文占比判断：若包含中文，则中文部分最多 8 个字符
		chineseCount := 0
		for _, r := range title {
			if r >= 0x4E00 && r <= 0x9FFF {
				chineseCount++
			}
		}
		if chineseCount > 0 && chineseCount > 8 {
			c.JSON(http.StatusBadRequest, gin.H{"error": fmt.Sprintf("等级 %d 的中文称号最多 8 个字", in.Level)})
			return
		}
	}

	// 在事务内逐条 upsert；空标题/reset 表示删除该等级自定义记录，读取时回落默认称号。
	err := h.db.Transaction(func(tx *gorm.DB) error {
		for _, in := range body.Titles {
			title := strings.TrimSpace(in.Title)
			if in.Reset || title == "" {
				if err := tx.Where("section_id = ? AND level = ?", section.ID, in.Level).Delete(&models.WaterSectionLevelTitle{}).Error; err != nil {
					return err
				}
				continue
			}

			var existing models.WaterSectionLevelTitle
			err := tx.Where("section_id = ? AND level = ?", section.ID, in.Level).First(&existing).Error
			if err == nil {
				if err := tx.Model(&existing).Update("title", title).Error; err != nil {
					return err
				}
				continue
			}
			if err != gorm.ErrRecordNotFound {
				return err
			}
			row := models.WaterSectionLevelTitle{
				SectionID: section.ID,
				Level:     in.Level,
				Title:     title,
			}
			if err := tx.Create(&row).Error; err != nil {
				return err
			}
		}

		// 写一条管理日志，便于追溯
		snapshot, _ := json.MarshalIndent(body.Titles, "", "  ")
		if err := tx.Create(&models.WaterModerationLog{
			SectionID:  section.ID,
			OperatorID: operator.ID,
			Action:     models.ModActionEditSection,
			TargetType: "section",
			TargetID:   section.ID,
			Reason:     "update_level_titles",
			Snapshot:   string(snapshot),
		}).Error; err != nil {
			fmt.Printf("[WaterSection] write level titles log failed: %v\n", err)
		}
		return nil
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存称号失败"})
		return
	}

	// 返回最新结果，便于前端刷新
	var customs []models.WaterSectionLevelTitle
	if err := h.db.Where("section_id = ?", section.ID).Order("level ASC").Find(&customs).Error; err != nil {
		c.JSON(http.StatusOK, gin.H{"updated": true})
		return
	}
	customByLevel := make(map[int]models.WaterSectionLevelTitle, len(customs))
	for _, t := range customs {
		customByLevel[t.Level] = t
	}
	out := make([]waterSectionLevelTitleResponse, 0, 8)
	for level := 1; level <= 8; level++ {
		if custom, ok := customByLevel[level]; ok && strings.TrimSpace(custom.Title) != "" {
			out = append(out, waterSectionLevelTitleResponse{
				Level: level, Title: custom.Title, Custom: true, Position: int(custom.ID),
			})
		} else {
			out = append(out, waterSectionLevelTitleResponse{
				Level: level, Title: services.DefaultWaterSectionLevelTitle(level), Custom: false,
			})
		}
	}
	c.JSON(http.StatusOK, gin.H{
		"section_id":   section.ID,
		"section_slug": section.Slug,
		"titles":       out,
	})
}

// --- 版块图标审核链路 ---

type createSectionIconReviewRequest struct {
	NewAvatarURL string `json:"new_avatar_url"`
	Reason       string `json:"reason"`
}

type reviewSectionIconRequest struct {
	ReviewReason string `json:"review_reason"`
}

type waterSectionIconReviewResponse struct {
	ID            uint       `json:"id"`
	SectionID     uint       `json:"section_id"`
	SectionTitle  string     `json:"section_title"`
	RequestedBy   uint       `json:"requested_by"`
	RequesterName string     `json:"requester_name"`
	OldAvatarURL  string     `json:"old_avatar_url"`
	NewAvatarURL  string     `json:"new_avatar_url"`
	Reason        string     `json:"reason"`
	Status        string     `json:"status"`
	ReviewedBy    *uint      `json:"reviewed_by"`
	ReviewerName  string     `json:"reviewer_name"`
	ReviewedAt    *time.Time `json:"reviewed_at"`
	ReviewReason  string     `json:"review_reason"`
	CreatedAt     time.Time  `json:"created_at"`
}

func formatIconReviewResponse(r models.WaterSectionIconReview) waterSectionIconReviewResponse {
	resp := waterSectionIconReviewResponse{
		ID:           r.ID,
		SectionID:    r.SectionID,
		SectionTitle: r.Section.Title,
		RequestedBy:  r.RequestedBy,
		OldAvatarURL: r.OldAvatarURL,
		NewAvatarURL: r.NewAvatarURL,
		Reason:       r.Reason,
		Status:       r.Status,
		ReviewedBy:   r.ReviewedBy,
		ReviewedAt:   r.ReviewedAt,
		ReviewReason: r.ReviewReason,
		CreatedAt:    r.CreatedAt,
	}
	if r.Requester.ID != 0 {
		resp.RequesterName = r.Requester.Nickname
	}
	if r.Reviewer != nil && r.Reviewer.ID != 0 {
		resp.ReviewerName = r.Reviewer.Nickname
	}
	return resp
}

// SubmitSectionIconReview 提交图标审核申请
func (h *WaterSectionHandler) SubmitSectionIconReview(c *gin.Context) {
	if !config.IsReviewEnabled() {
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"code":  "review_temporarily_disabled",
			"error": "版块图标申请暂未开放",
		})
		return
	}
	slug := c.Param("slug")
	userID := c.GetUint("userID")

	var section models.WaterSection
	if err := h.db.Where("slug = ?", slug).First(&section).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "版块不存在"})
		return
	}

	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未登录", "code": "authentication_required"})
		return
	}

	canEdit := h.permSvc.CanEditSection(section.ID, &user)
	if !canEdit {
		c.JSON(http.StatusForbidden, gin.H{"error": "没有权限修改该版块"})
		return
	}

	var req createSectionIconReviewRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误"})
		return
	}

	if req.NewAvatarURL == "" || (!strings.HasPrefix(req.NewAvatarURL, "/uploads/") && !strings.HasPrefix(req.NewAvatarURL, "/api/uploads/")) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "图片地址不合法，只能使用本站上传的图片"})
		return
	}
	if utf8.RuneCountInString(req.Reason) > 500 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "申请说明过长"})
		return
	}

	var pendingCount int64
	h.db.Model(&models.WaterSectionIconReview{}).Where("section_id = ? AND status = ?", section.ID, models.SectionIconReviewPending).Count(&pendingCount)
	if pendingCount > 0 {
		c.JSON(http.StatusConflict, gin.H{"error": "该版块已有一个待审核的图标申请，请先等待或撤回"})
		return
	}

	review := models.WaterSectionIconReview{
		SectionID:    section.ID,
		RequestedBy:  userID,
		OldAvatarURL: section.AvatarURL,
		NewAvatarURL: req.NewAvatarURL,
		Reason:       req.Reason,
		Status:       models.SectionIconReviewPending,
	}

	if err := h.db.Create(&review).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "提交申请失败"})
		return
	}

	h.db.Preload("Section").Preload("Requester").First(&review, review.ID)
	c.JSON(http.StatusOK, formatIconReviewResponse(review))
}

// GetCurrentSectionIconReview 获取当前版块的图标审核状态
func (h *WaterSectionHandler) GetCurrentSectionIconReview(c *gin.Context) {
	slug := c.Param("slug")
	var section models.WaterSection
	if err := h.db.Where("slug = ?", slug).First(&section).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "版块不存在"})
		return
	}

	var pending models.WaterSectionIconReview
	pendingErr := h.db.Preload("Section").Preload("Requester").Preload("Reviewer").
		Where("section_id = ? AND status = ?", section.ID, models.SectionIconReviewPending).
		First(&pending).Error

	var latest models.WaterSectionIconReview
	latestErr := h.db.Preload("Section").Preload("Requester").Preload("Reviewer").
		Where("section_id = ? AND status != ?", section.ID, models.SectionIconReviewPending).
		Order("created_at desc").
		First(&latest).Error

	resp := gin.H{}
	if pendingErr == nil {
		resp["pending"] = formatIconReviewResponse(pending)
	} else {
		resp["pending"] = nil
	}

	if latestErr == nil {
		resp["latest"] = formatIconReviewResponse(latest)
	} else {
		resp["latest"] = nil
	}

	c.JSON(http.StatusOK, resp)
}

// CancelSectionIconReview 撤回审核申请
func (h *WaterSectionHandler) CancelSectionIconReview(c *gin.Context) {
	slug := c.Param("slug")
	id := c.Param("id")
	userID := c.GetUint("userID")

	var section models.WaterSection
	if err := h.db.Where("slug = ?", slug).First(&section).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "版块不存在"})
		return
	}

	var review models.WaterSectionIconReview
	if err := h.db.Where("id = ? AND section_id = ?", id, section.ID).First(&review).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "申请不存在或不属于该版块"})
		return
	}

	if review.Status != models.SectionIconReviewPending {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该申请已被处理，无法撤回"})
		return
	}

	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未登录", "code": "authentication_required"})
		return
	}

	canEdit := h.permSvc.CanEditSection(section.ID, &user)
	if !canEdit && review.RequestedBy != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "没有权限撤回该申请"})
		return
	}

	if err := h.db.Model(&review).Update("status", models.SectionIconReviewCancelled).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "撤回失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "已撤回"})
}

// AdminListSectionIconReviews 管理员查看审核列表
func (h *WaterSectionHandler) AdminListSectionIconReviews(c *gin.Context) {
	status := c.Query("status")
	if status == "" {
		status = models.SectionIconReviewPending
	}

	var reviews []models.WaterSectionIconReview
	query := h.db.Preload("Section").Preload("Requester").Preload("Reviewer")
	if status != "" && status != "all" {
		query = query.Where("status = ?", status)
	}

	if err := query.Order("created_at desc").Limit(100).Find(&reviews).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取列表失败"})
		return
	}

	resp := make([]waterSectionIconReviewResponse, len(reviews))
	for i, r := range reviews {
		resp[i] = formatIconReviewResponse(r)
	}

	c.JSON(http.StatusOK, gin.H{"reviews": resp})
}

// AdminApproveSectionIconReview 管理员通过
func (h *WaterSectionHandler) AdminApproveSectionIconReview(c *gin.Context) {
	id := c.Param("id")
	adminID := c.GetUint("userID")

	var review models.WaterSectionIconReview
	if err := h.db.Preload("Section").Preload("Requester").Where("id = ?", id).First(&review).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "申请不存在"})
		return
	}

	if review.Status != models.SectionIconReviewPending {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该申请不再处于待审核状态"})
		return
	}

	var req reviewSectionIconRequest
	_ = c.ShouldBindJSON(&req)

	now := time.Now()
	err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.WaterSection{}).Where("id = ?", review.SectionID).
			Update("avatar_url", review.NewAvatarURL).Error; err != nil {
			return err
		}
		if err := services.ClaimPublicImagePaths(tx, review.NewAvatarURL); err != nil {
			return err
		}

		review.Status = models.SectionIconReviewApproved
		review.ReviewedBy = &adminID
		review.ReviewedAt = &now
		review.ReviewReason = req.ReviewReason
		if err := tx.Save(&review).Error; err != nil {
			return err
		}

		snapshot, _ := json.Marshal(map[string]interface{}{
			"old_avatar_url": review.OldAvatarURL,
			"new_avatar_url": review.NewAvatarURL,
			"review_id":      review.ID,
		})
		tx.Create(&models.WaterModerationLog{
			SectionID:  review.SectionID,
			OperatorID: adminID,
			Action:     "section_icon_review_approve",
			TargetType: "section",
			TargetID:   review.SectionID,
			Reason:     req.ReviewReason,
			Snapshot:   string(snapshot),
		})
		return nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "处理失败"})
		return
	}

	h.db.Preload("Section").Preload("Requester").Preload("Reviewer").First(&review, review.ID)
	c.JSON(http.StatusOK, formatIconReviewResponse(review))
}

// AdminRejectSectionIconReview 管理员拒绝
func (h *WaterSectionHandler) AdminRejectSectionIconReview(c *gin.Context) {
	id := c.Param("id")
	adminID := c.GetUint("userID")

	var review models.WaterSectionIconReview
	if err := h.db.Preload("Section").Preload("Requester").Where("id = ?", id).First(&review).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "申请不存在"})
		return
	}

	if review.Status != models.SectionIconReviewPending {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该申请不再处于待审核状态"})
		return
	}

	var req reviewSectionIconRequest
	if err := c.ShouldBindJSON(&req); err != nil || strings.TrimSpace(req.ReviewReason) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "拒绝操作必须填写原因"})
		return
	}

	now := time.Now()
	review.Status = models.SectionIconReviewRejected
	review.ReviewedBy = &adminID
	review.ReviewedAt = &now
	review.ReviewReason = req.ReviewReason

	if err := h.db.Save(&review).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "处理失败"})
		return
	}

	snapshot, _ := json.Marshal(map[string]interface{}{
		"review_id": review.ID,
	})
	h.db.Create(&models.WaterModerationLog{
		SectionID:  review.SectionID,
		OperatorID: adminID,
		Action:     "section_icon_review_reject",
		TargetType: "section",
		TargetID:   review.SectionID,
		Reason:     req.ReviewReason,
		Snapshot:   string(snapshot),
	})

	h.db.Preload("Section").Preload("Requester").Preload("Reviewer").First(&review, review.ID)
	c.JSON(http.StatusOK, formatIconReviewResponse(review))
}

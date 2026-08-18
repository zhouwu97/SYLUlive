package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// WaterModerationHandler 版块内内容管理处理器（置顶/删帖/禁言/日志）
type WaterModerationHandler struct {
	db      *gorm.DB
	permSvc *services.WaterPermissionService
}

// NewWaterModerationHandler 构造
func NewWaterModerationHandler(db *gorm.DB) *WaterModerationHandler {
	return &WaterModerationHandler{
		db:      db,
		permSvc: services.NewWaterPermissionService(db),
	}
}

// ── 辅助函数 ──

// getSectionOr404 获取版块，不存在则写 404
func (h *WaterModerationHandler) getSectionOr404(c *gin.Context) (*models.WaterSection, bool) {
	slug := c.Param("slug")
	var section models.WaterSection
	if err := h.db.Where("slug = ? AND status = ?", slug, "active").First(&section).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"error": "版块不存在"})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取版块失败"})
		}
		return nil, false
	}
	return &section, true
}

// getOperatorOr401 获取当前操作用户
func (h *WaterModerationHandler) getOperatorOr401(c *gin.Context) (*models.User, bool) {
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

func (h *WaterModerationHandler) writeLog(sectionID uint, operatorID uint, action string, targetType string, targetID uint, targetUserID *uint, reason string, snapshot string) {
	log := models.WaterModerationLog{
		SectionID:    sectionID,
		OperatorID:   operatorID,
		Action:       action,
		TargetType:   targetType,
		TargetID:     targetID,
		TargetUserID: targetUserID,
		Reason:       reason,
		Snapshot:     snapshot,
	}
	if err := h.db.Create(&log).Error; err != nil {
		fmt.Printf("[WaterModeration] write log failed: %v\n", err)
	}
}

func (h *WaterModerationHandler) notifyTarget(userID uint, operatorID uint, action string, section models.WaterSection, relatedID uint, postID uint, reason string) {
	if userID == 0 {
		return
	}
	actionText := map[string]string{
		models.ModActionDeletePost:  "你的帖子已被版块管理删除",
		models.ModActionRestorePost: "你的帖子已恢复",
		models.ModActionMuteUser:    "你已被版块禁言",
		models.ModActionUnmuteUser:  "你在版块内的禁言已解除",
	}[action]
	if actionText == "" {
		actionText = "版块管理通知"
	}
	content := fmt.Sprintf("%s：%s", section.Title, actionText)
	if strings.TrimSpace(reason) != "" {
		content = fmt.Sprintf("%s。原因：%s", content, strings.TrimSpace(reason))
	}
	if action == models.ModActionDeletePost || action == models.ModActionMuteUser {
		content = fmt.Sprintf("%s。如认为处理有误，可联系版块管理员申诉。", content)
	}
	notification := models.Notification{
		UserID:    userID,
		Type:      "water_moderation",
		Content:   content,
		RelatedID: relatedID,
		PostID:    postID,
		FromUID:   operatorID,
		IsRead:    false,
	}
	if err := h.db.Create(&notification).Error; err != nil {
		fmt.Printf("[WaterModeration] write notification failed: %v\n", err)
	}
}

func validateModerationReason(reason string, actionName string) (string, string) {
	trimmed := strings.TrimSpace(reason)
	if trimmed == "" {
		return "", fmt.Sprintf("请填写%s原因", actionName)
	}
	if len([]rune(trimmed)) < 2 {
		return "", fmt.Sprintf("%s原因至少 2 个字", actionName)
	}
	return trimmed, ""
}

// ── 版块置顶 ──

type pinSectionInput struct {
	Weight      int    `json:"weight"`
	Reason      string `json:"reason"`
	PinnedUntil string `json:"pinned_until"`
}

// PinPost POST /api/water/sections/:slug/posts/:post_id/pin
func (h *WaterModerationHandler) PinPost(c *gin.Context) {
	operator, ok := h.getOperatorOr401(c)
	if !ok {
		return
	}
	section, ok := h.getSectionOr404(c)
	if !ok {
		return
	}

	postIDStr := c.Param("post_id")
	postID, err := strconv.ParseUint(postIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子 ID"})
		return
	}

	// 权限校验
	if !h.permSvc.CanPinPost(section.ID, operator) {
		c.JSON(http.StatusForbidden, gin.H{"error": "没有置顶权限"})
		return
	}

	var post models.Post
	if err := h.db.First(&post, postID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}
	if post.Status == models.PostStatusDeleted {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子已删除"})
		return
	}
	if post.BoardID != models.BoardShuitie || post.ContentKind == models.PostContentKindPoll {
		c.JSON(http.StatusBadRequest, gin.H{"error": "只能置顶水帖版块帖子"})
		return
	}
	if post.PostType != section.Slug {
		c.JSON(http.StatusBadRequest, gin.H{"error": "帖子不属于该版块"})
		return
	}

	var input pinSectionInput
	_ = c.ShouldBindJSON(&input)

	weight := input.Weight
	if weight < 0 {
		weight = 0
	}
	if weight > 100 {
		weight = 100
	}

	now := time.Now()
	var until *time.Time
	if strings.TrimSpace(input.PinnedUntil) != "" {
		parsed, parseErr := time.Parse(time.RFC3339, input.PinnedUntil)
		if parseErr != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "置顶到期时间格式错误"})
			return
		}
		if !parsed.After(now) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "到期时间必须晚于当前时间"})
			return
		}
		until = &parsed
	}

	reason := strings.TrimSpace(input.Reason)
	if reason == "" {
		reason = "版块置顶"
	} else if validReason, msg := validateModerationReason(reason, "置顶"); msg != "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": msg})
		return
	} else {
		reason = validReason
	}

	// 查找已有记录（可能复用的 inactive）
	var existing models.WaterSectionPin
	dupErr := h.db.Where("section_id = ? AND post_id = ?", section.ID, postID).First(&existing).Error
	if dupErr == nil && existing.Status == models.PinStatusActive {
		// 同一帖子已置顶 → 更新
		snapshotBefore, _ := json.Marshal(existing)
		h.db.Model(&existing).Updates(map[string]interface{}{
			"pinned_by":    operator.ID,
			"weight":       weight,
			"reason":       reason,
			"pinned_until": until,
		})
		_ = h.db.First(&existing, existing.ID)
		snapshotAfter, _ := json.Marshal(existing)
		h.writeLog(section.ID, operator.ID, models.ModActionPinPost, "post", uint(postID), &post.AuthorID, reason,
			fmt.Sprintf("before:%s after:%s", snapshotBefore, snapshotAfter))
		c.JSON(http.StatusOK, gin.H{"message": "置顶已更新", "pin": existing})
		return
	}

	// 检查 active pin 上限
	var activeCount int64
	h.db.Model(&models.WaterSectionPin{}).
		Where("section_id = ? AND status = ? AND (pinned_until IS NULL OR pinned_until > ?)",
			section.ID, models.PinStatusActive, now).
		Count(&activeCount)
	if activeCount >= 3 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该版块置顶已达上限（最多 3 条）"})
		return
	}

	if dupErr == nil {
		// 复用 inactive 记录
		h.db.Model(&existing).Updates(map[string]interface{}{
			"pinned_by":    operator.ID,
			"weight":       weight,
			"reason":       reason,
			"pinned_until": until,
			"status":       models.PinStatusActive,
		})
		_ = h.db.First(&existing, existing.ID)
		snapshot, _ := json.Marshal(existing)
		h.writeLog(section.ID, operator.ID, models.ModActionPinPost, "post", uint(postID), &post.AuthorID, reason, string(snapshot))
		c.JSON(http.StatusOK, gin.H{"message": "置顶成功", "pin": existing})
		return
	}

	pin := models.WaterSectionPin{
		SectionID:   section.ID,
		PostID:      uint(postID),
		PinnedBy:    operator.ID,
		Weight:      weight,
		Reason:      reason,
		PinnedUntil: until,
		Status:      models.PinStatusActive,
	}
	if err := h.db.Create(&pin).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "置顶失败"})
		return
	}

	snapshot, _ := json.Marshal(pin)
	h.writeLog(section.ID, operator.ID, models.ModActionPinPost, "post", uint(postID), &post.AuthorID, reason, string(snapshot))
	c.JSON(http.StatusCreated, gin.H{"message": "置顶成功", "pin": pin})
}

// UnpinPost DELETE /api/water/sections/:slug/posts/:post_id/pin
func (h *WaterModerationHandler) UnpinPost(c *gin.Context) {
	operator, ok := h.getOperatorOr401(c)
	if !ok {
		return
	}
	section, ok := h.getSectionOr404(c)
	if !ok {
		return
	}

	postIDStr := c.Param("post_id")
	postID, err := strconv.ParseUint(postIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子 ID"})
		return
	}

	if !h.permSvc.CanPinPost(section.ID, operator) {
		c.JSON(http.StatusForbidden, gin.H{"error": "没有置顶权限"})
		return
	}

	var pin models.WaterSectionPin
	dbErr := h.db.Where("section_id = ? AND post_id = ? AND status = ?",
		section.ID, postID, models.PinStatusActive).First(&pin).Error
	if dbErr == gorm.ErrRecordNotFound {
		// 幂等，已取消
		c.JSON(http.StatusOK, gin.H{"message": "已取消置顶"})
		return
	}
	if dbErr != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询置顶记录失败"})
		return
	}

	reason := "取消置顶"
	var body struct {
		Reason string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&body); err == nil && body.Reason != "" {
		reason = body.Reason
	}

	h.db.Model(&pin).Update("status", models.PinStatusInactive)
	h.writeLog(section.ID, operator.ID, models.ModActionUnpinPost, "post", uint(postID), nil, reason, "")
	c.JSON(http.StatusOK, gin.H{"message": "已取消置顶"})
}

// ── 版块加精 ──

type featurePostInput struct {
	Reason string `json:"reason" binding:"required"`
}

// FeaturePost POST /api/water/sections/:slug/posts/:post_id/feature
func (h *WaterModerationHandler) FeaturePost(c *gin.Context) {
	operator, ok := h.getOperatorOr401(c)
	if !ok {
		return
	}
	section, ok := h.getSectionOr404(c)
	if !ok {
		return
	}

	postIDStr := c.Param("post_id")
	postID, err := strconv.ParseUint(postIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子 ID"})
		return
	}

	// 权限：复用 CanPinPost 作为版块精华的权限
	if !h.permSvc.CanPinPost(section.ID, operator) {
		c.JSON(http.StatusForbidden, gin.H{"error": "没有加精权限"})
		return
	}

	var post models.Post
	if err := h.db.First(&post, postID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}
	if post.Status == models.PostStatusDeleted {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子已删除"})
		return
	}
	if post.BoardID != models.BoardShuitie || post.ContentKind == models.PostContentKindPoll {
		c.JSON(http.StatusBadRequest, gin.H{"error": "只能加精水帖版块帖子"})
		return
	}
	if post.PostType != section.Slug {
		c.JSON(http.StatusBadRequest, gin.H{"error": "帖子不属于该版块"})
		return
	}

	var input featurePostInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请填写加精原因"})
		return
	}
	reason, reasonMsg := validateModerationReason(input.Reason, "加精")
	if reasonMsg != "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": reasonMsg})
		return
	}

	var existing models.WaterSectionFeaturedPost
	dupErr := h.db.Where("section_id = ? AND post_id = ?", section.ID, postID).First(&existing).Error
	if dupErr == nil && existing.Status == models.SectionFeaturedStatusActive {
		// 已是版块精华：补偿检查首页推荐申请是否仍然存在（自动修复历史脏状态）
		homeApp, ensureErr := h.ensureHomeFeaturedApplication(uint(postID), operator.ID, section.ID, existing.ID, reason)
		if ensureErr != nil {
			log.Printf("[water_moderation] 帖子已是版块精华，但首页推荐补偿失败 post_id=%d: %v", postID, ensureErr)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "帖子已是版块精华，但首页推荐提交失败，请重试"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"message": "帖子已是版块精华", "featured": existing, "home_application": homeApp})
		return
	}

	if dupErr == nil {
		h.db.Model(&existing).Updates(map[string]interface{}{
			"featured_by": operator.ID,
			"reason":      reason,
			"status":      models.SectionFeaturedStatusActive,
		})
		_ = h.db.First(&existing, existing.ID)
		snapshot, _ := json.Marshal(existing)
		h.writeLog(section.ID, operator.ID, models.ModActionFeaturePost, "post", uint(postID), &post.AuthorID, reason, string(snapshot))
		homeApp, ensureErr := h.ensureHomeFeaturedApplication(uint(postID), operator.ID, section.ID, existing.ID, reason)
		if ensureErr != nil {
			log.Printf("[water_moderation] 恢复版块精华后首页推荐失败 post_id=%d: %v", postID, ensureErr)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "已恢复版块精华，但首页推荐提交失败，请重试"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"message": "加精成功，并已提交首页推荐审核", "featured": existing, "home_application": homeApp})
		return
	}

	featured := models.WaterSectionFeaturedPost{
		SectionID:  section.ID,
		PostID:     uint(postID),
		FeaturedBy: operator.ID,
		Reason:     reason,
		Status:     models.SectionFeaturedStatusActive,
	}
	if err := h.db.Create(&featured).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "加精失败"})
		return
	}

	snapshot, _ := json.Marshal(featured)
	h.writeLog(section.ID, operator.ID, models.ModActionFeaturePost, "post", uint(postID), &post.AuthorID, reason, string(snapshot))

	// 自动生成首页精华审核记录；失败必须如实上报，不能假报成功
	homeApp, ensureErr := h.ensureHomeFeaturedApplication(uint(postID), operator.ID, section.ID, featured.ID, reason)
	if ensureErr != nil {
		log.Printf("[water_moderation] 版块加精成功但首页推荐提交失败 post_id=%d: %v", postID, ensureErr)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "已设为版块精华，首页推荐提交失败，请重试"})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"message": "加精成功，并已提交首页推荐审核", "featured": featured, "home_application": homeApp})
}

// ensureHomeFeaturedApplication 确保首页精华审核记录存在，任何数据库错误都向上返回：
// 已有 pending → 返回 existing,nil；没有 → 创建并返回；查询/创建失败 → 返回 error。
func (h *WaterModerationHandler) ensureHomeFeaturedApplication(postID uint, moderatorID uint, sectionID uint, sectionFeaturedID uint, reason string) (*models.FeaturedApplication, error) {
	var existing models.FeaturedApplication
	err := h.db.Where("post_id = ? AND status = ?", postID, "pending").First(&existing).Error
	switch {
	case err == nil:
		return &existing, nil
	case !errors.Is(err, gorm.ErrRecordNotFound):
		return nil, fmt.Errorf("查询首页精华申请失败: %w", err)
	}
	app := models.FeaturedApplication{
		PostID:            postID,
		ApplicantID:       moderatorID,
		Source:            "moderator",
		SectionID:         &sectionID,
		SectionFeaturedID: &sectionFeaturedID,
		Reason:            "版主推荐: " + reason,
		Status:            "pending",
	}
	if err := h.db.Create(&app).Error; err != nil {
		return nil, fmt.Errorf("创建首页精华申请失败: %w", err)
	}
	return &app, nil
}

// UnfeaturePost DELETE /api/water/sections/:slug/posts/:post_id/feature
func (h *WaterModerationHandler) UnfeaturePost(c *gin.Context) {
	operator, ok := h.getOperatorOr401(c)
	if !ok {
		return
	}
	section, ok := h.getSectionOr404(c)
	if !ok {
		return
	}

	postIDStr := c.Param("post_id")
	postID, err := strconv.ParseUint(postIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子 ID"})
		return
	}

	if !h.permSvc.CanPinPost(section.ID, operator) {
		c.JSON(http.StatusForbidden, gin.H{"error": "没有取消加精权限"})
		return
	}

	var featured models.WaterSectionFeaturedPost
	dbErr := h.db.Where("section_id = ? AND post_id = ? AND status = ?",
		section.ID, postID, models.SectionFeaturedStatusActive).First(&featured).Error
	if dbErr == gorm.ErrRecordNotFound {
		c.JSON(http.StatusOK, gin.H{"message": "已取消加精"})
		return
	}
	if dbErr != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询加精记录失败"})
		return
	}

	reason := "取消加精"
	var body struct {
		Reason string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&body); err == nil && body.Reason != "" {
		reason = body.Reason
	}

	h.db.Model(&featured).Update("status", models.SectionFeaturedStatusInactive)
	h.writeLog(section.ID, operator.ID, models.ModActionUnfeaturePost, "post", uint(postID), nil, reason, "")
	c.JSON(http.StatusOK, gin.H{"message": "已取消加精"})
}

// ── 版块删帖 ──

type moderateDeleteInput struct {
	Reason string `json:"reason" binding:"required"`
}

// DeletePost DELETE /api/water/sections/:slug/posts/:post_id/moderate
func (h *WaterModerationHandler) DeletePost(c *gin.Context) {
	operator, ok := h.getOperatorOr401(c)
	if !ok {
		return
	}
	section, ok := h.getSectionOr404(c)
	if !ok {
		return
	}

	postIDStr := c.Param("post_id")
	postID, err := strconv.ParseUint(postIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子 ID"})
		return
	}

	if !h.permSvc.CanDeletePost(section.ID, operator) {
		c.JSON(http.StatusForbidden, gin.H{"error": "没有删除权限"})
		return
	}

	var post models.Post
	if err := h.db.First(&post, postID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}
	if post.Status == models.PostStatusDeleted {
		c.JSON(http.StatusOK, gin.H{"message": "帖子已被删除"})
		return
	}
	if post.BoardID != models.BoardShuitie || post.ContentKind == models.PostContentKindPoll {
		c.JSON(http.StatusBadRequest, gin.H{"error": "只能管理水帖版块帖子"})
		return
	}
	if post.PostType != section.Slug {
		c.JSON(http.StatusBadRequest, gin.H{"error": "帖子不属于该版块"})
		return
	}

	var input moderateDeleteInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请填写删除原因"})
		return
	}
	reason, reasonMsg := validateModerationReason(input.Reason, "删除")
	if reasonMsg != "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": reasonMsg})
		return
	}

	// 受保护用户检查
	if protected, reason := h.permSvc.IsUserProtectedFromModerator(section.ID, operator, post.AuthorID); protected {
		c.JSON(http.StatusForbidden, gin.H{"error": reason})
		return
	}

	h.db.Model(&post).Update("status", models.PostStatusDeleted)
	h.writeLog(section.ID, operator.ID, models.ModActionDeletePost, "post", uint(postID), &post.AuthorID, reason,
		fmt.Sprintf(`{"post_id":%d,"author_id":%d}`, post.ID, post.AuthorID))
	h.notifyTarget(post.AuthorID, operator.ID, models.ModActionDeletePost, *section, post.ID, post.ID, reason)
	c.JSON(http.StatusOK, gin.H{"message": "帖子已删除"})
}

// ── 管理员恢复帖子 ──

type restorePostInput struct {
	Reason string `json:"reason"`
}

// RestorePost POST /api/water/sections/:slug/posts/:post_id/restore
func (h *WaterModerationHandler) RestorePost(c *gin.Context) {
	operator, ok := h.getOperatorOr401(c)
	if !ok {
		return
	}
	section, ok := h.getSectionOr404(c)
	if !ok {
		return
	}

	if !h.permSvc.IsGlobalWaterAdmin(operator) {
		c.JSON(http.StatusForbidden, gin.H{"error": "只有管理员可以恢复帖子"})
		return
	}

	postIDStr := c.Param("post_id")
	postID, err := strconv.ParseUint(postIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的帖子 ID"})
		return
	}

	var post models.Post
	if err := h.db.First(&post, postID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}
	if post.BoardID != models.BoardShuitie || post.ContentKind == models.PostContentKindPoll {
		c.JSON(http.StatusBadRequest, gin.H{"error": "只能恢复水帖版块帖子"})
		return
	}
	if post.PostType != section.Slug {
		c.JSON(http.StatusBadRequest, gin.H{"error": "帖子不属于该版块"})
		return
	}
	if post.Status != models.PostStatusDeleted {
		c.JSON(http.StatusBadRequest, gin.H{"error": "帖子未被删除"})
		return
	}

	var input restorePostInput
	_ = c.ShouldBindJSON(&input)
	reason := strings.TrimSpace(input.Reason)
	if reason == "" {
		reason = "恢复帖子"
	} else if validReason, msg := validateModerationReason(reason, "恢复"); msg != "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": msg})
		return
	} else {
		reason = validReason
	}

	before, _ := json.Marshal(gin.H{
		"post_id":   post.ID,
		"author_id": post.AuthorID,
		"status":    post.Status,
	})
	if err := h.db.Model(&post).Update("status", models.PostStatusNormal).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "恢复帖子失败"})
		return
	}
	after, _ := json.Marshal(gin.H{
		"post_id":   post.ID,
		"author_id": post.AuthorID,
		"status":    models.PostStatusNormal,
	})
	h.writeLog(section.ID, operator.ID, models.ModActionRestorePost, "post", uint(postID), &post.AuthorID, reason,
		fmt.Sprintf("before:%s after:%s", before, after))
	h.notifyTarget(post.AuthorID, operator.ID, models.ModActionRestorePost, *section, post.ID, post.ID, reason)
	c.JSON(http.StatusOK, gin.H{"message": "帖子已恢复"})
}

// ── 版块禁言 ──

type muteUserInput struct {
	Reason string `json:"reason" binding:"required"`
	Until  string `json:"until"`
}

// MuteUser POST /api/water/sections/:slug/users/:user_id/mute
func (h *WaterModerationHandler) MuteUser(c *gin.Context) {
	operator, ok := h.getOperatorOr401(c)
	if !ok {
		return
	}
	section, ok := h.getSectionOr404(c)
	if !ok {
		return
	}

	userIDStr := c.Param("user_id")
	targetUserID, err := strconv.ParseUint(userIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户 ID"})
		return
	}

	if !h.permSvc.CanMuteUser(section.ID, operator) {
		c.JSON(http.StatusForbidden, gin.H{"error": "没有禁言权限"})
		return
	}

	// 目标用户存在
	var targetUser models.User
	if err := h.db.First(&targetUser, targetUserID).Error; err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "目标用户不存在"})
		return
	}

	if protected, reason := h.permSvc.IsUserProtectedFromModerator(section.ID, operator, uint(targetUserID)); protected {
		c.JSON(http.StatusForbidden, gin.H{"error": reason})
		return
	}

	var input muteUserInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请填写禁言原因"})
		return
	}
	reason, reasonMsg := validateModerationReason(input.Reason, "禁言")
	if reasonMsg != "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": reasonMsg})
		return
	}

	now := time.Now()
	var until *time.Time
	if strings.TrimSpace(input.Until) != "" {
		parsed, parseErr := time.Parse(time.RFC3339, input.Until)
		if parseErr != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "禁言到期时间格式错误"})
			return
		}
		if !parsed.After(now) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "到期时间必须晚于当前时间"})
			return
		}
		// 版主最长 7 天，管理员最长 30 天
		isAdmin := h.permSvc.IsGlobalWaterAdmin(operator)
		maxDur := 7 * 24 * time.Hour
		if isAdmin {
			maxDur = 30 * 24 * time.Hour
		}
		if parsed.Sub(now) > maxDur {
			c.JSON(http.StatusBadRequest, gin.H{"error": fmt.Sprintf("禁言时长不能超过 %.0f 天", maxDur.Hours()/24)})
			return
		}
		until = &parsed
	}

	// 查找已有记录
	var existing models.WaterSectionMute
	dupErr := h.db.Where("section_id = ? AND user_id = ?", section.ID, targetUserID).First(&existing).Error
	if dupErr == nil && existing.Status == models.MuteStatusActive {
		// 已在禁言 → 更新
		h.db.Model(&existing).Updates(map[string]interface{}{
			"muted_by": operator.ID,
			"reason":   reason,
			"until":    until,
		})
		_ = h.db.First(&existing, existing.ID)
		snapshot, _ := json.Marshal(existing)
		h.writeLog(section.ID, operator.ID, models.ModActionMuteUser, "user", uint(targetUserID), nil, reason, string(snapshot))
		h.notifyTarget(uint(targetUserID), operator.ID, models.ModActionMuteUser, *section, existing.ID, 0, reason)
		c.JSON(http.StatusOK, gin.H{"message": "禁言已更新", "mute": existing})
		return
	}

	if dupErr == nil {
		// 复用 lifted 记录
		h.db.Model(&existing).Updates(map[string]interface{}{
			"muted_by":    operator.ID,
			"reason":      reason,
			"until":       until,
			"status":      models.MuteStatusActive,
			"lifted_by":   nil,
			"lifted_at":   nil,
			"lift_reason": "",
		})
		_ = h.db.First(&existing, existing.ID)
		snapshot, _ := json.Marshal(existing)
		h.writeLog(section.ID, operator.ID, models.ModActionMuteUser, "user", uint(targetUserID), nil, reason, string(snapshot))
		h.notifyTarget(uint(targetUserID), operator.ID, models.ModActionMuteUser, *section, existing.ID, 0, reason)
		c.JSON(http.StatusOK, gin.H{"message": "禁言成功", "mute": existing})
		return
	}

	mute := models.WaterSectionMute{
		SectionID: section.ID,
		UserID:    uint(targetUserID),
		MutedBy:   operator.ID,
		Reason:    reason,
		Until:     until,
		Status:    models.MuteStatusActive,
	}
	if err := h.db.Create(&mute).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "禁言失败"})
		return
	}

	snapshot, _ := json.Marshal(mute)
	h.writeLog(section.ID, operator.ID, models.ModActionMuteUser, "user", uint(targetUserID), nil, reason, string(snapshot))
	h.notifyTarget(uint(targetUserID), operator.ID, models.ModActionMuteUser, *section, mute.ID, 0, reason)
	c.JSON(http.StatusCreated, gin.H{"message": "禁言成功", "mute": mute})
}

// UnmuteUser DELETE /api/water/sections/:slug/users/:user_id/mute
func (h *WaterModerationHandler) UnmuteUser(c *gin.Context) {
	operator, ok := h.getOperatorOr401(c)
	if !ok {
		return
	}
	section, ok := h.getSectionOr404(c)
	if !ok {
		return
	}

	userIDStr := c.Param("user_id")
	targetUserID, err := strconv.ParseUint(userIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户 ID"})
		return
	}

	if !h.permSvc.CanMuteUser(section.ID, operator) {
		c.JSON(http.StatusForbidden, gin.H{"error": "没有禁言权限"})
		return
	}

	var mute models.WaterSectionMute
	dbErr := h.db.Where("section_id = ? AND user_id = ? AND status = ?",
		section.ID, targetUserID, models.MuteStatusActive).First(&mute).Error
	if dbErr == gorm.ErrRecordNotFound {
		c.JSON(http.StatusOK, gin.H{"message": "已解除禁言"})
		return
	}
	if dbErr != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询禁言记录失败"})
		return
	}

	reason := "解除禁言"
	var body struct {
		Reason string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&body); err == nil && body.Reason != "" {
		reason = body.Reason
	}

	now := time.Now()
	h.db.Model(&mute).Updates(map[string]interface{}{
		"status":      models.MuteStatusLifted,
		"lifted_by":   operator.ID,
		"lifted_at":   &now,
		"lift_reason": reason,
	})
	h.writeLog(section.ID, operator.ID, models.ModActionUnmuteUser, "user", uint(targetUserID), nil, reason, "")
	h.notifyTarget(uint(targetUserID), operator.ID, models.ModActionUnmuteUser, *section, mute.ID, 0, reason)
	c.JSON(http.StatusOK, gin.H{"message": "已解除禁言"})
}

// ── 禁言列表 ──

// ListMutes GET /api/water/sections/:slug/mutes
func (h *WaterModerationHandler) ListMutes(c *gin.Context) {
	operator, ok := h.getOperatorOr401(c)
	if !ok {
		return
	}
	section, ok := h.getSectionOr404(c)
	if !ok {
		return
	}

	if !h.permSvc.CanMuteUser(section.ID, operator) {
		c.JSON(http.StatusForbidden, gin.H{"error": "没有查看禁言列表的权限"})
		return
	}

	var mutes []models.WaterSectionMute
	now := time.Now()
	h.db.
		Where("section_id = ? AND status = ? AND (until IS NULL OR until > ?)",
			section.ID, models.MuteStatusActive, now).
		Preload("User").
		Order("created_at DESC").
		Find(&mutes)

	if mutes == nil {
		mutes = []models.WaterSectionMute{}
	}
	c.JSON(http.StatusOK, gin.H{"mutes": mutes})
}

// ── 操作日志 ──

// ListLogs GET /api/water/sections/:slug/moderation/logs
func (h *WaterModerationHandler) ListLogs(c *gin.Context) {
	operator, ok := h.getOperatorOr401(c)
	if !ok {
		return
	}
	section, ok := h.getSectionOr404(c)
	if !ok {
		return
	}

	// admin/super_admin 自动有权限；普通用户检查版主权限
	if !h.permSvc.IsGlobalWaterAdmin(operator) {
		mod, _ := h.permSvc.GetActiveModerator(section.ID, operator.ID)
		if mod == nil {
			c.JSON(http.StatusForbidden, gin.H{"error": "没有查看操作日志的权限"})
			return
		}
	}

	pageStr := c.DefaultQuery("page", "1")
	pageSizeStr := c.DefaultQuery("page_size", "20")
	actionFilter := c.Query("action")

	page, _ := strconv.Atoi(pageStr)
	pageSize, _ := strconv.Atoi(pageSizeStr)
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 100 {
		pageSize = 20
	}

	query := h.db.Where("section_id = ?", section.ID)
	if actionFilter != "" {
		query = query.Where("action = ?", actionFilter)
	}

	var total int64
	query.Model(&models.WaterModerationLog{}).Count(&total)

	var logs []models.WaterModerationLog
	query.Order("created_at DESC").
		Offset((page - 1) * pageSize).
		Limit(pageSize).
		Find(&logs)

	if logs == nil {
		logs = []models.WaterModerationLog{}
	}
	c.JSON(http.StatusOK, gin.H{
		"logs":      logs,
		"total":     total,
		"page":      page,
		"page_size": pageSize,
	})
}

package handlers

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// WaterModeratorHandler 版主任命维护处理器
type WaterModeratorHandler struct {
	db      *gorm.DB
	permSvc *services.WaterPermissionService
}

// NewWaterModeratorHandler 构造
func NewWaterModeratorHandler(db *gorm.DB) *WaterModeratorHandler {
	return &WaterModeratorHandler{
		db:      db,
		permSvc: services.NewWaterPermissionService(db),
	}
}

// moderatorResponse 版主列表/详情返回体
type moderatorResponse struct {
	ID             uint       `json:"id"`
	SectionID      uint       `json:"section_id"`
	SectionSlug    string     `json:"section_slug"`
	UserID         uint       `json:"user_id"`
	User           *userBrief `json:"user,omitempty"`
	Role           string     `json:"role"`
	CanEditSection bool       `json:"can_edit_section"`
	CanManageTags  bool       `json:"can_manage_tags"`
	CanPinPost     bool       `json:"can_pin_post"`
	CanDeletePost  bool       `json:"can_delete_post"`
	CanMuteUser    bool       `json:"can_mute_user"`
	Status         string     `json:"status"`
	AssignedBy     uint       `json:"assigned_by"`
	AssignReason   string     `json:"assign_reason"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
}

// userBrief 公开版主用户摘要（不含私密字段）
type userBrief struct {
	ID       uint   `json:"id"`
	Nickname string `json:"nickname"`
	Avatar   string `json:"avatar"`
}

func userToBrief(u *models.User) *userBrief {
	if u == nil {
		return nil
	}
	return &userBrief{ID: u.ID, Nickname: u.Nickname, Avatar: u.Avatar}
}

func toModeratorResponse(m *models.WaterSectionModerator) moderatorResponse {
	resp := moderatorResponse{
		ID:             m.ID,
		SectionID:      m.SectionID,
		SectionSlug:    m.Section.Slug,
		UserID:         m.UserID,
		User:           userToBrief(&m.User),
		Role:           m.Role,
		CanEditSection: m.CanEditSection,
		CanManageTags:  m.CanManageTags,
		CanPinPost:     m.CanPinPost,
		CanDeletePost:  m.CanDeletePost,
		CanMuteUser:    m.CanMuteUser,
		Status:         m.Status,
		AssignedBy:     m.AssignedBy,
		AssignReason:   m.AssignReason,
		CreatedAt:      m.CreatedAt,
		UpdatedAt:      m.UpdatedAt,
	}
	return resp
}

// requireAdmin 仅 admin / super_admin 可通过
func (h *WaterModeratorHandler) requireAdmin(c *gin.Context) (*models.User, *models.WaterSection, bool) {
	userID, _ := c.Get("user_id")
	role, _ := c.Get("role")
	if role != "admin" && role != "super_admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "需要管理员权限"})
		return nil, nil, false
	}
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "用户不存在", "code": "authentication_required"})
		return nil, nil, false
	}

	slug := c.Param("slug")
	var section models.WaterSection
	if err := h.db.Where("slug = ? AND status = ?", slug, "active").First(&section).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"error": "版块不存在"})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取版块失败"})
		}
		return nil, nil, false
	}
	return &user, &section, true
}

// getSectionBySlug 辅助：获取版块并在不存在时 404
func (h *WaterModeratorHandler) getSectionBySlug(c *gin.Context, slug string) (*models.WaterSection, bool) {
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

// GetModerators GET /api/admin/water/sections/:slug/moderators
// 返回该 section 下所有 active 版主
func (h *WaterModeratorHandler) GetModerators(c *gin.Context) {
	_, section, ok := h.requireAdmin(c)
	if !ok {
		return
	}

	var mods []models.WaterSectionModerator
	if err := h.db.
		Where("section_id = ? AND status = ?", section.ID, models.ModeratorStatusActive).
		Preload("User").
		Preload("Section").
		Order("created_at ASC").
		Find(&mods).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取版主列表失败"})
		return
	}

	resp := make([]moderatorResponse, 0, len(mods))
	for _, m := range mods {
		resp = append(resp, toModeratorResponse(&m))
	}
	c.JSON(http.StatusOK, gin.H{"moderators": resp})
}

// assignModeratorRequest 任命请求体
type assignModeratorRequest struct {
	UserID         uint   `json:"user_id" binding:"required"`
	Role           string `json:"role"`
	CanEditSection *bool  `json:"can_edit_section"`
	CanManageTags  *bool  `json:"can_manage_tags"`
	CanPinPost     *bool  `json:"can_pin_post"`
	CanDeletePost  *bool  `json:"can_delete_post"`
	CanMuteUser    *bool  `json:"can_mute_user"`
	Reason         string `json:"reason"`
}

// AssignModerator POST /api/admin/water/sections/:slug/moderators
// 任命版主，仅 admin/super_admin
func (h *WaterModeratorHandler) AssignModerator(c *gin.Context) {
	_, section, ok := h.requireAdmin(c)
	if !ok {
		return
	}

	var req assignModeratorRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误: " + err.Error()})
		return
	}

	// 目标用户校验
	var targetUser models.User
	if err := h.db.First(&targetUser, req.UserID).Error; err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "目标用户不存在"})
		return
	}
	if targetUser.Role == models.RoleAdmin || targetUser.Role == models.RoleSuperAdmin {
		c.JSON(http.StatusBadRequest, gin.H{"error": "管理员拥有全局权限，不需要被任命为版主"})
		return
	}

	role := models.ModeratorRoleModerator
	if req.Role == models.ModeratorRoleOwner {
		role = models.ModeratorRoleOwner
	}

	// 默认权限
	canPin := true
	canDelete := true
	canMute := true
	canEdit := false
	canManage := false

	if role == models.ModeratorRoleOwner {
		canEdit = true
		canManage = true
	}
	if req.CanPinPost != nil {
		canPin = *req.CanPinPost
	}
	if req.CanDeletePost != nil {
		canDelete = *req.CanDeletePost
	}
	if req.CanMuteUser != nil {
		canMute = *req.CanMuteUser
	}
	if req.CanEditSection != nil {
		canEdit = *req.CanEditSection
	}
	if req.CanManageTags != nil {
		canManage = *req.CanManageTags
	}

	// 查找已有记录
	var existing models.WaterSectionModerator
	err := h.db.Where("section_id = ? AND user_id = ?", section.ID, req.UserID).First(&existing).Error
	if err == nil {
		switch existing.Status {
		case models.ModeratorStatusActive:
			c.JSON(http.StatusConflict, gin.H{"error": "该用户已经是该版块版主，请使用 PATCH 修改权限"})
			return
		case models.ModeratorStatusRevoked:
			// 复用已撤销记录
			existing.Role = role
			existing.CanEditSection = canEdit
			existing.CanManageTags = canManage
			existing.CanPinPost = canPin
			existing.CanDeletePost = canDelete
			existing.CanMuteUser = canMute
			existing.Status = models.ModeratorStatusActive
			existing.AssignedBy = c.GetUint("user_id")
			existing.AssignReason = req.Reason
			existing.RevokedBy = nil
			existing.RevokedAt = nil
			existing.RevokeReason = ""
			if err := h.db.Save(&existing).Error; err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "重新激活版主失败"})
				return
			}
			_ = h.db.Preload("User").Preload("Section").First(&existing, existing.ID)
			c.JSON(http.StatusOK, gin.H{"moderator": toModeratorResponse(&existing)})
			return
		}
	} else if err != gorm.ErrRecordNotFound {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询版主记录失败"})
		return
	}

	mod := models.WaterSectionModerator{
		SectionID:      section.ID,
		UserID:         req.UserID,
		Role:           role,
		CanEditSection: canEdit,
		CanManageTags:  canManage,
		CanPinPost:     canPin,
		CanDeletePost:  canDelete,
		CanMuteUser:    canMute,
		Status:         models.ModeratorStatusActive,
		AssignedBy:     c.GetUint("user_id"),
		AssignReason:   req.Reason,
	}
	if err := h.db.Create(&mod).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "任命版主失败"})
		return
	}
	_ = h.db.Preload("User").Preload("Section").First(&mod, mod.ID)
	c.JSON(http.StatusCreated, gin.H{"moderator": toModeratorResponse(&mod)})
}

// updateModeratorRequest 修改权限请求体
type updateModeratorRequest struct {
	Role           *string `json:"role"`
	CanEditSection *bool   `json:"can_edit_section"`
	CanManageTags  *bool   `json:"can_manage_tags"`
	CanPinPost     *bool   `json:"can_pin_post"`
	CanDeletePost  *bool   `json:"can_delete_post"`
	CanMuteUser    *bool   `json:"can_mute_user"`
	Reason         string  `json:"reason"`
}

// UpdateModerator PATCH /api/admin/water/sections/:slug/moderators/:moderator_id
func (h *WaterModeratorHandler) UpdateModerator(c *gin.Context) {
	_, section, ok := h.requireAdmin(c)
	if !ok {
		return
	}

	modID := c.Param("moderator_id")
	var mod models.WaterSectionModerator
	if err := h.db.Where("id = ? AND section_id = ? AND status = ?",
		modID, section.ID, models.ModeratorStatusActive).First(&mod).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"error": "版主记录不存在或已撤销"})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "查询版主失败"})
		}
		return
	}

	var req updateModeratorRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数错误"})
		return
	}

	updates := map[string]interface{}{}
	if req.Role != nil {
		if *req.Role != models.ModeratorRoleOwner && *req.Role != models.ModeratorRoleModerator {
			c.JSON(http.StatusBadRequest, gin.H{"error": "role 仅允许 owner / moderator"})
			return
		}
		updates["role"] = *req.Role
	}
	if req.CanEditSection != nil {
		updates["can_edit_section"] = *req.CanEditSection
	}
	if req.CanManageTags != nil {
		updates["can_manage_tags"] = *req.CanManageTags
	}
	if req.CanPinPost != nil {
		updates["can_pin_post"] = *req.CanPinPost
	}
	if req.CanDeletePost != nil {
		updates["can_delete_post"] = *req.CanDeletePost
	}
	if req.CanMuteUser != nil {
		updates["can_mute_user"] = *req.CanMuteUser
	}
	if req.Reason != "" {
		updates["assign_reason"] = req.Reason
	}

	if len(updates) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "没有可更新的字段"})
		return
	}

	if err := h.db.Model(&mod).Updates(updates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新版主权限失败"})
		return
	}
	_ = h.db.Preload("User").Preload("Section").First(&mod, mod.ID)
	c.JSON(http.StatusOK, gin.H{"moderator": toModeratorResponse(&mod)})
}

// revokeModeratorRequest 罢免请求体
type revokeModeratorRequest struct {
	Reason string `json:"reason"`
}

// RevokeModerator DELETE /api/admin/water/sections/:slug/moderators/:moderator_id
// 软罢免，不物理删除
func (h *WaterModeratorHandler) RevokeModerator(c *gin.Context) {
	_, section, ok := h.requireAdmin(c)
	if !ok {
		return
	}

	modID := c.Param("moderator_id")
	var mod models.WaterSectionModerator
	if err := h.db.Where("id = ? AND section_id = ?", modID, section.ID).First(&mod).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"error": "版主记录不存在"})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "查询版主失败"})
		}
		return
	}

	// 幂等：已经是 revoked 直接返回成功
	if mod.Status == models.ModeratorStatusRevoked {
		c.JSON(http.StatusOK, gin.H{"message": "版主已被撤销"})
		return
	}

	var req revokeModeratorRequest
	_ = c.ShouldBindJSON(&req)

	now := time.Now()
	updates := map[string]interface{}{
		"status":        models.ModeratorStatusRevoked,
		"revoked_by":    c.GetUint("user_id"),
		"revoked_at":    &now,
		"revoke_reason": req.Reason,
	}
	if err := h.db.Model(&mod).Updates(updates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "罢免版主失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已罢免版主"})
}

// MyPermission GET /api/water/sections/:slug/my-permission
// 当前登录用户对该版块的权限
func (h *WaterModeratorHandler) MyPermission(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "用户不存在", "code": "authentication_required"})
		return
	}

	slug := c.Param("slug")
	section, ok := h.getSectionBySlug(c, slug)
	if !ok {
		return
	}

	perm := h.permSvc.GetPermission(section.ID, &user)
	c.JSON(http.StatusOK, gin.H{"permission": perm})
}

// ---- 供其他 handler 复用的辅助 ----

// GetCurrentUser 从 context 获取用户
func GetCurrentUser(db *gorm.DB, c *gin.Context) (*models.User, bool) {
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未登录", "code": "authentication_required"})
		return nil, false
	}
	var user models.User
	if err := db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "用户不存在", "code": "authentication_required"})
		return nil, false
	}
	return &user, true
}

// 确保 middleware 包被引用（供 go build 使用）
var _ = middleware.GenerateToken

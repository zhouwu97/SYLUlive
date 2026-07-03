package services

import (
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// WaterSectionPermission 当前用户对某版块的权限摘要（返回给客户端）
type WaterSectionPermission struct {
	IsGlobalAdmin      bool   `json:"is_global_admin"`
	IsModerator        bool   `json:"is_moderator"`
	Role               string `json:"role"`

	CanEditSection     bool   `json:"can_edit_section"`
	CanManageTags      bool   `json:"can_manage_tags"`
	CanPinPost         bool   `json:"can_pin_post"`
	CanDeletePost      bool   `json:"can_delete_post"`
	CanMuteUser        bool   `json:"can_mute_user"`
	CanManageModerators bool  `json:"can_manage_moderators"`
}

// WaterPermissionService 版块权限服务
type WaterPermissionService struct {
	db *gorm.DB
}

// NewWaterPermissionService 构造
func NewWaterPermissionService(db *gorm.DB) *WaterPermissionService {
	return &WaterPermissionService{db: db}
}

// IsGlobalWaterAdmin admin / super_admin 拥有所有版块全部权限，不需要被任命为版主
func (s *WaterPermissionService) IsGlobalWaterAdmin(user *models.User) bool {
	if user == nil {
		return false
	}
	return user.Role == models.RoleAdmin || user.Role == models.RoleSuperAdmin
}

// GetActiveModerator 获取某用户在某个 section 的 active 版主记录；没有返回 nil。
func (s *WaterPermissionService) GetActiveModerator(sectionID, userID uint) (*models.WaterSectionModerator, error) {
	var mod models.WaterSectionModerator
	err := s.db.Where("section_id = ? AND user_id = ? AND status = ?",
		sectionID, userID, models.ModeratorStatusActive).First(&mod).Error
	if err == gorm.ErrRecordNotFound {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &mod, nil
}

// GetPermission 返回 user 对指定 section 的权限。
func (s *WaterPermissionService) GetPermission(sectionID uint, user *models.User) *WaterSectionPermission {
	perm := &WaterSectionPermission{}

	if s.IsGlobalWaterAdmin(user) {
		perm.IsGlobalAdmin = true
		perm.IsModerator = true
		perm.Role = string(user.Role)
		perm.CanEditSection = true
		perm.CanManageTags = true
		perm.CanPinPost = true
		perm.CanDeletePost = true
		perm.CanMuteUser = true
		perm.CanManageModerators = true
		return perm
	}

	mod, err := s.GetActiveModerator(sectionID, user.ID)
	if err != nil || mod == nil {
		return perm
	}

	perm.IsModerator = true
	perm.Role = mod.Role
	perm.CanEditSection = mod.CanEditSection
	perm.CanManageTags = mod.CanManageTags
	perm.CanPinPost = mod.CanPinPost
	perm.CanDeletePost = mod.CanDeletePost
	perm.CanMuteUser = mod.CanMuteUser
	perm.CanManageModerators = false // 版主不能任命/罢免版主，只有 admin/super_admin 可以

	return perm
}

// CanManageModerators 仅 admin / super_admin 可以管理版主
func (s *WaterPermissionService) CanManageModerators(user *models.User) bool {
	return s.IsGlobalWaterAdmin(user)
}

// CanEditSection ...
func (s *WaterPermissionService) CanEditSection(sectionID uint, user *models.User) bool {
	return s.GetPermission(sectionID, user).CanEditSection
}

// CanManageTags ...
func (s *WaterPermissionService) CanManageTags(sectionID uint, user *models.User) bool {
	return s.GetPermission(sectionID, user).CanManageTags
}

// CanPinPost ...
func (s *WaterPermissionService) CanPinPost(sectionID uint, user *models.User) bool {
	return s.GetPermission(sectionID, user).CanPinPost
}

// CanDeletePost ...
func (s *WaterPermissionService) CanDeletePost(sectionID uint, user *models.User) bool {
	return s.GetPermission(sectionID, user).CanDeletePost
}

// CanMuteUser ...
func (s *WaterPermissionService) CanMuteUser(sectionID uint, user *models.User) bool {
	return s.GetPermission(sectionID, user).CanMuteUser
}

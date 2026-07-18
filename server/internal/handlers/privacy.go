package handlers

import (
	"fmt"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

// PrivacyHandler 处理个人信息权利请求和账号注销。
type PrivacyHandler struct {
	db *gorm.DB
}

func NewPrivacyHandler(db *gorm.DB) *PrivacyHandler {
	return &PrivacyHandler{db: db}
}

type CancelAccountInput struct {
	Password  string `json:"password" binding:"required"`
	Confirmed bool   `json:"confirmed"`
}

// ExportMyData 直接返回当前用户的账户资料和授权记录，不经过人工审批。
func (h *PrivacyHandler) ExportMyData(c *gin.Context) {
	userID := c.GetUint("user_id")
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	consentState, err := models.LegalConsentStateForUser(h.db, user)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取授权状态失败"})
		return
	}

	consents := make([]models.UserLegalConsent, 0)
	if err := h.db.Where("user_id = ?", userID).Order("accepted_at DESC").Find(&consents).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取授权记录失败"})
		return
	}

	c.Header("Content-Disposition", fmt.Sprintf("attachment; filename=shenliyuan-personal-data-%d.json", userID))
	c.JSON(http.StatusOK, gin.H{
		"exported_at":             time.Now().UTC(),
		"scope":                   "账户资料和法律文件授权记录；不含密码、教务 Cookie、会话令牌及其他认证凭证",
		"legal_consents_active":   consentState == models.LegalConsentStateActive,
		"legal_consents_required": consentState == models.LegalConsentStateRequired,
		"consent_revoked_at":      user.LegalConsentRevokedAt,
		"account": gin.H{
			"id":              user.ID,
			"student_id":      user.StudentID,
			"nickname":        user.Nickname,
			"gender":          user.Gender,
			"avatar":          user.Avatar,
			"background":      user.Background,
			"qq":              user.QQ,
			"created_at":      user.CreatedAt,
			"edu_bound":       user.EduBound,
			"edu_student_id":  user.EduStudentID,
			"edu_grade":       user.EduGrade,
			"edu_college":     user.EduCollege,
			"edu_major":       user.EduMajor,
			"notification_on": user.DeviceToken != "",
		},
		"legal_consents": consents,
	})
}

// WithdrawConsent 立即撤销当前账号的全部授权，并清除依赖授权保存的教务和推送凭证。
func (h *PrivacyHandler) WithdrawConsent(c *gin.Context) {
	var input CancelAccountInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效"})
		return
	}
	if !input.Confirmed {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请确认已知悉撤销同意后的功能限制"})
		return
	}

	userID := c.GetUint("user_id")
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	if user.LegalConsentRevokedAt != nil {
		c.JSON(http.StatusOK, gin.H{
			"message":               "授权已撤销",
			"legal_consents_active": false,
			"revoked_at":            user.LegalConsentRevokedAt,
		})
		return
	}
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(input.Password)); err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "密码错误"})
		return
	}

	// 教务凭证可能由独立服务保存，撤销授权前必须先完成远端清理。
	if user.EduBound {
		response, err := pythonEduRequest(http.MethodDelete, "/api/edu/bind", &userID, nil)
		if err != nil {
			c.JSON(http.StatusBadGateway, gin.H{"error": "教务凭证清除失败，请稍后重试"})
			return
		}
		if response.StatusCode() != http.StatusOK {
			mapEduServiceError(c, response.StatusCode(), response.Body())
			return
		}
	}

	now := time.Now()
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
			"legal_consent_revoked_at": &now,
			"device_token":             "",
			"edu_student_id":           "",
			"edu_password":             "",
			"edu_cookie":               "",
			"edu_bound":                false,
			"edu_grade":                "",
			"edu_college":              "",
			"edu_major":                "",
		}).Error; err != nil {
			return err
		}
		return tx.Model(&models.UserLegalConsent{}).
			Where("user_id = ? AND revoked_at IS NULL", userID).
			Update("revoked_at", &now).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "撤销同意失败"})
		return
	}

	middleware.InvalidateTokenVersionCache(userID)
	c.JSON(http.StatusOK, gin.H{
		"message":               "已撤销全部授权，相关功能已停止使用",
		"legal_consents_active": false,
		"revoked_at":            now,
	})
}

// CancelAccount 以不可逆匿名化方式注销账号，同时保留内容关联和必要审计记录。
func (h *PrivacyHandler) CancelAccount(c *gin.Context) {
	var input CancelAccountInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效"})
		return
	}
	if !input.Confirmed {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请确认已知悉账号注销后不可恢复"})
		return
	}
	userID := c.GetUint("user_id")
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	if user.Role == models.RoleSuperAdmin {
		c.JSON(http.StatusForbidden, gin.H{"error": "超级管理员账号不能自助注销，请先完成管理员交接"})
		return
	}
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(input.Password)); err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "密码错误"})
		return
	}
	// 教务凭证由独立服务保存时，必须先完成远端解绑，避免只清除主库而留下认证凭证。
	if user.EduBound {
		response, err := pythonEduRequest(http.MethodDelete, "/api/edu/bind", &userID, nil)
		if err != nil {
			c.JSON(http.StatusBadGateway, gin.H{"error": "教务凭证清除失败，请稍后重试账号注销"})
			return
		}
		if response.StatusCode() != http.StatusOK {
			mapEduServiceError(c, response.StatusCode(), response.Body())
			return
		}
	}

	randomPassword, err := bcrypt.GenerateFromPassword([]byte(fmt.Sprintf("cancelled-%d-%d", user.ID, time.Now().UnixNano())), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "处理账号注销失败"})
		return
	}
	now := time.Now()
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
			"student_id":     fmt.Sprintf("cancelled-%d-%d", userID, now.UnixNano()),
			"password_hash":  string(randomPassword),
			"nickname":       "已注销用户",
			"gender":         "",
			"avatar":         "",
			"background":     "",
			"qq":             "",
			"device_token":   "",
			"edu_student_id": "",
			"edu_password":   "",
			"edu_cookie":     "",
			"edu_bound":      false,
			"edu_grade":      "",
			"edu_college":    "",
			"edu_major":      "",
			"token_version":  gorm.Expr("token_version + 1"),
		}).Error; err != nil {
			return err
		}
		if err := tx.Where("follower_id = ? OR following_id = ?", userID, userID).Delete(&models.UserFollow{}).Error; err != nil {
			return err
		}
		return tx.Create(&models.PersonalDataRequest{
			UserID: userID, RequestType: models.PersonalDataRequestAccountCancelled,
			Detail: "用户通过密码确认发起账号注销", Status: models.PersonalDataRequestCompleted,
			Result:    "账号身份信息、教务凭证和设备推送标识已匿名化或清除；为履行内容治理和审计义务，内容关联与必要操作记录将按适用法律保留。",
			HandledAt: &now,
		}).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "账号注销失败"})
		return
	}
	middleware.InvalidateTokenVersionCache(userID)
	c.JSON(http.StatusOK, gin.H{"message": "账号已注销并完成本地身份信息匿名化"})
}

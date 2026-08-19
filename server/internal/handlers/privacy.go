package handlers

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// PrivacyHandler 处理个人信息权利请求和账号注销。
type PrivacyHandler struct {
	db                       *gorm.DB
	eduCredentialCleanupJobs *services.EduCredentialCleanupJobService
}

func NewPrivacyHandler(db *gorm.DB) *PrivacyHandler {
	return NewPrivacyHandlerWithEduCredentialCleanup(db, services.NewEduCredentialCleanupJobService(db, nil, time.Now))
}

// NewPrivacyHandlerWithEduCredentialCleanup 创建带教务凭证补偿任务的隐私处理器。
func NewPrivacyHandlerWithEduCredentialCleanup(db *gorm.DB, jobs *services.EduCredentialCleanupJobService) *PrivacyHandler {
	if jobs == nil {
		jobs = services.NewEduCredentialCleanupJobService(db, nil, time.Now)
	}
	return &PrivacyHandler{db: db, eduCredentialCleanupJobs: jobs}
}

type CreatePersonalDataRequestInput struct {
	RequestType string `json:"request_type" binding:"required"`
	Detail      string `json:"detail"`
}

type HandlePersonalDataRequestInput struct {
	Status string `json:"status" binding:"required"`
	Result string `json:"result" binding:"required"`
}

type CancelAccountInput struct {
	Password  string `json:"password" binding:"required"`
	Confirmed bool   `json:"confirmed"`
}

var allowedPersonalDataRequestTypes = map[models.PersonalDataRequestType]struct{}{
	models.PersonalDataRequestCorrection: {},
	models.PersonalDataRequestDeletion:   {},
}

func parsePersonalDataRequestType(value string) (models.PersonalDataRequestType, bool) {
	requestType := models.PersonalDataRequestType(strings.TrimSpace(value))
	_, ok := allowedPersonalDataRequestTypes[requestType]
	return requestType, ok
}

// CreateRequest 仅受理无法由用户直接完成的更正与删除请求。
func (h *PrivacyHandler) CreateRequest(c *gin.Context) {
	var input CreatePersonalDataRequestInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效"})
		return
	}

	requestType, ok := parsePersonalDataRequestType(input.RequestType)
	if !ok {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不支持的个人信息请求类型"})
		return
	}
	detail := strings.TrimSpace(input.Detail)
	if utf8.RuneCountInString(detail) > 500 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求说明不能超过 500 个字符"})
		return
	}

	userID := c.GetUint("user_id")
	var existing models.PersonalDataRequest
	err := h.db.Where(
		"user_id = ? AND request_type = ? AND status IN ?",
		userID,
		requestType,
		[]models.PersonalDataRequestStatus{models.PersonalDataRequestPending, models.PersonalDataRequestProcessing},
	).First(&existing).Error
	if err == nil {
		c.JSON(http.StatusConflict, gin.H{"error": "同类请求正在处理中，请勿重复提交"})
		return
	}
	if err != nil && err != gorm.ErrRecordNotFound {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询请求状态失败"})
		return
	}

	request := models.PersonalDataRequest{
		UserID:      userID,
		RequestType: requestType,
		Detail:      detail,
		Status:      models.PersonalDataRequestPending,
	}
	if err := h.db.Create(&request).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "提交个人信息请求失败"})
		return
	}
	c.JSON(http.StatusCreated, request)
}

// ListMyRequests 返回当前用户自己的请求及处理结果。
func (h *PrivacyHandler) ListMyRequests(c *gin.Context) {
	requests := make([]models.PersonalDataRequest, 0)
	if err := h.db.Where("user_id = ?", c.GetUint("user_id")).Order("created_at DESC").Find(&requests).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取个人信息请求失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": requests})
}

func (h *PrivacyHandler) personalDataPayload(userID uint, includeRequests bool) (gin.H, error) {
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		return nil, err
	}
	consents := make([]models.UserLegalConsent, 0)
	if err := h.db.Where("user_id = ?", userID).Order("accepted_at DESC").Find(&consents).Error; err != nil {
		return nil, err
	}
	consentState, err := models.LegalConsentStateForUser(h.db, user)
	if err != nil {
		return nil, err
	}
	payload := gin.H{
		"exported_at":             time.Now().UTC(),
		"scope":                   "账户资料、法律文件授权记录和个人信息请求记录；不含密码、教务 Cookie、会话令牌、推送标识及内部文件地址",
		"legal_consents_active":   consentState == models.LegalConsentStateActive,
		"legal_consents_required": consentState == models.LegalConsentStateRequired,
		"consent_revoked_at":      user.LegalConsentRevokedAt,
		"account": gin.H{
			"id":                  user.ID,
			"student_id":          user.StudentID,
			"student_verified_at": user.StudentVerifiedAt,
			"email":               user.Email,
			"email_verified_at":   user.EmailVerifiedAt,
			"account_status":      user.AccountStatus,
			"cancelled_at":        user.CancelledAt,
			"nickname":            user.Nickname,
			"gender":              user.Gender,
			"avatar_set":          user.Avatar != "",
			"background_set":      user.Background != "",
			"qq":                  user.QQ,
			"created_at":          user.CreatedAt,
			"edu_bound":           user.IsEduAuthorized(),
			"edu_authorized":      user.IsEduAuthorized(),
			"edu_session_state":   user.EduSessionState,
			"edu_student_id":      user.EduStudentID,
			"edu_grade":           user.EduGrade,
			"edu_college":         user.EduCollege,
			"edu_major":           user.EduMajor,
			"notification_on":     user.DeviceToken != "",
		},
		"legal_consents": consents,
	}
	if includeRequests {
		requests := make([]models.PersonalDataRequest, 0)
		if err := h.db.Where("user_id = ?", userID).Order("created_at DESC").Find(&requests).Error; err != nil {
			return nil, err
		}
		payload["requests"] = requests
	}
	return payload, nil
}

// GetMyData 直接返回当前用户可查阅的账户资料、授权记录和请求摘要。
func (h *PrivacyHandler) GetMyData(c *gin.Context) {
	payload, err := h.personalDataPayload(c.GetUint("user_id"), true)
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取个人数据失败"})
		return
	}
	c.JSON(http.StatusOK, payload)
}

// ExportMyData 直接生成可分享的 JSON，不包含认证凭证或内部地址。
func (h *PrivacyHandler) ExportMyData(c *gin.Context) {
	userID := c.GetUint("user_id")
	payload, err := h.personalDataPayload(userID, true)
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "导出个人数据失败"})
		return
	}
	c.Header("Content-Disposition", fmt.Sprintf("attachment; filename=shenliyuan-personal-data-%d.json", userID))
	c.JSON(http.StatusOK, payload)
}

// WithdrawConsent 立即撤销全部法律文件授权，并清除依赖授权保存的教务和推送凭证。
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
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(input.Password)); err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "密码错误", "code": "INVALID_PASSWORD"})
		return
	}
	needsEduCredentialCleanup := user.IsEduAuthorized()
	now := time.Now()
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
			"legal_consent_revoked_at":     &now,
			"device_token":                 "",
			"push_data_processing_enabled": false,
			"push_installation_id":         "",
			"push_notice_version":          "",
			"push_enabled_at":              nil,
			"edu_password":                 "",
			"edu_cookie":                   "",
			"edu_bound":                    false,
			"edu_authorized":               false,
			"edu_session_state":            "revoked",
			"edu_auto_relogin":             false,
			"edu_cleanup_pending":          needsEduCredentialCleanup,
		}).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.UserLegalConsent{}).
			Where("user_id = ? AND revoked_at IS NULL", userID).
			Update("revoked_at", &now).Error; err != nil {
			return err
		}
		if needsEduCredentialCleanup {
			return h.eduCredentialCleanupJobs.Enqueue(tx, userID, user.EduAuthorizationGeneration, now, false)
		}
		return nil
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "撤销同意失败"})
		return
	}
	middleware.InvalidateTokenVersionCache(userID)
	c.JSON(http.StatusOK, gin.H{
		"message":                 "已撤销全部授权，相关功能已停止使用",
		"legal_consents_active":   false,
		"legal_consents_required": false,
		"revoked_at":              now,
	})
}

// UnbindEdu 解除教务绑定，主库事务成功后再异步清理 Python 服务凭证。
func (h *PrivacyHandler) UnbindEdu(c *gin.Context) {
	userID := c.GetUint("user_id")
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	needsCleanup := user.IsEduAuthorized() || user.EduStudentID != "" || user.EduCookie != "" || user.EduPassword != ""
	now := time.Now()
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
			"edu_password":        "",
			"edu_cookie":          "",
			"edu_bound":           false,
			"edu_authorized":      false,
			"edu_session_state":   "revoked",
			"edu_auto_relogin":    false,
			"edu_cleanup_pending": needsCleanup,
		}).Error; err != nil {
			return err
		}
		if needsCleanup {
			return h.eduCredentialCleanupJobs.Enqueue(tx, userID, user.EduAuthorizationGeneration, now, false)
		}
		return nil
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "解除教务绑定失败"})
		return
	}
	middleware.InvalidateTokenVersionCache(userID)
	c.JSON(http.StatusOK, gin.H{
		"message":         "已解除教务绑定，远端凭证清理中",
		"edu_bound":       false,
		"cleanup_pending": needsCleanup,
	})
}

// ListRequestsForAdmin 供管理员处理个人信息权利请求。
func (h *PrivacyHandler) ListRequestsForAdmin(c *gin.Context) {
	query := h.db.Model(&models.PersonalDataRequest{}).Preload("User")
	if status := strings.TrimSpace(c.Query("status")); status != "" {
		if status != string(models.PersonalDataRequestPending) &&
			status != string(models.PersonalDataRequestProcessing) &&
			status != string(models.PersonalDataRequestCompleted) &&
			status != string(models.PersonalDataRequestRejected) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "不支持的请求状态"})
			return
		}
		query = query.Where("status = ?", status)
	}
	requests := make([]models.PersonalDataRequest, 0)
	if err := query.Order("created_at ASC").Find(&requests).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取个人信息请求失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": requests})
}

// HandleRequest 写入处理状态及答复，答复会向用户展示。
func (h *PrivacyHandler) HandleRequest(c *gin.Context) {
	requestID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的请求 ID"})
		return
	}
	var input HandlePersonalDataRequestInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效"})
		return
	}
	status := models.PersonalDataRequestStatus(strings.TrimSpace(input.Status))
	if status != models.PersonalDataRequestProcessing && status != models.PersonalDataRequestCompleted && status != models.PersonalDataRequestRejected {
		c.JSON(http.StatusBadRequest, gin.H{"error": "处理状态只能是 processing、completed 或 rejected"})
		return
	}
	result := strings.TrimSpace(input.Result)
	if result == "" || utf8.RuneCountInString(result) > 1000 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "处理说明长度需在 1 到 1000 个字符之间"})
		return
	}

	adminID := c.GetUint("user_id")
	now := time.Now()
	var request models.PersonalDataRequest
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.First(&request, uint(requestID)).Error; err != nil {
			return err
		}
		request.Status = status
		request.Result = result
		request.HandlerID = &adminID
		request.HandledAt = &now
		if err := tx.Save(&request).Error; err != nil {
			return err
		}
		return tx.Create(&models.AdminActionLog{
			AdminID: adminID, Action: "handle_personal_data_request", TargetType: "personal_data_request", TargetID: request.ID,
			Detail: fmt.Sprintf("处理个人信息请求: type=%s status=%s", request.RequestType, status),
		}).Error
	}); err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"error": "个人信息请求不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "处理个人信息请求失败"})
		return
	}
	c.JSON(http.StatusOK, request)
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
		c.JSON(http.StatusUnauthorized, gin.H{"error": "密码错误", "code": "INVALID_PASSWORD"})
		return
	}
	randomPassword, err := bcrypt.GenerateFromPassword([]byte(fmt.Sprintf("cancelled-%d-%d", user.ID, time.Now().UnixNano())), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "处理账号注销失败"})
		return
	}
	now := time.Now()
	needsEduCredentialCleanup := user.IsEduAuthorized() || user.EduStudentID != "" || user.EduCookie != "" || user.EduPassword != ""
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
			"student_id":                   "",
			"student_verified_at":          nil,
			"email":                        "",
			"email_verified_at":            nil,
			"account_status":               "cancelled",
			"cancelled_at":                 now,
			"password_hash":                string(randomPassword),
			"nickname":                     "已注销用户",
			"gender":                       "",
			"avatar":                       "",
			"background":                   "",
			"qq":                           "",
			"device_token":                 "",
			"push_data_processing_enabled": false,
			"push_installation_id":         "",
			"push_notice_version":          "",
			"push_enabled_at":              nil,
			"edu_student_id":               "",
			"edu_password":                 "",
			"edu_cookie":                   "",
			"edu_bound":                    false,
			"edu_authorized":               false,
			"edu_session_state":            "revoked",
			"edu_auto_relogin":             false,
			"edu_cleanup_pending":          needsEduCredentialCleanup,
			"edu_grade":                    "",
			"edu_college":                  "",
			"edu_major":                    "",
			"token_version":                gorm.Expr("token_version + 1"),
		}).Error; err != nil {
			return err
		}
		if err := tx.Where("follower_id = ? OR following_id = ?", userID, userID).Delete(&models.UserFollow{}).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.EmailVerificationChallenge{}).
			Where("user_id = ? AND consumed_at IS NULL", userID).
			Update("consumed_at", now).Error; err != nil {
			return err
		}
		if needsEduCredentialCleanup {
			if err := h.eduCredentialCleanupJobs.Enqueue(tx, userID, user.EduAuthorizationGeneration, now, true); err != nil {
				return err
			}
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
	c.JSON(http.StatusOK, gin.H{"message": "账号已注销并完成本地身份信息匿名化，相关远端清理任务已排队", "cleanup_pending": needsEduCredentialCleanup})
}

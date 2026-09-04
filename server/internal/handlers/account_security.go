package handlers

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"shenliyuan/internal/utils"
)

type emailCodeInput struct {
	Email   string `json:"email" binding:"required"`
	Purpose string `json:"purpose" binding:"required"`
}

type emailRegisterInput struct {
	Email    string `json:"email" binding:"required"`
	Code     string `json:"code" binding:"required,len=6"`
	Password string `json:"password" binding:"required,min=8,max=32"`
	Nickname string `json:"nickname"`
	LegalConsentInput
}

type emailUpdateInput struct {
	Email    string `json:"email" binding:"required"`
	Code     string `json:"code" binding:"required,len=6"`
	Password string `json:"password" binding:"required,min=8,max=32"`
}

type emailDeleteInput struct {
	Password string `json:"password" binding:"required,min=8,max=32"`
}

type emailPasswordResetInput struct {
	Email       string `json:"email" binding:"required"`
	Code        string `json:"code" binding:"required,len=6"`
	NewPassword string `json:"new_password" binding:"required,min=8,max=32"`
}

type accountSecurityResponse struct {
	StudentID        string   `json:"student_id"`
	StudentVerified  bool     `json:"student_verified"`
	Email            string   `json:"email"`
	EmailMasked      string   `json:"email_masked"`
	EmailBound       bool     `json:"email_bound"`
	LoginMethods     []string `json:"login_methods"`
	CanResetViaEmail bool     `json:"can_reset_via_email"`
	CanResetViaEdu   bool     `json:"can_reset_via_edu"`
	EduAuthorized    bool     `json:"edu_authorized"`
	EduSessionState  string   `json:"edu_session_state"`
}

// RequestEmailRegistrationCode 发送邮箱注册验证码。外部响应不暴露邮箱是否已注册。
func (h *AuthHandler) RequestEmailRegistrationCode(c *gin.Context) {
	var input emailCodeInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if input.Purpose != models.EmailVerificationPurposeRegister {
		c.JSON(http.StatusBadRequest, gin.H{"error": "验证码用途无效"})
		return
	}
	email, err := services.NormalizeEmail(input.Email)
	if err != nil {
		writeEmailVerificationError(c, err)
		return
	}
	if h.emailVerification == nil {
		writeEmailVerificationError(c, services.ErrMailNotConfigured)
		return
	}
	if err := h.emailVerification.ReservePublicRequest(email, input.Purpose, c.ClientIP()); err != nil {
		writeEmailVerificationError(c, err)
		return
	}
	var existing models.User
	if err := h.db.Where("email = ?", email).First(&existing).Error; errors.Is(err, gorm.ErrRecordNotFound) {
		// 公开接口不向外暴露发送失败，避免通过 SMTP 响应枚举已有账号。
		_ = h.emailVerification.SendReservedPublicRequest(email, input.Purpose, nil, c.ClientIP())
	} else if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取账号失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "如果该邮箱可以使用，验证码将发送至邮箱"})
}

// RegisterWithEmail 创建未完成学生认证的邮箱账号。
func (h *AuthHandler) RegisterWithEmail(c *gin.Context) {
	var input emailRegisterInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if err := input.LegalConsentInput.validate(false); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	email, err := services.NormalizeEmail(input.Email)
	if err != nil {
		writeEmailVerificationError(c, err)
		return
	}
	if h.emailVerification == nil {
		writeEmailVerificationError(c, services.ErrMailNotConfigured)
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(input.Password), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})
		return
	}
	now := time.Now()
	user := models.User{
		StudentID: "", Email: email, EmailVerifiedAt: &now,
		Nickname: strings.TrimSpace(input.Nickname), PasswordHash: string(hash),
		Role: models.RoleUser, CreditScore: 100, EduSessionState: "unbound",
	}
	if user.Nickname == "" {
		user.Nickname = "邮箱用户"
	}
	useGeneratedNickname := strings.TrimSpace(input.Nickname) == ""
	if err := h.emailVerification.UseValidatedChallenge(email, models.EmailVerificationPurposeRegister, input.Code, func(tx *gorm.DB, _ models.EmailVerificationChallenge) error {
		if err := tx.Create(&user).Error; err != nil {
			return err
		}
		if useGeneratedNickname {
			user.Nickname = "邮箱用户" + strconvUserID(user.ID)
			if err := tx.Model(&user).Update("nickname", user.Nickname).Error; err != nil {
				return err
			}
		}
		return recordLegalConsents(tx, user.ID, input.LegalConsentInput, false)
	}); err != nil {
		if isEmailVerificationError(err) {
			writeEmailVerificationError(c, err)
			return
		}
		if utils.IsPostgresUniqueViolation(err) || strings.Contains(strings.ToLower(err.Error()), "unique") {
			c.JSON(http.StatusConflict, gin.H{"error": "该邮箱已绑定其他账号", "code": "EMAIL_ALREADY_BOUND"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建用户失败"})
		return
	}
	h.writeSecurityAudit(user.ID, "email_registered", maskEmail(email))
	h.issueAuthSession(c, user, http.StatusCreated)
}

// RequestUserEmailCode 为已登录用户发送绑定或修改邮箱验证码。
func (h *AuthHandler) RequestUserEmailCode(c *gin.Context) {
	var input emailCodeInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	userID := c.GetUint("user_id")
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	expectedPurpose := models.EmailVerificationPurposeBind
	if user.Email != "" {
		expectedPurpose = models.EmailVerificationPurposeChange
	}
	if input.Purpose != expectedPurpose {
		c.JSON(http.StatusBadRequest, gin.H{"error": "验证码用途与当前账号状态不一致"})
		return
	}
	if err := h.requestEmailCode(c, input.Email, input.Purpose, &userID); err != nil {
		writeEmailVerificationError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "验证码已发送"})
}

// UpdateUserEmail 绑定或修改邮箱，必须验证当前 APP 密码。
func (h *AuthHandler) UpdateUserEmail(c *gin.Context) {
	var input emailUpdateInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	userID := c.GetUint("user_id")
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(input.Password)) != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "APP 密码错误", "code": "INVALID_PASSWORD"})
		return
	}
	email, err := services.NormalizeEmail(input.Email)
	if err != nil {
		writeEmailVerificationError(c, err)
		return
	}
	purpose := models.EmailVerificationPurposeBind
	action := "email_bound"
	if user.Email != "" {
		purpose = models.EmailVerificationPurposeChange
		action = "email_changed"
	}
	now := time.Now()
	if h.emailVerification == nil {
		writeEmailVerificationError(c, services.ErrMailNotConfigured)
		return
	}
	if err := h.emailVerification.UseValidatedChallenge(email, purpose, input.Code, func(tx *gorm.DB, challenge models.EmailVerificationChallenge) error {
		if challenge.UserID == nil || *challenge.UserID != userID {
			return services.ErrCodeNotFound
		}
		var lockedUser models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&lockedUser, userID).Error; err != nil {
			return err
		}
		if bcrypt.CompareHashAndPassword([]byte(lockedUser.PasswordHash), []byte(input.Password)) != nil {
			return errors.New("APP 密码错误")
		}
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
			"email": email, "email_verified_at": now, "token_version": gorm.Expr("token_version + 1"),
		}).Error; err != nil {
			return err
		}
		return tx.Model(&models.EmailVerificationChallenge{}).
			Where("user_id = ? AND purpose = ? AND consumed_at IS NULL", userID, models.EmailVerificationPurposeResetPassword).
			Update("consumed_at", now).Error
	}); err != nil {
		if isEmailVerificationError(err) {
			writeEmailVerificationError(c, err)
			return
		}
		if utils.IsPostgresUniqueViolation(err) || strings.Contains(strings.ToLower(err.Error()), "unique") {
			c.JSON(http.StatusConflict, gin.H{"error": "该邮箱已绑定其他账号", "code": "EMAIL_ALREADY_BOUND"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新邮箱失败"})
		return
	}
	middleware.InvalidateTokenVersionCache(user.ID)
	clearLoginFailures("user:" + strconvUserID(user.ID))
	if err := h.db.First(&user, user.ID).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "刷新账号信息失败"})
		return
	}
	h.writeSecurityAudit(user.ID, action, maskEmail(email))
	h.issueAuthSession(c, user, http.StatusOK)
}

// DeleteUserEmail 解除学生账号的邮箱；未认证学生的邮箱账号不能失去唯一登录方式。
func (h *AuthHandler) DeleteUserEmail(c *gin.Context) {
	var input emailDeleteInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	userID := c.GetUint("user_id")
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	if !user.IsStudentVerified() {
		c.JSON(http.StatusConflict, gin.H{"error": "未完成学生认证的邮箱账号不能解除唯一邮箱"})
		return
	}
	if user.Email == "" || user.EmailVerifiedAt == nil {
		c.JSON(http.StatusConflict, gin.H{"error": "当前未绑定邮箱"})
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(input.Password)) != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "APP 密码错误", "code": "INVALID_PASSWORD"})
		return
	}
	previousEmail := user.Email
	now := time.Now()
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.User{}).Where("id = ?", user.ID).Updates(map[string]interface{}{
			"email": "", "email_verified_at": nil, "token_version": gorm.Expr("token_version + 1"),
		}).Error; err != nil {
			return err
		}
		return tx.Model(&models.EmailVerificationChallenge{}).
			Where("user_id = ? AND purpose = ? AND consumed_at IS NULL", user.ID, models.EmailVerificationPurposeResetPassword).
			Update("consumed_at", now).Error
	}); err != nil {
		if isEmailVerificationError(err) {
			writeEmailVerificationError(c, err)
			return
		}
		if err.Error() == "APP 密码错误" {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "APP 密码错误", "code": "INVALID_PASSWORD"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "解除邮箱失败"})
		return
	}
	middleware.InvalidateTokenVersionCache(user.ID)
	if err := h.db.First(&user, user.ID).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "刷新账号信息失败"})
		return
	}
	h.writeSecurityAudit(user.ID, "email_removed", maskEmail(previousEmail))
	h.issueAuthSession(c, user, http.StatusOK)
}

// RequestEmailPasswordResetCode 对已验证邮箱发送重置验证码，响应不暴露账号是否存在。
func (h *AuthHandler) RequestEmailPasswordResetCode(c *gin.Context) {
	var input emailCodeInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if input.Purpose != models.EmailVerificationPurposeResetPassword {
		c.JSON(http.StatusBadRequest, gin.H{"error": "验证码用途无效"})
		return
	}
	email, err := services.NormalizeEmail(input.Email)
	if err != nil {
		writeEmailVerificationError(c, err)
		return
	}
	if h.emailVerification == nil {
		writeEmailVerificationError(c, services.ErrMailNotConfigured)
		return
	}
	if err := h.emailVerification.ReservePublicRequest(email, input.Purpose, c.ClientIP()); err != nil {
		writeEmailVerificationError(c, err)
		return
	}
	var user models.User
	if err := h.db.Where("email = ? AND email_verified_at IS NOT NULL", email).First(&user).Error; err == nil {
		// 公开接口不向外暴露发送失败，避免通过 SMTP 响应枚举已有账号。
		_ = h.emailVerification.SendReservedPublicRequest(email, input.Purpose, &user.ID, c.ClientIP())
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取账号失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "如果该邮箱可以使用，验证码将发送至邮箱"})
}

// ResetPasswordByEmail 仅重置 APP 密码，不改变学生身份或教务授权。
func (h *AuthHandler) ResetPasswordByEmail(c *gin.Context) {
	var input emailPasswordResetInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	email, err := services.NormalizeEmail(input.Email)
	if err != nil {
		writeEmailVerificationError(c, err)
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(input.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})
		return
	}
	if h.emailVerification == nil {
		writeEmailVerificationError(c, services.ErrMailNotConfigured)
		return
	}
	var user models.User
	if err := h.emailVerification.UseValidatedChallenge(email, models.EmailVerificationPurposeResetPassword, input.Code, func(tx *gorm.DB, challenge models.EmailVerificationChallenge) error {
		if challenge.UserID == nil {
			return services.ErrCodeNotFound
		}
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, *challenge.UserID).Error; err != nil {
			return err
		}
		if user.Email != email || user.EmailVerifiedAt == nil {
			return errors.New("邮箱不可用于密码找回")
		}
		return tx.Model(&models.User{}).Where("id = ?", user.ID).Updates(map[string]interface{}{
			"password_hash": string(hash), "token_version": gorm.Expr("token_version + 1"),
		}).Error
	}); err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "邮箱不可用于密码找回"})
			return
		}
		if err.Error() == "邮箱不可用于密码找回" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "邮箱不可用于密码找回"})
			return
		}
		if errors.Is(err, services.ErrCodeNotFound) || errors.Is(err, services.ErrCodeExpired) || errors.Is(err, services.ErrCodeAttempts) || errors.Is(err, services.ErrCodeInvalid) {
			writeEmailVerificationError(c, err)
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码重置失败"})
		return
	}
	middleware.InvalidateTokenVersionCache(user.ID)
	clearLoginFailures("user:" + strconvUserID(user.ID))
	h.writeSecurityAudit(user.ID, "password_reset_email", "")
	c.JSON(http.StatusOK, gin.H{"message": "密码已重置，请使用新密码登录"})
}

// GetAccountSecurity 返回账号安全页面所需的完整私有资料。
func (h *AuthHandler) GetAccountSecurity(c *gin.Context) {
	var user models.User
	if err := h.db.First(&user, c.GetUint("user_id")).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	loginMethods := make([]string, 0, 2)
	if user.IsStudentVerified() && user.StudentID != "" {
		loginMethods = append(loginMethods, "student_id")
	}
	if user.EmailVerifiedAt != nil && user.Email != "" {
		loginMethods = append(loginMethods, "email")
	}
	c.JSON(http.StatusOK, accountSecurityResponse{
		StudentID: user.StudentID, StudentVerified: user.IsStudentVerified(),
		Email: user.Email, EmailMasked: maskEmail(user.Email), EmailBound: user.EmailVerifiedAt != nil && user.Email != "",
		LoginMethods: loginMethods, CanResetViaEmail: user.EmailVerifiedAt != nil && user.Email != "",
		CanResetViaEdu: user.IsStudentVerified() && user.StudentID != "",
		EduAuthorized:  user.IsEduAuthorized(), EduSessionState: user.EduSessionState,
	})
}

func (h *AuthHandler) requestEmailCode(c *gin.Context, email string, purpose string, userID *uint) error {
	if h.emailVerification == nil {
		return services.ErrMailNotConfigured
	}
	return h.emailVerification.Request(email, purpose, userID, c.ClientIP())
}

func (h *AuthHandler) validateEmailCode(email string, purpose string, code string, consume bool) error {
	if h.emailVerification == nil {
		return services.ErrMailNotConfigured
	}
	return h.emailVerification.Validate(email, purpose, code, consume)
}

func (h *AuthHandler) issueAuthSession(c *gin.Context, user models.User, status int) {
	token, err := middleware.GenerateToken(user.ID, string(user.Role), user.TokenVersion, h.jwtSecret)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法生成 Token"})
		return
	}
	secure := middleware.SecureCookieEnabled()
	c.SetSameSite(http.SameSiteLaxMode)
	c.SetCookie("jwt", token, 7*24*3600, "/api", "", secure, true)
	response, err := selfUserResponseForDB(h.db, user)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取账号状态失败"})
		return
	}
	c.JSON(status, authSessionPayload(c, token, response))
}

func (h *AuthHandler) writeSecurityAudit(userID uint, action string, metadata string) {
	if userID == 0 {
		return
	}
	_ = h.db.Create(&models.AccountSecurityAuditLog{UserID: userID, Action: action, Metadata: metadata}).Error
}

func writeEmailVerificationError(c *gin.Context, err error) {
	status := http.StatusBadRequest
	code := "EMAIL_VERIFICATION_INVALID"
	switch {
	case errors.Is(err, services.ErrSendTooFrequently), errors.Is(err, services.ErrEmailRateLimited), errors.Is(err, services.ErrIPRateLimited):
		status, code = http.StatusTooManyRequests, "EMAIL_VERIFICATION_RATE_LIMITED"
	case errors.Is(err, services.ErrMailNotConfigured):
		status, code = http.StatusServiceUnavailable, "MAIL_UNAVAILABLE"
	case errors.Is(err, services.ErrCodeExpired):
		code = "EMAIL_VERIFICATION_EXPIRED"
	case errors.Is(err, services.ErrCodeAttempts):
		code = "EMAIL_VERIFICATION_ATTEMPTS_EXCEEDED"
	}
	c.JSON(status, gin.H{"error": err.Error(), "code": code})
}

func isEmailVerificationError(err error) bool {
	return errors.Is(err, services.ErrEmailInvalid) ||
		errors.Is(err, services.ErrCodeNotFound) ||
		errors.Is(err, services.ErrCodeExpired) ||
		errors.Is(err, services.ErrCodeAttempts) ||
		errors.Is(err, services.ErrCodeInvalid) ||
		errors.Is(err, services.ErrPurposeInvalid) ||
		errors.Is(err, services.ErrMailNotConfigured)
}

func maskEmail(email string) string {
	parts := strings.SplitN(email, "@", 2)
	if len(parts) != 2 || parts[0] == "" {
		return ""
	}
	local := []rune(parts[0])
	if len(local) <= 2 {
		return string(local[:1]) + "***@" + parts[1]
	}
	return string(local[:2]) + "***@" + parts[1]
}

func strconvUserID(id uint) string {
	return strconv.FormatUint(uint64(id), 10)
}

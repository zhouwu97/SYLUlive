package handlers

import (
	"os"

	"encoding/json"

	"errors"

	"fmt"

	crand "crypto/rand"
	"math/big"

	"mime"

	"net/http"

	"net/smtp"

	"regexp"

	"strconv"

	"strings"

	"sync"

	"time"

	"github.com/gin-gonic/gin"

	"golang.org/x/crypto/bcrypt"

	"gorm.io/gorm"

	"shenliyuan/internal/middleware"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"shenliyuan/internal/utils"
)

// EduServiceConfig 鏁欏姟鏈嶅姟閰嶇疆

var EduServiceConfig = struct {
	BaseURL string
	Token   string
}{

	BaseURL: "", // 浠巆onfig鍔犺浇

}

var VerifyCodeConfig = struct {
	SMTPHost string

	SMTPPort string

	SMTPUser string

	SMTPPass string

	SMTPFrom string
}{}

type verifyCodeRecord struct {
	Code     string
	Attempts int
	SentAt   time.Time

	ExpiresAt time.Time
}

type loginThrottleRecord struct {
	FailureCount int

	LockedUntil time.Time
}

var verifyCodeStore = struct {
	sync.Mutex

	codes map[string]verifyCodeRecord

	verified map[string]time.Time

	ipSends map[string][]time.Time
}{

	codes: map[string]verifyCodeRecord{},

	verified: map[string]time.Time{},

	ipSends: map[string][]time.Time{},
}

var loginThrottleStore = struct {
	sync.Mutex

	records map[string]loginThrottleRecord
}{

	records: map[string]loginThrottleRecord{},
}

// AuthHandler 璁よ瘉澶勭悊鍣

type AuthHandler struct {
	db          *gorm.DB
	cleanupJobs *services.EduCredentialCleanupJobService

	jwtSecret               string
	emailVerification       *services.EmailVerificationService
	accountIdentityReadMode string
	schoolRoutesRetired     bool
}

const (
	AccountIdentityReadModeLegacy   = "legacy"
	AccountIdentityReadModeIdentity = "identity"
)

// NewAuthHandler 鍒涘缓璁よ瘉澶勭悊鍣

func NewAuthHandler(db *gorm.DB, jwtSecret string) *AuthHandler {
	return NewAuthHandlerWithEmailVerificationAndCleanup(db, jwtSecret, nil, nil)

}

// NewAuthHandlerWithEmailVerification 创建使用持久化邮箱验证码服务的认证处理器。
func NewAuthHandlerWithEmailVerification(db *gorm.DB, jwtSecret string, emailVerification *services.EmailVerificationService) *AuthHandler {
	return NewAuthHandlerWithEmailVerificationAndCleanup(db, jwtSecret, emailVerification, nil)

}

// NewAuthHandlerWithEmailVerificationAndCleanup 创建具备教务凭据补偿能力的认证处理器。
func NewAuthHandlerWithEmailVerificationAndCleanup(
	db *gorm.DB,
	jwtSecret string,
	emailVerification *services.EmailVerificationService,
	cleanupJobs *services.EduCredentialCleanupJobService,
) *AuthHandler {
	return &AuthHandler{
		db: db, jwtSecret: jwtSecret, emailVerification: emailVerification, cleanupJobs: cleanupJobs,
		accountIdentityReadMode: AccountIdentityReadModeLegacy,
	}

}

// SetAccountIdentityReadMode 只允许显式选择已定义的登录读路径；现有构造器默认 legacy。
func (h *AuthHandler) SetAccountIdentityReadMode(mode string) error {
	if h == nil {
		return errors.New("认证处理器未配置")
	}
	normalized := strings.ToLower(strings.TrimSpace(mode))
	switch normalized {
	case AccountIdentityReadModeLegacy, AccountIdentityReadModeIdentity:
		h.accountIdentityReadMode = normalized
		return nil
	default:
		return errors.New("账号 Identity 读模式只能是 legacy 或 identity")
	}
}

// SetSchoolAcademicRoutesRetired 同步 Release D 门禁，避免账号安全页继续暴露已退役能力。
func (h *AuthHandler) SetSchoolAcademicRoutesRetired(retired bool) {
	if h != nil {
		h.schoolRoutesRetired = retired
	}
}

type GraduateRegisterInput struct {
	QQ string `json:"qq" binding:"required"`

	Code string `json:"code" binding:"required,len=6"`

	Password string `json:"password" binding:"required,min=8,max=32"`

	Nickname string `json:"nickname"`

	LegalConsentInput
}

// LegalConsentInput 是注册时必填的法律文件确认。教务专项授权只在在校生注册时要求。
type LegalConsentInput struct {
	UserAgreementAccepted    bool `json:"user_agreement_accepted"`
	PrivacyPolicyAccepted    bool `json:"privacy_policy_accepted"`
	CommunityRulesAccepted   bool `json:"community_rules_accepted"`
	MinorProtectionAccepted  bool `json:"minor_protection_accepted"`
	ContentComplaintAccepted bool `json:"content_complaint_accepted"`
	SDKDisclosureAccepted    bool `json:"sdk_disclosure_accepted"`
	EduDataConsentAccepted   bool `json:"edu_data_consent_accepted"`
}

func (input LegalConsentInput) validate(requireEduConsent bool) error {
	if !input.UserAgreementAccepted || !input.PrivacyPolicyAccepted {
		return errors.New("请先阅读并确认用户协议和隐私政策")
	}
	if requireEduConsent && !input.EduDataConsentAccepted {
		return errors.New("使用教务认证前请阅读并同意教务数据专项授权")
	}
	return nil
}

func recordLegalConsents(tx *gorm.DB, userID uint, input LegalConsentInput, includeEduConsent bool) error {
	now := time.Now()
	for _, document := range models.RequiredLegalDocuments(includeEduConsent) {
		acknowledgementType := "agreement"
		scope := "account"
		if document == models.LegalDocumentPrivacyPolicy {
			acknowledgementType = "acknowledged"
		}
		if document == models.LegalDocumentEduDataConsent {
			acknowledgementType = "separate_consent"
			scope = "education"
		}
		consent := models.UserLegalConsent{
			UserID: userID, Document: document, Version: models.LegalDocumentVersion,
			AcknowledgementType: acknowledgementType,
			Scope:               scope,
			Scene:               "registration",
		}
		if err := tx.Where("user_id = ? AND document = ? AND version = ?", userID, document, models.LegalDocumentVersion).
			Assign(map[string]interface{}{"accepted_at": now, "revoked_at": nil}).
			FirstOrCreate(&consent).Error; err != nil {
			return err
		}
	}
	// 兼容旧客户端一次性提交的六项确认：保留历史证据，但明确标记为捆绑告知，不能作为新的独立授权。
	legacyDocuments := map[string]bool{
		models.LegalDocumentCommunityRules:   input.CommunityRulesAccepted,
		models.LegalDocumentMinorProtection:  input.MinorProtectionAccepted,
		models.LegalDocumentContentComplaint: input.ContentComplaintAccepted,
		models.LegalDocumentSDKDisclosure:    input.SDKDisclosureAccepted,
	}
	for document, accepted := range legacyDocuments {
		if !accepted {
			continue
		}
		consent := models.UserLegalConsent{
			UserID: userID, Document: document, Version: models.LegalDocumentVersion,
			AcknowledgementType: "legacy_bundled", Scope: "legacy", Scene: "registration",
		}
		if err := tx.Where("user_id = ? AND document = ? AND version = ?", userID, document, models.LegalDocumentVersion).
			Assign(map[string]interface{}{"accepted_at": now, "revoked_at": nil, "acknowledgement_type": "legacy_bundled", "scope": "legacy", "scene": "registration"}).
			FirstOrCreate(&consent).Error; err != nil {
			return err
		}
	}
	return nil
}

// recordEduBindingConsent 记录绑定教务前取得的专项授权，与注册阶段的同意证据分开保存。
func recordEduBindingConsent(tx *gorm.DB, userID uint) error {
	now := time.Now()
	consent := models.UserLegalConsent{
		UserID: userID, Document: models.LegalDocumentEduDataConsent, Version: models.LegalDocumentVersion,
		AcknowledgementType: "separate_consent", Scope: "education", Scene: "edu_binding",
	}
	return tx.Where("user_id = ? AND document = ? AND version = ? AND scene = ?", userID, consent.Document, consent.Version, consent.Scene).
		Assign(map[string]interface{}{"accepted_at": now, "revoked_at": nil, "acknowledgement_type": consent.AcknowledgementType, "scope": consent.Scope}).
		FirstOrCreate(&consent).Error
}

// AcceptLegalConsents 记录当前协议版本的同意，并恢复已主动撤销授权的账号。
func (h *AuthHandler) AcceptLegalConsents(c *gin.Context) {
	var input LegalConsentInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效"})
		return
	}

	userID := c.GetUint("user_id")
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	if err := input.validate(user.IsEduAuthorized()); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := recordLegalConsents(tx, user.ID, input, user.IsEduAuthorized()); err != nil {
			return err
		}
		return tx.Model(&models.User{}).Where("id = ?", user.ID).Update("legal_consent_revoked_at", nil).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存协议确认失败"})
		return
	}
	if err := h.db.First(&user, user.ID).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "刷新授权状态失败"})
		return
	}
	response, err := selfUserResponseForDB(h.db, user)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取授权状态失败"})
		return
	}
	middleware.InvalidateTokenVersionCache(user.ID)
	c.JSON(http.StatusOK, gin.H{"message": "已确认协议与隐私政策", "user": response})
}

type CommunityRulesInput struct {
	Accepted bool `json:"accepted"`
}

// AcceptCommunityRules 记录社区写操作前的独立规则确认，不参与基础登录门禁。
func (h *AuthHandler) AcceptCommunityRules(c *gin.Context) {
	var input CommunityRulesInput
	if err := c.ShouldBindJSON(&input); err != nil || !input.Accepted {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请明确确认社区规则"})
		return
	}
	userID := c.GetUint("user_id")
	now := time.Now()
	consent := models.UserLegalConsent{
		UserID: userID, Document: models.LegalDocumentCommunityRules,
		Version: models.LegalDocumentVersion, AcknowledgementType: "rules_acceptance",
		Scope: "community_write", Scene: "first_write",
	}
	if err := h.db.Where("user_id = ? AND document = ? AND version = ?", userID, consent.Document, consent.Version).
		Assign(map[string]interface{}{
			"accepted_at": now, "revoked_at": nil,
			"acknowledgement_type": consent.AcknowledgementType,
			"scope":                consent.Scope, "scene": consent.Scene,
		}).FirstOrCreate(&consent).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存社区规则确认失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已确认社区规则"})
}

// deleteIncompleteRegistrationUser 清理注册链路中未完成的账号及其授权留痕。
func deleteIncompleteRegistrationUser(db *gorm.DB, userID uint) error {
	return db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("user_id = ?", userID).Delete(&models.UserLegalConsent{}).Error; err != nil {
			return err
		}
		return tx.Delete(&models.User{}, userID).Error
	})
}

// markIncompleteRegistrationForCleanup 将本地占位账号转为可重试清理状态。
// 即使远端已经删除成功，本地删除失败也必须留下 outbox，不能永久占用学号。
func (h *AuthHandler) markIncompleteRegistrationForCleanup(userID uint, generation uint) error {
	if h == nil || h.db == nil || generation == 0 {
		return errors.New("注册清理参数无效")
	}
	jobs := h.cleanupJobs
	if jobs == nil {
		jobs = services.NewEduCredentialCleanupJobService(h.db, nil, time.Now)
	}
	now := time.Now()
	return h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
			"account_status":                 "registration_cleanup_pending",
			"edu_authorization_generation":   generation,
			"edu_authorized":                 false,
			"edu_bound":                      false,
			"edu_session_state":              "revoked",
			"edu_auto_relogin":               false,
			"edu_cleanup_pending":            true,
			"edu_binding_state":              "cleanup_pending",
			"edu_binding_pending_generation": 0,
			"edu_binding_pending_student_id": "",
			"edu_binding_started_at":         nil,
			"edu_session_updated_at":         now,
			"edu_password":                   "",
			"edu_cookie":                     "",
		}).Error; err != nil {
			return err
		}
		return jobs.Enqueue(tx, userID, generation, now, true)
	})
}

// compensateFailedEduRegistrationBinding 清理注册阶段 Python 已写入、但 Go 身份升级失败的教务凭据。
// 远端暂时不可用时必须保留本地占位账号和持久化 outbox，不能删除唯一可追踪的 user_id。
// 返回 true 表示远端身份已同步清除，调用方可删除本地未完成账号。
func (h *AuthHandler) compensateFailedEduRegistrationBinding(userID uint) bool {
	resp, err := pythonEduRequest(http.MethodDelete, "/api/edu/authorization", &userID, map[string]interface{}{
		"expected_generation": 1,
		"delete_identity":     true,
	})
	if err == nil && resp.StatusCode() == http.StatusOK {
		return true
	}
	if err := h.markIncompleteRegistrationForCleanup(userID, 1); err != nil {
		return false
	}
	return false
}

type verifyCodeInput struct {
	QQ string `json:"qq" binding:"required"`
}

type verifyQQCodeInput struct {
	QQ string `json:"qq" binding:"required"`

	Code string `json:"code" binding:"required,len=6"`
}

func normalizeQQ(input string) string {

	return strings.TrimSpace(input)

}

func normalizeLoginAccount(input string) string {

	return strings.ToLower(strings.TrimSpace(input))

}

func loginLockDurationForFailures(failures int) time.Duration {

	switch {

	case failures >= 6:

		return 10 * time.Minute

	case failures == 5:

		return 5 * time.Minute

	case failures == 4:

		return 3 * time.Minute

	case failures >= 3:

		return 1 * time.Minute

	default:

		return 0

	}

}

func formatRetryAfterCN(d time.Duration) string {

	if d <= 0 {

		return "稍后"

	}

	if d < time.Minute {

		seconds := int(d.Round(time.Second).Seconds())

		if seconds < 1 {

			seconds = 1

		}

		return fmt.Sprintf("%d秒", seconds)

	}

	minutes := int((d + time.Minute - 1) / time.Minute)

	if minutes < 1 {

		minutes = 1

	}

	return fmt.Sprintf("%d分钟", minutes)

}

func currentLoginLock(account string, now time.Time) (time.Duration, bool) {

	loginThrottleStore.Lock()

	defer loginThrottleStore.Unlock()

	record, ok := loginThrottleStore.records[account]

	if !ok {

		return 0, false

	}

	if now.After(record.LockedUntil) || now.Equal(record.LockedUntil) {

		record.LockedUntil = time.Time{}

		loginThrottleStore.records[account] = record

		return 0, false

	}

	return record.LockedUntil.Sub(now), true

}

func registerLoginFailure(account string, now time.Time) time.Duration {

	loginThrottleStore.Lock()

	defer loginThrottleStore.Unlock()

	record := loginThrottleStore.records[account]

	record.FailureCount++

	lockFor := loginLockDurationForFailures(record.FailureCount)

	if lockFor > 0 {

		record.LockedUntil = now.Add(lockFor)

	}

	loginThrottleStore.records[account] = record

	return lockFor

}

func clearLoginFailures(account string) {

	loginThrottleStore.Lock()

	defer loginThrottleStore.Unlock()

	delete(loginThrottleStore.records, account)

}

func validateQQ(qq string) bool {

	return regexp.MustCompile(`^[1-9][0-9]{4,14}$`).MatchString(qq)

}

func generateVerifyCode() string {
	n, _ := crand.Int(crand.Reader, big.NewInt(1000000))
	return fmt.Sprintf("%06d", n.Int64())
}

func markQQVerified(qq string) {

	verifyCodeStore.Lock()

	defer verifyCodeStore.Unlock()

	verifyCodeStore.verified[qq] = time.Now().Add(10 * time.Minute)

}

func isQQVerified(qq string) bool {

	verifyCodeStore.Lock()

	defer verifyCodeStore.Unlock()

	expiresAt, ok := verifyCodeStore.verified[qq]

	if !ok {

		return false

	}

	if time.Now().After(expiresAt) {

		delete(verifyCodeStore.verified, qq)

		return false

	}

	return true

}

func consumeQQVerified(qq string) {

	verifyCodeStore.Lock()

	defer verifyCodeStore.Unlock()

	delete(verifyCodeStore.verified, qq)

	delete(verifyCodeStore.codes, qq)

}

func sendMailCode(qq, code string) error {

	if VerifyCodeConfig.SMTPHost == "" || VerifyCodeConfig.SMTPUser == "" || VerifyCodeConfig.SMTPPass == "" || VerifyCodeConfig.SMTPFrom == "" {

		return errors.New("服务器未配置验证码邮箱，请联系管理员")

	}

	to := qq + "@qq.com"

	addr := VerifyCodeConfig.SMTPHost + ":" + VerifyCodeConfig.SMTPPort

	auth := smtp.PlainAuth("", VerifyCodeConfig.SMTPUser, VerifyCodeConfig.SMTPPass, VerifyCodeConfig.SMTPHost)

	message := buildVerifyCodeEmail(to, VerifyCodeConfig.SMTPFrom, code)

	return smtp.SendMail(addr, auth, VerifyCodeConfig.SMTPFrom, []string{to}, message)
}

func buildVerifyCodeEmail(to, from, code string) []byte {
	subject := mime.QEncoding.Encode("UTF-8", "沈理校园注册验证码")

	body := fmt.Sprintf(`

<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="UTF-8">
  </head>

  <body style="font-family: Arial, 'PingFang SC', 'Microsoft YaHei', sans-serif; line-height: 1.6; color: #222;">

    <h2 style="margin: 0 0 12px;">沈理校园注册验证码</h2>

    <p style="margin: 0 0 8px;">您的验证码为：</p>

    <div style="display: inline-block; padding: 10px 16px; margin: 4px 0 12px; font-size: 28px; font-weight: 700; letter-spacing: 4px; color: #4F46E5; background: #F5F3FF; border-radius: 10px;">

      %s

    </div>

    <p style="margin: 0 0 6px;"><strong>有效期：</strong>10 分钟</p>

    <p style="margin: 0; color: #666;">如果不是本人操作，请忽略此邮件。</p>

  </body>

</html>`, code)

	return []byte("To: " + to + "\r\n" +

		"From: " + from + "\r\n" +

		"Subject: " + subject + "\r\n" +

		"MIME-Version: 1.0\r\n" +

		"Content-Type: text/html; charset=UTF-8\r\n" +

		"Content-Transfer-Encoding: 8bit\r\n\r\n" +

		body)

}

// SendVerifyCode 鍙戦佹瘯涓氱敤鎴锋敞鍐岄獙璇佺爜鍒 QQ 閭绠

func (h *AuthHandler) SendVerifyCode(c *gin.Context) {

	var input verifyCodeInput

	if err := c.ShouldBindJSON(&input); err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})

		return

	}

	qq := normalizeQQ(input.QQ)

	if !validateQQ(qq) {

		c.JSON(http.StatusBadRequest, gin.H{"error": "请输入正确的QQ号"})

		return

	}
	if h.emailVerification != nil {
		// 旧客户端仅能提交 QQ 号；兼容期内统一映射为 QQ 邮箱验证码。
		if err := h.requestEmailCode(c, qq+"@qq.com", models.EmailVerificationPurposeRegister, nil); err != nil {
			writeEmailVerificationError(c, err)
			return
		}
		c.JSON(http.StatusOK, gin.H{"success": true, "message": "验证码已发送"})
		return
	}

	var count int64

	h.db.Model(&models.User{}).Where("student_id = ?", qq).Count(&count)

	if count > 0 {

		c.JSON(http.StatusBadRequest, gin.H{"error": "该QQ号已注册，请直接登录"})

		return

	}

	verifyCodeStore.Lock()
	now := time.Now()
	if previous, exists := verifyCodeStore.codes[qq]; exists && now.Sub(previous.SentAt) < time.Minute {
		verifyCodeStore.Unlock()
		c.JSON(http.StatusTooManyRequests, gin.H{"error": "同一 QQ 请 60 秒后再发送"})
		return
	}
	ip := c.ClientIP()
	recent := verifyCodeStore.ipSends[ip][:0]
	for _, sentAt := range verifyCodeStore.ipSends[ip] {
		if now.Sub(sentAt) < time.Hour {
			recent = append(recent, sentAt)
		}
	}
	if len(recent) >= 10 {
		verifyCodeStore.ipSends[ip] = recent
		verifyCodeStore.Unlock()
		c.JSON(http.StatusTooManyRequests, gin.H{"error": "该 IP 发送验证码过于频繁，请稍后再试"})
		return
	}
	verifyCodeStore.ipSends[ip] = append(recent, now)
	code := generateVerifyCode()

	verifyCodeStore.codes[qq] = verifyCodeRecord{

		Code:   code,
		SentAt: now,

		ExpiresAt: time.Now().Add(10 * time.Minute),
	}

	verifyCodeStore.Unlock()

	if err := sendMailCode(qq, code); err != nil {

		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})

		return

	}

	c.JSON(http.StatusOK, gin.H{"success": true, "message": "验证码已发送"})

}

// VerifyCode 鏍￠獙姣曚笟鐢ㄦ埛閭绠遍獙璇佺爜

func (h *AuthHandler) VerifyCode(c *gin.Context) {

	var input verifyQQCodeInput

	if err := c.ShouldBindJSON(&input); err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})

		return

	}

	qq := normalizeQQ(input.QQ)

	if !validateQQ(qq) {

		c.JSON(http.StatusBadRequest, gin.H{"error": "请输入正确的QQ号"})

		return

	}
	if h.emailVerification != nil {
		// 兼容校验不消费验证码，随后 /register 会原子消费它。
		if err := h.validateEmailCode(qq+"@qq.com", models.EmailVerificationPurposeRegister, input.Code, false); err != nil {
			writeEmailVerificationError(c, err)
			return
		}
		c.JSON(http.StatusOK, gin.H{"success": true, "message": "验证通过"})
		return
	}

	verifyCodeStore.Lock()
	record, ok := verifyCodeStore.codes[qq]
	if ok && time.Now().After(record.ExpiresAt) {
		delete(verifyCodeStore.codes, qq)
		ok = false
	}
	if ok && strings.TrimSpace(input.Code) != record.Code {
		record.Attempts++
		if record.Attempts >= 5 {
			delete(verifyCodeStore.codes, qq)
		} else {
			verifyCodeStore.codes[qq] = record
		}
		verifyCodeStore.Unlock()
		c.JSON(http.StatusBadRequest, gin.H{"error": "验证码错误"})
		return
	}
	verifyCodeStore.Unlock()

	if !ok {

		c.JSON(http.StatusBadRequest, gin.H{"error": "请先发送验证码"})

		return

	}

	if time.Now().After(record.ExpiresAt) {

		c.JSON(http.StatusBadRequest, gin.H{"error": "验证码已过期，请重新发送"})

		return

	}

	markQQVerified(qq)

	c.JSON(http.StatusOK, gin.H{"success": true, "message": "验证通过"})

}

// Register 姣曚笟浜哄憳鏅閫氳处鍙锋敞鍐岋紙QQ 楠岃瘉鐮侊級

func (h *AuthHandler) Register(c *gin.Context) {

	var input GraduateRegisterInput

	if err := c.ShouldBindJSON(&input); err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})

		return

	}
	if err := input.LegalConsentInput.validate(false); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	qq := normalizeQQ(input.QQ)

	if !validateQQ(qq) {

		c.JSON(http.StatusBadRequest, gin.H{"error": "请输入正确的QQ号"})

		return

	}
	email := qq + "@qq.com"

	var count int64

	h.db.Model(&models.User{}).Where("student_id = ?", qq).Count(&count)

	if count > 0 {

		c.JSON(http.StatusBadRequest, gin.H{"error": "该QQ号已注册，请直接登录"})

		return

	}

	// 未启用邮件验证码服务时，沿用旧 QQ 验证完成态；启用后由后续事务校验并消费。
	if h.emailVerification == nil && !isQQVerified(qq) {
		verifyCodeStore.Lock()
		record, ok := verifyCodeStore.codes[qq]
		verifyCodeStore.Unlock()

		if !ok {
			c.JSON(http.StatusBadRequest, gin.H{"error": "请先发送验证码"})
			return
		}
		if time.Now().After(record.ExpiresAt) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "验证码已过期，请重新发送"})
			return
		}
		if strings.TrimSpace(input.Code) != record.Code {
			c.JSON(http.StatusBadRequest, gin.H{"error": "验证码错误"})
			return
		}
	}

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.Password), bcrypt.DefaultCost)

	if err != nil {

		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})

		return

	}

	nickname := strings.TrimSpace(input.Nickname)

	if nickname == "" {

		nickname = "毕业用户"

	}
	useGeneratedNickname := strings.TrimSpace(input.Nickname) == ""

	now := time.Now()
	user := models.User{

		StudentID: "",

		QQ: qq,

		Email: email, EmailVerifiedAt: &now,

		Nickname: nickname,

		PasswordHash: string(hashedPassword),

		Role: models.RoleUser,

		CreditScore: 100,

		EduSessionState: "unbound",
	}

	createUser := func(tx *gorm.DB) error {
		if err := tx.Create(&user).Error; err != nil {
			return err
		}
		if useGeneratedNickname {
			user.Nickname = "毕业用户" + strconv.FormatUint(uint64(user.ID), 10)
			if err := tx.Model(&user).Update("nickname", user.Nickname).Error; err != nil {
				return err
			}
		}
		if _, err := services.CreateEmailIdentity(tx, user.ID, email, now); err != nil {
			return err
		}
		return recordLegalConsents(tx, user.ID, input.LegalConsentInput, false)
	}
	if h.emailVerification != nil {
		err = h.emailVerification.UseValidatedChallenge(email, models.EmailVerificationPurposeRegister, input.Code, func(tx *gorm.DB, _ models.EmailVerificationChallenge) error {
			return createUser(tx)
		})
	} else {
		err = h.db.Transaction(createUser)
	}
	if err != nil {
		if isEmailVerificationError(err) {
			writeEmailVerificationError(c, err)
			return
		}

		if errors.Is(err, services.ErrIdentityConflict) || errors.Is(err, services.ErrIdentityDisabled) ||
			utils.IsPostgresUniqueViolation(err) || strings.Contains(strings.ToLower(err.Error()), "unique") {
			c.JSON(http.StatusConflict, gin.H{"error": "该邮箱已绑定其他账号", "code": "EMAIL_ALREADY_BOUND"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建用户失败"})

		return

	}

	if h.emailVerification == nil {
		consumeQQVerified(qq)
	}

	if h.emailVerification != nil {
		h.writeSecurityAudit(user.ID, "legacy_qq_registered_as_email", maskEmail(email))
	}
	h.issueAuthSession(c, user, http.StatusCreated)

}

// EduRegisterInput 鏁欏姟楠岃瘉鍚庢敞鍐岃緭鍏

type EduRegisterInput struct {
	StudentID string `json:"student_id" binding:"required,len=10"`

	EduPassword string `json:"edu_password" binding:"required"`

	Password string `json:"password" binding:"required,min=8,max=32"`

	Nickname string `json:"nickname"`

	LegalConsentInput
}

// RegisterWithEdu 鏁欏姟楠岃瘉鍚庢敞鍐岋紙瀛﹀彿蹇呴』鍏堥氳繃鏁欏姟楠岃瘉锛

func (h *AuthHandler) RegisterWithEdu(c *gin.Context) {

	var input EduRegisterInput

	if err := c.ShouldBindJSON(&input); err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})

		return

	}
	if err := input.LegalConsentInput.validate(true); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 妫鏌ュ﹀彿鏄鍚﹀凡瀛樺湪

	var count int64

	h.db.Model(&models.User{}).Where("student_id = ?", input.StudentID).Count(&count)

	if count > 0 {

		c.JSON(http.StatusBadRequest, gin.H{"error": "该学号已注册，请直接登录"})

		return

	}

	verifyResult, err := verifyEduWithPython(input.StudentID, input.EduPassword, input.Password)

	if err != nil {

		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})

		return

	}

	if !verifyResult.Success {

		if verifyResult.Message == "" {

			verifyResult.Message = "教务验证失败"

		}

		c.JSON(http.StatusUnauthorized, gin.H{"error": verifyResult.Message, "code": verifyResult.Code})

		return

	}

	if verifyResult.StudentID != "" && verifyResult.StudentID != input.StudentID {

		c.JSON(http.StatusUnauthorized, gin.H{"error": "教务账号与当前学号不一致", "code": "EDU_STUDENT_MISMATCH"})

		return

	}

	// 鍝堝笇App瀵嗙爜

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.Password), bcrypt.DefaultCost)

	if err != nil {

		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})

		return

	}

	// 鍏堝垱寤虹敤鎴

	nickname := input.Nickname

	if nickname == "" {

		nickname = "新用户"

	}

	now := time.Now()
	user := models.User{

		// 在 Python 持久化凭据成功前，账号只作为不可登录的注册占位记录。
		// 这避免进程在跨服务调用前崩溃时留下“已授权但无凭据”的假状态。
		StudentID:     input.StudentID,
		AccountStatus: "registration_pending",

		Nickname: nickname,

		PasswordHash: string(hashedPassword),

		Role: models.RoleUser,

		CreditScore: 100,

		EduAuthorized:               false,
		EduSessionState:             "unbound",
		EduAutoRelogin:              false,
		EduSessionUpdatedAt:         &now,
		EduBindingState:             "pending",
		EduBindingPendingGeneration: 1,
		EduBindingPendingStudentID:  input.StudentID,
		EduBindingStartedAt:         &now,
		EduBound:                    false,
	}

	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Create(&user).Error; err != nil {
			return err
		}
		return recordLegalConsents(tx, user.ID, input.LegalConsentInput, true)
	}); err != nil {
		if utils.IsPostgresUniqueViolation(err) || strings.Contains(strings.ToLower(err.Error()), "unique") {
			c.JSON(http.StatusConflict, gin.H{"error": "该学号已绑定其他账号", "code": "EDU_STUDENT_ALREADY_BOUND"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建用户失败"})

		return

	}

	// 鐢ㄦ埛娌″～鏄电О鏃舵墠鐢ㄩ粯璁ゅ

	if input.Nickname == "" {

		if err := h.db.Model(&user).Update("nickname", "校园用户"+strconv.FormatUint(uint64(user.ID), 10)).Error; err != nil {
			if cleanupErr := deleteIncompleteRegistrationUser(h.db, user.ID); cleanupErr != nil {
				_ = h.markIncompleteRegistrationForCleanup(user.ID, 1)
			}
			c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
			return
		}

		user.Nickname = "校园用户" + strconv.FormatUint(uint64(user.ID), 10)

	}

	// 创建本地账号后，必须由同一条 Go -> Python 绑定链路完成凭据落库。
	bindResult, err := bindEduWithPython(user.ID, input.StudentID, input.EduPassword, 1)
	if err != nil {
		if h.compensateFailedEduRegistrationBinding(user.ID) {
			if cleanupErr := deleteIncompleteRegistrationUser(h.db, user.ID); cleanupErr != nil {
				_ = h.markIncompleteRegistrationForCleanup(user.ID, 1)
			}
		}
		writeEduServiceError(c, err)
		return
	}
	if err := updateUserEduBinding(h.db, user.ID, input.StudentID, bindResult, 1, false); err != nil {
		if h.compensateFailedEduRegistrationBinding(user.ID) {
			if cleanupErr := deleteIncompleteRegistrationUser(h.db, user.ID); cleanupErr != nil {
				_ = h.markIncompleteRegistrationForCleanup(user.ID, 1)
			}
		}
		if errors.Is(err, errEduStudentAlreadyBound) {
			c.JSON(http.StatusConflict, gin.H{"error": "该学号已绑定其他账号", "code": "EDU_STUDENT_ALREADY_BOUND"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "同步教务绑定状态失败"})
		return
	}
	middleware.InvalidateTokenVersionCache(user.ID)
	if err := h.db.First(&user, user.ID).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "刷新注册后的会话失败"})
		return
	}
	h.issueAuthSession(c, user, http.StatusCreated)

}

// LoginInput 鐧诲綍杈撳叆

type LoginInput struct {
	// Account 是新客户端字段；StudentID 保留给兼容客户端。
	Account   string `json:"account"`
	StudentID string `json:"student_id"`

	Password string `json:"password" binding:"required"`
}

// LoginEduInput 缁熶竴鐧诲綍杈撳叆锛堝﹀彿+鏁欏姟瀵嗙爜+APP瀵嗙爜锛

type LoginEduInput struct {
	StudentID string `json:"student_id" binding:"required,len=10"`

	EduPassword string `json:"edu_password" binding:"required"`

	Password string `json:"password" binding:"required,min=8,max=32"`

	LegalConsentInput
}

type eduVerifyResult struct {
	Success bool `json:"success"`

	Message string `json:"message"`

	Code string `json:"code"`

	StudentID string `json:"student_id"`

	Name string `json:"name"`

	Grade string `json:"grade"`

	College string `json:"college"`

	Major string `json:"major"`
}

// LoginEdu 是迁移期独立的旧账号登录入口，只校验 APP 密码。
// 它不接收、不使用教务密码，也不会访问学校系统；Sunset 后由路由层在读取 Body 前返回 410。
func (h *AuthHandler) LoginEdu(c *gin.Context) {
	var input LoginInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	account := input.Account
	if strings.TrimSpace(account) == "" {
		account = input.StudentID
	}
	account = normalizeLoginAccount(account)
	if account == "" || strings.Contains(account, "@") {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "旧账号入口只接受学号或 QQ", "code": "LEGACY_ACCOUNT_REQUIRED",
		})
		return
	}
	h.completePasswordLogin(c, account, input.Password, "legacy", h.findLegacyLoginUser, "legacy_account_login")
}

// ForgotPasswordInput 蹇樿板瘑鐮佽緭鍏

type ForgotPasswordInput struct {
	StudentID string `json:"student_id" binding:"required,len=10"`

	EduPassword string `json:"edu_password" binding:"required"`

	NewPassword string `json:"new_password" binding:"required,min=8,max=32"`
}

// ForgotPassword 浠呭凡娉ㄥ唽杞浠惰处鍙峰彲閫氳繃鏁欏姟璐﹀彿楠岃瘉韬浠藉悗閲嶇疆 APP 瀵嗙爜

func (h *AuthHandler) ForgotPassword(c *gin.Context) {

	var input ForgotPasswordInput

	if err := c.ShouldBindJSON(&input); err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})

		return

	}

	var user models.User

	if err := h.db.Where("student_id = ? AND student_verified_at IS NOT NULL", input.StudentID).First(&user).Error; err != nil {

		c.JSON(http.StatusNotFound, gin.H{"error": "该学号尚未注册，请先注册"})

		return

	}

	result, err := verifyEduWithPython(input.StudentID, input.EduPassword, input.NewPassword)

	if err != nil {

		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})

		return

	}

	if !result.Success {

		if result.Message == "" {

			result.Message = "教务验证失败"

		}

		c.JSON(http.StatusUnauthorized, gin.H{"error": result.Message, "code": result.Code})

		return

	}

	if result.StudentID != "" && result.StudentID != input.StudentID {

		c.JSON(http.StatusUnauthorized, gin.H{"error": "教务账号与当前学号不一致", "code": "EDU_STUDENT_MISMATCH"})

		return

	}

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.NewPassword), bcrypt.DefaultCost)

	if err != nil {

		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})

		return

	}

	updates := map[string]interface{}{

		"password_hash": string(hashedPassword),

		"token_version": gorm.Expr("token_version + 1"),
	}

	if err := h.db.Model(&user).Updates(updates).Error; err != nil {

		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码重置失败"})

		return

	}
	middleware.InvalidateTokenVersionCache(user.ID)

	clearLoginFailures("user:" + strconvUserID(user.ID))
	h.writeSecurityAudit(user.ID, "password_reset_edu", "")

	c.JSON(http.StatusOK, gin.H{"message": "密码已重置，请使用新密码登录"})

}

func verifyEduWithPython(studentID, eduPassword, _ string) (*eduVerifyResult, error) {
	resp, err := pythonEduRequest(http.MethodPost, "/api/edu/pre_verify", nil, map[string]string{
		"student_id": studentID,
		"password":   eduPassword,
	})

	if err != nil {

		return nil, err

	}

	if resp.StatusCode() != http.StatusOK {

		var errResp struct {
			Error string `json:"error"`

			Detail interface{} `json:"detail"`
		}

		_ = json.Unmarshal(resp.Body(), &errResp)

		if errResp.Error != "" {

			return nil, errors.New(errResp.Error)

		}

		switch detail := errResp.Detail.(type) {
		case string:
			if detail != "" {
				return nil, errors.New(detail)
			}
		case map[string]interface{}:
			message, _ := detail["message"].(string)
			if message == "" {
				message, _ = detail["error"].(string)
			}
			if message != "" {
				return nil, errors.New(message)
			}
		}

		return nil, errors.New("教务服务验证失败")

	}

	var result eduVerifyResult

	if err := json.Unmarshal(resp.Body(), &result); err != nil {

		return nil, errors.New("解析教务服务响应失败")

	}

	return &result, nil

}

// Login 在显式完成 S4 切换前保留旧 Email/StudentID/QQ 兼容读路径。
// identity 模式只允许有效 Email Identity，且未命中时绝不回退旧字段。
func (h *AuthHandler) Login(c *gin.Context) {
	var input LoginInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	accountInput := input.Account
	if strings.TrimSpace(accountInput) == "" {
		accountInput = input.StudentID
	}
	if h.accountIdentityReadMode != AccountIdentityReadModeIdentity {
		account := normalizeLoginAccount(accountInput)
		if account == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "请输入学号或邮箱"})
			return
		}
		h.completePasswordLogin(c, account, input.Password, "legacy", h.findLegacyCompatibleLoginUser, "")
		return
	}
	email, err := services.NormalizeEmail(accountInput)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "请使用已验证邮箱登录", "code": "EMAIL_LOGIN_REQUIRED",
		})
		return
	}
	h.completePasswordLogin(c, email, input.Password, "email", h.findLoginUser, "")
}

// findLegacyCompatibleLoginUser 仅供 S0-S3 普通登录读路径使用。
func (h *AuthHandler) findLegacyCompatibleLoginUser(account string) (models.User, error) {
	var user models.User
	if strings.Contains(account, "@") {
		email, err := services.NormalizeEmail(account)
		if err != nil {
			return user, err
		}
		err = h.db.Where("account_status = ? AND email = ? AND email_verified_at IS NOT NULL", "active", email).
			First(&user).Error
		return user, err
	}
	return h.findLegacyLoginUser(account)
}

type loginUserResolver func(account string) (models.User, error)

// completePasswordLogin 统一邮箱和迁移期旧账号入口的限流、APP 密码校验与会话签发。
// resolver 决定身份来源，避免普通 Login 在未命中时出现任何 Legacy fallback。
func (h *AuthHandler) completePasswordLogin(
	c *gin.Context,
	account string,
	password string,
	throttleNamespace string,
	resolver loginUserResolver,
	auditAction string,
) {
	now := time.Now()
	unknownKey := throttleNamespace + ":account:" + account
	if remaining, locked := currentLoginLock(unknownKey, now); locked {
		c.Header("Retry-After", strconv.Itoa(int(remaining.Round(time.Second).Seconds())))
		c.JSON(http.StatusTooManyRequests, gin.H{
			"error": fmt.Sprintf("连续登录失败次数过多，请在%s后重试，或使用忘记密码", formatRetryAfterCN(remaining)),
		})
		return
	}
	user, err := resolver(account)
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			registerLoginFailure(unknownKey, now)
			c.JSON(http.StatusNotFound, gin.H{"error": "账号或密码错误"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询账号失败"})
		return
	}
	userKey := "user:" + strconv.FormatUint(uint64(user.ID), 10)
	if remaining, locked := currentLoginLock(userKey, now); locked {
		c.Header("Retry-After", strconv.Itoa(int(remaining.Round(time.Second).Seconds())))
		c.JSON(http.StatusTooManyRequests, gin.H{"error": fmt.Sprintf("连续登录失败次数过多，请在%s后重试，或使用忘记密码", formatRetryAfterCN(remaining))})
		return
	}
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(password)); err != nil {
		lockFor := registerLoginFailure(userKey, now)
		if lockFor > 0 {
			c.Header("Retry-After", strconv.Itoa(int(lockFor.Round(time.Second).Seconds())))
			c.JSON(http.StatusTooManyRequests, gin.H{
				"error": fmt.Sprintf("连续登录失败次数过多，请在%s后重试，或使用忘记密码", formatRetryAfterCN(lockFor)),
			})
			return
		}
		c.JSON(http.StatusUnauthorized, gin.H{"error": "密码错误，请重新输入", "code": "INVALID_PASSWORD"})
		return
	}
	clearLoginFailures(userKey)
	clearLoginFailures(unknownKey)
	if auditAction != "" {
		h.writeSecurityAudit(user.ID, auditAction, "")
	}
	h.issueAuthSession(c, user, http.StatusOK)
}

// findLoginUser 只从有效且已验证的 Email Identity 解析 user.id。
func (h *AuthHandler) findLoginUser(account string) (models.User, error) {
	var user models.User
	identity, err := services.FindActiveEmailIdentity(h.db, account)
	if err != nil {
		return user, err
	}
	err = h.db.Where("id = ? AND account_status = ?", identity.UserID, "active").First(&user).Error
	return user, err
}

// findLegacyLoginUser 仅供独立迁移路由使用。普通 /api/login 不得调用此函数。
func (h *AuthHandler) findLegacyLoginUser(account string) (models.User, error) {
	var user models.User
	activeUsers := func() *gorm.DB {
		return h.db.Where("account_status = ?", "active")
	}
	switch {
	case regexp.MustCompile(`^[0-9]{8,20}$`).MatchString(account):
		err := activeUsers().Where("student_id = ? AND student_verified_at IS NOT NULL", account).First(&user).Error
		if err == nil || !errors.Is(err, gorm.ErrRecordNotFound) {
			return user, err
		}
		// 数字 QQ 与学号可能重叠，仅在已认证学号未命中时回退兼容旧账号。
		if validateQQ(account) {
			return user, activeUsers().Where("qq = ?", account).First(&user).Error
		}
		return user, gorm.ErrRecordNotFound
	case validateQQ(account):
		return user, activeUsers().Where("qq = ?", account).First(&user).Error
	default:
		return user, gorm.ErrRecordNotFound
	}
}

// ChangePasswordInput 淇鏀瑰瘑鐮佽緭鍏

type ChangePasswordInput struct {
	OldPassword string `json:"old_password" binding:"required"`

	NewPassword string `json:"new_password" binding:"required,min=8,max=32"`
}

// ChangePassword 淇鏀瑰瘑鐮

func (h *AuthHandler) ChangePassword(c *gin.Context) {

	userID, _ := c.Get("user_id")

	var input ChangePasswordInput

	if err := c.ShouldBindJSON(&input); err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})

		return

	}

	var user models.User

	if err := h.db.First(&user, userID).Error; err != nil {

		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})

		return

	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(input.OldPassword)); err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": "旧密码错误"})

		return

	}

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.NewPassword), bcrypt.DefaultCost)

	if err != nil {

		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})

		return

	}

	if err := h.db.Model(&user).Updates(map[string]interface{}{"password_hash": string(hashedPassword), "token_version": gorm.Expr("token_version + 1")}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码修改失败"})
		return
	}
	if err := h.db.First(&user, user.ID).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "刷新密码修改后的会话失败"})
		return
	}
	middleware.InvalidateTokenVersionCache(user.ID)
	h.issueAuthSession(c, user, http.StatusOK)

}

// Logout 退出登录 (清除 cookie)
func (h *AuthHandler) Logout(c *gin.Context) {
	userID, _ := c.Get("user_id")
	if err := h.db.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
		"device_token": "", "push_data_processing_enabled": false,
		"push_installation_id": "", "push_notice_version": "", "push_enabled_at": nil,
		"token_version": gorm.Expr("token_version + 1"),
	}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "退出登录失败"})
		return
	}
	if id, ok := userID.(uint); ok {
		middleware.InvalidateTokenVersionCache(id)
	}
	secure := os.Getenv("SSL") == "true" || os.Getenv("ENV") == "production"
	c.SetSameSite(http.SameSiteLaxMode)
	c.SetCookie("jwt", "", -1, "/api", "", secure, true)
	c.JSON(http.StatusOK, gin.H{"message": "已退出登录"})
}

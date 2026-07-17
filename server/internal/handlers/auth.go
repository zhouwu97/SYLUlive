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
	db *gorm.DB

	jwtSecret string
}

// NewAuthHandler 鍒涘缓璁よ瘉澶勭悊鍣

func NewAuthHandler(db *gorm.DB, jwtSecret string) *AuthHandler {

	return &AuthHandler{db: db, jwtSecret: jwtSecret}

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
	if !input.UserAgreementAccepted || !input.PrivacyPolicyAccepted ||
		!input.CommunityRulesAccepted || !input.MinorProtectionAccepted ||
		!input.ContentComplaintAccepted || !input.SDKDisclosureAccepted {
		return errors.New("请先阅读并同意用户协议、隐私政策、社区规则、未成年人保护规则、投诉举报规则和第三方服务说明")
	}
	if requireEduConsent && !input.EduDataConsentAccepted {
		return errors.New("使用教务认证前请阅读并同意教务数据专项授权")
	}
	return nil
}

func recordLegalConsents(tx *gorm.DB, userID uint, input LegalConsentInput, includeEduConsent bool) error {
	now := time.Now()
	documents := []string{
		models.LegalDocumentUserAgreement,
		models.LegalDocumentPrivacyPolicy,
		models.LegalDocumentCommunityRules,
		models.LegalDocumentMinorProtection,
		models.LegalDocumentContentComplaint,
		models.LegalDocumentSDKDisclosure,
	}
	if includeEduConsent {
		documents = append(documents, models.LegalDocumentEduDataConsent)
	}
	for _, document := range documents {
		if err := tx.Create(&models.UserLegalConsent{
			UserID: userID, Document: document, Version: models.LegalDocumentVersion, AcceptedAt: now,
		}).Error; err != nil {
			return err
		}
	}
	return nil
}

// deleteIncompleteRegistrationUser 清理注册链路中未完成的账号及其授权留痕。
func deleteIncompleteRegistrationUser(db *gorm.DB, userID uint) {
	_ = db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("user_id = ?", userID).Delete(&models.UserLegalConsent{}).Error; err != nil {
			return err
		}
		return tx.Delete(&models.User{}, userID).Error
	})
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

	var count int64

	h.db.Model(&models.User{}).Where("student_id = ?", qq).Count(&count)

	if count > 0 {

		c.JSON(http.StatusBadRequest, gin.H{"error": "该QQ号已注册，请直接登录"})

		return

	}

	// 已验证的凭证是注册唯一可信的完成态。验证码记录可在验证后被清理，
	// 因此不能要求它仍然存在。
	if !isQQVerified(qq) {
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

	user := models.User{

		StudentID: qq,

		Nickname: nickname,

		PasswordHash: string(hashedPassword),

		Role: models.RoleUser,

		CreditScore: 100,

		QQ: qq,

		EduBound: false,
	}

	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Create(&user).Error; err != nil {
			return err
		}
		return recordLegalConsents(tx, user.ID, input.LegalConsentInput, false)
	}); err != nil {

		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建用户失败"})

		return

	}

	if strings.TrimSpace(input.Nickname) == "" {

		user.Nickname = "毕业用户" + strconv.FormatUint(uint64(user.ID), 10)

		if err := h.db.Model(&user).Update("nickname", user.Nickname).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
			return
		}

	}

	consumeQQVerified(qq)

	token, err := middleware.GenerateToken(user.ID, string(user.Role), user.TokenVersion, h.jwtSecret)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法生成Token"})
		return
	}

	secure := os.Getenv("SSL") == "true" || os.Getenv("ENV") == "production"
	c.SetSameSite(http.SameSiteLaxMode)
	c.SetCookie("jwt", token, 7*24*3600, "/api", "", secure, true)

	c.JSON(http.StatusCreated, gin.H{

		"token": token,

		"user": selfUserResponse(user),
	})

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

		c.JSON(http.StatusUnauthorized, gin.H{"error": "教务账号与当前学号不一致"})

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

	user := models.User{

		StudentID: input.StudentID,

		Nickname: nickname,

		PasswordHash: string(hashedPassword),

		Role: models.RoleUser,

		CreditScore: 100,

		EduBound: false,
	}

	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Create(&user).Error; err != nil {
			return err
		}
		return recordLegalConsents(tx, user.ID, input.LegalConsentInput, true)
	}); err != nil {

		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建用户失败"})

		return

	}

	// 鐢ㄦ埛娌″～鏄电О鏃舵墠鐢ㄩ粯璁ゅ

	if input.Nickname == "" {

		if err := h.db.Model(&user).Update("nickname", "校园用户"+strconv.FormatUint(uint64(user.ID), 10)).Error; err != nil {
			deleteIncompleteRegistrationUser(h.db, user.ID)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
			return
		}

		user.Nickname = "校园用户" + strconv.FormatUint(uint64(user.ID), 10)

	}

	// 创建本地账号后，必须由同一条 Go -> Python 绑定链路完成凭据落库。
	bindResult, err := bindEduWithPython(user.ID, input.StudentID, input.EduPassword)
	if err != nil {
		deleteIncompleteRegistrationUser(h.db, user.ID)
		writeEduServiceError(c, err)
		return
	}
	if err := updateUserEduBinding(h.db, user.ID, input.StudentID, bindResult); err != nil {
		deleteIncompleteRegistrationUser(h.db, user.ID)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "同步教务绑定状态失败"})
		return
	}
	user.EduBound = true
	user.EduStudentID = input.StudentID
	user.EduGrade = bindResult.Grade
	user.EduCollege = bindResult.College
	user.EduMajor = bindResult.Major

	token, err := middleware.GenerateToken(user.ID, string(user.Role), user.TokenVersion, h.jwtSecret)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法生成Token"})
		return
	}

	secure := os.Getenv("SSL") == "true" || os.Getenv("ENV") == "production"
	c.SetSameSite(http.SameSiteLaxMode)
	c.SetCookie("jwt", token, 7*24*3600, "/api", "", secure, true)

	c.JSON(http.StatusCreated, gin.H{

		"token": token,

		"user": selfUserResponse(user),
	})

}

// LoginInput 鐧诲綍杈撳叆

type LoginInput struct {
	StudentID string `json:"student_id" binding:"required"`

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

// LoginEdu 缁熶竴鐧诲綍锛堟暀鍔￠獙璇+鑷鍔ㄦ敞鍐岋級

func (h *AuthHandler) LoginEdu(c *gin.Context) {

	var input LoginEduInput

	if err := c.ShouldBindJSON(&input); err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})

		return

	}

	// 妫鏌ョ敤鎴锋槸鍚﹀凡瀛樺湪

	var user models.User

	err := h.db.Where("student_id = ?", input.StudentID).First(&user).Error

	isNewUser := err == gorm.ErrRecordNotFound

	if isNewUser {
		if err := input.LegalConsentInput.validate(true); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}

		// 新用户先预验证，再在创建本地账号后调用统一绑定链路持久化凭据。
		result, err := verifyEduWithPython(input.StudentID, input.EduPassword, input.Password)
		if err != nil {
			c.JSON(http.StatusBadGateway, gin.H{"error": err.Error()})
			return
		}

		if !result.Success {

			c.JSON(http.StatusUnauthorized, gin.H{"error": result.Message, "code": result.Code})

			return

		}

		// 鍝堝笇APP瀵嗙爜

		hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.Password), bcrypt.DefaultCost)

		if err != nil {

			c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})

			return

		}

		// 鍒涘缓鐢ㄦ埛

		user = models.User{

			StudentID: input.StudentID,

			Nickname: input.StudentID,

			PasswordHash: string(hashedPassword),

			Role: models.RoleUser,

			CreditScore: 100,

			EduBound: false,
		}

		if err := h.db.Transaction(func(tx *gorm.DB) error {
			if err := tx.Create(&user).Error; err != nil {
				return err
			}
			return recordLegalConsents(tx, user.ID, input.LegalConsentInput, true)
		}); err != nil {

			c.JSON(http.StatusInternalServerError, gin.H{"error": "创建用户失败"})

			return

		}

		bindResult, err := bindEduWithPython(user.ID, input.StudentID, input.EduPassword)
		if err != nil {
			deleteIncompleteRegistrationUser(h.db, user.ID)
			writeEduServiceError(c, err)
			return
		}
		if err := updateUserEduBinding(h.db, user.ID, input.StudentID, bindResult); err != nil {
			deleteIncompleteRegistrationUser(h.db, user.ID)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "同步教务绑定状态失败"})
			return
		}
		user.EduBound = true
		user.EduStudentID = input.StudentID
		user.EduGrade = bindResult.Grade
		user.EduCollege = bindResult.College
		user.EduMajor = bindResult.Major

	} else {

		// 鑰佺敤鎴凤細楠岃瘉APP瀵嗙爜

		if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(input.Password)); err != nil {

			c.JSON(http.StatusUnauthorized, gin.H{"error": "APP密码错误"})

			return

		}

		bindResult, err := bindEduWithPython(user.ID, input.StudentID, input.EduPassword)
		if err != nil {
			writeEduServiceError(c, err)
			return
		}
		if err := updateUserEduBinding(h.db, user.ID, input.StudentID, bindResult); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "同步教务绑定状态失败"})
			return
		}
		user.EduBound = true
		user.EduStudentID = input.StudentID
		user.EduGrade = bindResult.Grade
		user.EduCollege = bindResult.College
		user.EduMajor = bindResult.Major

	}

	token, err := middleware.GenerateToken(user.ID, string(user.Role), user.TokenVersion, h.jwtSecret)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法生成Token"})
		return
	}

	secure := os.Getenv("SSL") == "true" || os.Getenv("ENV") == "production"
	c.SetSameSite(http.SameSiteLaxMode)
	c.SetCookie("jwt", token, 7*24*3600, "/api", "", secure, true)

	c.JSON(http.StatusOK, gin.H{

		"token": token,

		"user": selfUserResponse(user),
	})

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

	if err := h.db.Where("student_id = ?", input.StudentID).First(&user).Error; err != nil {

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

		c.JSON(http.StatusUnauthorized, gin.H{"error": "教务账号与当前学号不一致"})

		return

	}

	bindResult, err := bindEduWithPython(user.ID, input.StudentID, input.EduPassword)
	if err != nil {
		writeEduServiceError(c, err)
		return
	}

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.NewPassword), bcrypt.DefaultCost)

	if err != nil {

		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码加密失败"})

		return

	}

	updates := map[string]interface{}{

		"password_hash": string(hashedPassword),

		"edu_student_id": input.StudentID,

		"edu_password": "",

		"edu_cookie": "",

		"edu_bound": true,

		"token_version": gorm.Expr("token_version + 1"),
	}

	if bindResult.Grade != "" {

		updates["edu_grade"] = bindResult.Grade

	}

	if bindResult.College != "" {

		updates["edu_college"] = bindResult.College

	}

	if bindResult.Major != "" {

		updates["edu_major"] = bindResult.Major

	}

	if err := h.db.Model(&user).Updates(updates).Error; err != nil {

		c.JSON(http.StatusInternalServerError, gin.H{"error": "密码重置失败"})

		return

	}
	middleware.InvalidateTokenVersionCache(user.ID)

	clearLoginFailures(normalizeLoginAccount(input.StudentID))

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

// Login 鐧诲綍

func (h *AuthHandler) Login(c *gin.Context) {

	var input LoginInput

	if err := c.ShouldBindJSON(&input); err != nil {

		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})

		return

	}

	account := normalizeLoginAccount(input.StudentID)

	now := time.Now()

	if remaining, locked := currentLoginLock(account, now); locked {

		c.Header("Retry-After", strconv.Itoa(int(remaining.Round(time.Second).Seconds())))

		c.JSON(http.StatusTooManyRequests, gin.H{

			"error": fmt.Sprintf("连续登录失败次数过多，请在%s后重试，或使用忘记密码", formatRetryAfterCN(remaining)),
		})

		return

	}

	var user models.User

	if err := h.db.Where("student_id = ?", input.StudentID).First(&user).Error; err != nil {

		if errors.Is(err, gorm.ErrRecordNotFound) {

			c.JSON(http.StatusNotFound, gin.H{"error": "该账号尚未注册，请先注册"})

			return

		}

		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询账号失败"})

		return

	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(input.Password)); err != nil {

		lockFor := registerLoginFailure(account, now)

		if lockFor > 0 {

			c.Header("Retry-After", strconv.Itoa(int(lockFor.Round(time.Second).Seconds())))

			c.JSON(http.StatusTooManyRequests, gin.H{

				"error": fmt.Sprintf("连续登录失败次数过多，请在%s后重试，或使用忘记密码", formatRetryAfterCN(lockFor)),
			})

			return

		}

		c.JSON(http.StatusUnauthorized, gin.H{"error": "密码错误，请重新输入"})

		return

	}

	clearLoginFailures(account)

	token, err := middleware.GenerateToken(user.ID, string(user.Role), user.TokenVersion, h.jwtSecret)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法生成Token"})
		return
	}

	secure := os.Getenv("SSL") == "true" || os.Getenv("ENV") == "production"
	c.SetSameSite(http.SameSiteLaxMode)
	c.SetCookie("jwt", token, 7*24*3600, "/api", "", secure, true)

	c.JSON(http.StatusOK, gin.H{

		"token": token,

		"user": selfUserResponse(user),
	})

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
	middleware.InvalidateTokenVersionCache(user.ID)

	c.JSON(http.StatusOK, gin.H{"message": "密码修改成功"})

}

// Logout 退出登录 (清除 cookie)
func (h *AuthHandler) Logout(c *gin.Context) {
	userID, _ := c.Get("user_id")
	if err := h.db.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
		"device_token":  "",
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

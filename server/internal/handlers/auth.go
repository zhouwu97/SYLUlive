package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"net/http"
	"net/smtp"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/go-resty/resty/v2"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

// EduServiceConfig 鏁欏姟鏈嶅姟閰嶇疆
var EduServiceConfig = struct {
	BaseURL string
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
	Code      string
	ExpiresAt time.Time
}

type loginThrottleRecord struct {
	FailureCount int
	LockedUntil  time.Time
}

var verifyCodeStore = struct {
	sync.Mutex
	codes    map[string]verifyCodeRecord
	verified map[string]time.Time
}{
	codes:    map[string]verifyCodeRecord{},
	verified: map[string]time.Time{},
}

var loginThrottleStore = struct {
	sync.Mutex
	records map[string]loginThrottleRecord
}{
	records: map[string]loginThrottleRecord{},
}

// AuthHandler 璁よ瘉澶勭悊鍣
type AuthHandler struct {
	db        *gorm.DB
	jwtSecret string
}

// NewAuthHandler 鍒涘缓璁よ瘉澶勭悊鍣
func NewAuthHandler(db *gorm.DB, jwtSecret string) *AuthHandler {
	return &AuthHandler{db: db, jwtSecret: jwtSecret}
}

type GraduateRegisterInput struct {
	QQ       string `json:"qq" binding:"required"`
	Code     string `json:"code" binding:"required,len=6"`
	Password string `json:"password" binding:"required,min=8,max=32"`
	Nickname string `json:"nickname"`
}

type verifyCodeInput struct {
	QQ string `json:"qq" binding:"required"`
}

type verifyQQCodeInput struct {
	QQ   string `json:"qq" binding:"required"`
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
		return "绋嶅悗"
	}
	if d < time.Minute {
		seconds := int(d.Round(time.Second).Seconds())
		if seconds < 1 {
			seconds = 1
		}
		return fmt.Sprintf("%d绉", seconds)
	}
	minutes := int((d + time.Minute - 1) / time.Minute)
	if minutes < 1 {
		minutes = 1
	}
	return fmt.Sprintf("%d鍒嗛挓", minutes)
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
	return fmt.Sprintf("%06d", rand.New(rand.NewSource(time.Now().UnixNano())).Intn(1000000))
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
		return errors.New("鏈嶅姟鍣ㄦ湭閰嶇疆楠岃瘉鐮侀偖绠憋紝璇疯仈绯荤＄悊鍛")
	}
	to := qq + "@qq.com"
	addr := VerifyCodeConfig.SMTPHost + ":" + VerifyCodeConfig.SMTPPort
	auth := smtp.PlainAuth("", VerifyCodeConfig.SMTPUser, VerifyCodeConfig.SMTPPass, VerifyCodeConfig.SMTPHost)
	subject := "娌堢悊鏍″洯娉ㄥ唽楠岃瘉鐮"
	body := fmt.Sprintf(`
<html>
  <body style="font-family: Arial, 'PingFang SC', 'Microsoft YaHei', sans-serif; line-height: 1.6; color: #222;">
    <h2 style="margin: 0 0 12px;">娌堢悊鏍″洯娉ㄥ唽楠岃瘉鐮</h2>
    <p style="margin: 0 0 8px;">鎮ㄧ殑楠岃瘉鐮佷负锛</p>
    <div style="display: inline-block; padding: 10px 16px; margin: 4px 0 12px; font-size: 28px; font-weight: 700; letter-spacing: 4px; color: #4F46E5; background: #F5F3FF; border-radius: 10px;">
      %s
    </div>
    <p style="margin: 0 0 6px;"><strong>鏈夋晥鏈燂細</strong>10 鍒嗛挓</p>
    <p style="margin: 0; color: #666;">濡傛灉涓嶆槸鏈浜烘搷浣滐紝璇峰拷鐣ユら偖浠躲</p>
  </body>
</html>`, code)
	message := []byte("To: " + to + "\r\n" +
		"From: " + VerifyCodeConfig.SMTPFrom + "\r\n" +
		"Subject: " + subject + "\r\n" +
		"MIME-Version: 1.0\r\n" +
		"Content-Type: text/html; charset=UTF-8\r\n\r\n" +
		body)
	return smtp.SendMail(addr, auth, VerifyCodeConfig.SMTPFrom, []string{to}, message)
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
		c.JSON(http.StatusBadRequest, gin.H{"error": "璇疯緭鍏ユｇ‘鐨凲Q鍙"})
		return
	}

	var count int64
	h.db.Model(&models.User{}).Where("student_id = ?", qq).Count(&count)
	if count > 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "璇QQ鍙峰凡娉ㄥ唽锛岃风洿鎺ョ櫥褰"})
		return
	}

	code := generateVerifyCode()
	verifyCodeStore.Lock()
	verifyCodeStore.codes[qq] = verifyCodeRecord{
		Code:      code,
		ExpiresAt: time.Now().Add(10 * time.Minute),
	}
	verifyCodeStore.Unlock()

	if err := sendMailCode(qq, code); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"success": true, "message": "楠岃瘉鐮佸凡鍙戦"})
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
		c.JSON(http.StatusBadRequest, gin.H{"error": "璇疯緭鍏ユｇ‘鐨凲Q鍙"})
		return
	}

	verifyCodeStore.Lock()
	record, ok := verifyCodeStore.codes[qq]
	verifyCodeStore.Unlock()
	if !ok {
		c.JSON(http.StatusBadRequest, gin.H{"error": "璇峰厛鍙戦侀獙璇佺爜"})
		return
	}
	if time.Now().After(record.ExpiresAt) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "楠岃瘉鐮佸凡杩囨湡锛岃烽噸鏂板彂閫"})
		return
	}
	if strings.TrimSpace(input.Code) != record.Code {
		c.JSON(http.StatusBadRequest, gin.H{"error": "楠岃瘉鐮侀敊璇"})
		return
	}

	markQQVerified(qq)
	c.JSON(http.StatusOK, gin.H{"success": true, "message": "楠岃瘉閫氳繃"})
}

// Register 姣曚笟浜哄憳鏅閫氳处鍙锋敞鍐岋紙QQ 楠岃瘉鐮侊級
func (h *AuthHandler) Register(c *gin.Context) {
	var input GraduateRegisterInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	qq := normalizeQQ(input.QQ)
	if !validateQQ(qq) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "璇疯緭鍏ユｇ‘鐨凲Q鍙"})
		return
	}

	var count int64
	h.db.Model(&models.User{}).Where("student_id = ?", qq).Count(&count)
	if count > 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "璇QQ鍙峰凡娉ㄥ唽锛岃风洿鎺ョ櫥褰"})
		return
	}

	verifyCodeStore.Lock()
	record, ok := verifyCodeStore.codes[qq]
	verifyCodeStore.Unlock()
	if !ok {
		c.JSON(http.StatusBadRequest, gin.H{"error": "璇峰厛鍙戦侀獙璇佺爜"})
		return
	}
	if time.Now().After(record.ExpiresAt) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "楠岃瘉鐮佸凡杩囨湡锛岃烽噸鏂板彂閫"})
		return
	}
	if strings.TrimSpace(input.Code) != record.Code && !isQQVerified(qq) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "楠岃瘉鐮侀敊璇"})
		return
	}

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.Password), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "瀵嗙爜鍔犲瘑澶辫触"})
		return
	}

	nickname := strings.TrimSpace(input.Nickname)
	if nickname == "" {
		nickname = "姣曚笟鐢ㄦ埛"
	}

	user := models.User{
		StudentID:    qq,
		Nickname:     nickname,
		PasswordHash: string(hashedPassword),
		Role:         models.RoleUser,
		CreditScore:  100,
		QQ:           qq,
		EduBound:     false,
	}
	if err := h.db.Create(&user).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "鍒涘缓鐢ㄦ埛澶辫触"})
		return
	}

	if strings.TrimSpace(input.Nickname) == "" {
		user.Nickname = "姣曚笟鐢ㄦ埛" + strconv.FormatUint(uint64(user.ID), 10)
		h.db.Model(&user).Update("nickname", user.Nickname)
	}

	consumeQQVerified(qq)
	token, _ := middleware.GenerateToken(user.ID, string(user.Role), user.TokenVersion, h.jwtSecret)
	c.JSON(http.StatusCreated, gin.H{
		"token": token,
		"user":  user,
	})
}

// EduRegisterInput 鏁欏姟楠岃瘉鍚庢敞鍐岃緭鍏
type EduRegisterInput struct {
	StudentID   string `json:"student_id" binding:"required,len=10"`
	EduPassword string `json:"edu_password" binding:"required"`
	Password    string `json:"password" binding:"required,min=8,max=32"`
	Nickname    string `json:"nickname"`
}

// RegisterWithEdu 鏁欏姟楠岃瘉鍚庢敞鍐岋紙瀛﹀彿蹇呴』鍏堥氳繃鏁欏姟楠岃瘉锛
func (h *AuthHandler) RegisterWithEdu(c *gin.Context) {
	var input EduRegisterInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 妫鏌ュ﹀彿鏄鍚﹀凡瀛樺湪
	var count int64
	h.db.Model(&models.User{}).Where("student_id = ?", input.StudentID).Count(&count)
	if count > 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "璇ュ﹀彿宸叉敞鍐岋紝璇风洿鎺ョ櫥褰"})
		return
	}

	verifyResult, err := verifyEduWithPython(input.StudentID, input.EduPassword, input.Password)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	if !verifyResult.Success {
		if verifyResult.Message == "" {
			verifyResult.Message = "鏁欏姟楠岃瘉澶辫触"
		}
		c.JSON(http.StatusUnauthorized, gin.H{"error": verifyResult.Message})
		return
	}
	if verifyResult.StudentID != "" && verifyResult.StudentID != input.StudentID {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "鏁欏姟璐﹀彿涓庡綋鍓嶅﹀彿涓嶄竴鑷"})
		return
	}

	// 鍝堝笇App瀵嗙爜
	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.Password), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "瀵嗙爜鍔犲瘑澶辫触"})
		return
	}

	// 鍏堝垱寤虹敤鎴
	nickname := input.Nickname
	if nickname == "" {
		nickname = "鏂扮敤鎴"
	}
	user := models.User{
		StudentID:    input.StudentID,
		Nickname:     nickname,
		PasswordHash: string(hashedPassword),
		Role:         models.RoleUser,
		CreditScore:  100,
		EduStudentID: input.StudentID,
		EduPassword:  input.EduPassword,
		EduBound:     true,
		EduGrade:     verifyResult.Grade,
		EduCollege:   verifyResult.College,
		EduMajor:     verifyResult.Major,
	}

	if err := h.db.Create(&user).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "鍒涘缓鐢ㄦ埛澶辫触"})
		return
	}

	// 鐢ㄦ埛娌″～鏄电О鏃舵墠鐢ㄩ粯璁ゅ
	if input.Nickname == "" {
		h.db.Model(&user).Update("nickname", "鏍″洯鐢ㄦ埛"+strconv.FormatUint(uint64(user.ID), 10))
		user.Nickname = "鏍″洯鐢ㄦ埛" + strconv.FormatUint(uint64(user.ID), 10)
	}

	// 闈欓粯缁戝畾锛氳皟鐢≒ython鐨刡ind鎺ュ彛鑾峰彇cookie
	client := resty.New()
	client.SetTimeout(10 * time.Second)

	resp, err := client.R().
		SetHeader("Content-Type", "application/json").
		SetBody(map[string]interface{}{
			"user_id":    strconv.FormatUint(uint64(user.ID), 10),
			"student_id": input.StudentID,
			"password":   input.EduPassword,
		}).
		Post(EduServiceConfig.BaseURL + "/api/edu/bind")

	if err != nil {
		// Python璋冪敤澶辫触锛屽彧鏍囪板凡缁戝畾锛堝悗缁鍙鎵嬪姩鍒锋柊cookie锛
		h.db.Model(&user).Updates(map[string]interface{}{
			"edu_student_id": input.StudentID,
			"edu_password":   input.EduPassword,
			"edu_bound":      true,
		})
		user.EduBound = true
	} else {
		var bindResult struct {
			Success bool   `json:"success"`
			Message string `json:"message"`
			Name    string `json:"name"`
			Cookie  string `json:"cookie"`
			Grade   string `json:"grade"`
			College string `json:"college"`
			Major   string `json:"major"`
		}
		json.Unmarshal(resp.Body(), &bindResult)
		if bindResult.Success {
			h.db.Model(&user).Updates(map[string]interface{}{
				"edu_student_id": input.StudentID,
				"edu_password":   input.EduPassword,
				"edu_cookie":     bindResult.Cookie,
				"edu_bound":      true,
				"edu_grade":      bindResult.Grade,
				"edu_college":    bindResult.College,
				"edu_major":      bindResult.Major,
			})
			user.EduBound = true
			user.EduCookie = bindResult.Cookie
			user.EduGrade = bindResult.Grade
			user.EduCollege = bindResult.College
			user.EduMajor = bindResult.Major
		} else {
			h.db.Model(&user).Updates(map[string]interface{}{
				"edu_student_id": input.StudentID,
				"edu_password":   input.EduPassword,
				"edu_bound":      true,
				"edu_grade":      verifyResult.Grade,
				"edu_college":    verifyResult.College,
				"edu_major":      verifyResult.Major,
			})
			user.EduBound = true
		}
	}

	token, _ := middleware.GenerateToken(user.ID, string(user.Role), user.TokenVersion, h.jwtSecret)
	c.JSON(http.StatusCreated, gin.H{
		"token": token,
		"user":  user,
	})
}

// LoginInput 鐧诲綍杈撳叆
type LoginInput struct {
	StudentID string `json:"student_id" binding:"required"`
	Password  string `json:"password" binding:"required"`
}

// LoginEduInput 缁熶竴鐧诲綍杈撳叆锛堝﹀彿+鏁欏姟瀵嗙爜+APP瀵嗙爜锛
type LoginEduInput struct {
	StudentID   string `json:"student_id" binding:"required,len=10"`
	EduPassword string `json:"edu_password" binding:"required"`
	Password    string `json:"password" binding:"required,min=8,max=32"`
}

type eduVerifyResult struct {
	Success   bool   `json:"success"`
	Message   string `json:"message"`
	StudentID string `json:"student_id"`
	Name      string `json:"name"`
	Grade     string `json:"grade"`
	College   string `json:"college"`
	Major     string `json:"major"`
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
		// 鏂扮敤鎴凤細閫氳繃Python鏈嶅姟楠岃瘉鏁欏姟
		client := resty.New()
		client.SetTimeout(10 * time.Second)

		resp, err := client.R().
			SetHeader("Content-Type", "application/json").
			SetBody(map[string]string{
				"student_id":   input.StudentID,
				"edu_password": input.EduPassword,
				"password":     input.Password,
			}).
			Post(EduServiceConfig.BaseURL + "/api/edu/login_edu")

		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "鏃犳硶杩炴帴鏁欏姟鏈嶅姟"})
			return
		}

		var result eduVerifyResult
		if err := json.Unmarshal(resp.Body(), &result); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "瑙ｆ瀽鍝嶅簲澶辫触"})
			return
		}

		if !result.Success {
			c.JSON(http.StatusUnauthorized, gin.H{"error": result.Message})
			return
		}

		// 鍝堝笇APP瀵嗙爜
		hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.Password), bcrypt.DefaultCost)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "瀵嗙爜鍔犲瘑澶辫触"})
			return
		}

		// 鍒涘缓鐢ㄦ埛
		user = models.User{
			StudentID:    input.StudentID,
			Nickname:     input.StudentID,
			PasswordHash: string(hashedPassword),
			Role:         models.RoleUser,
			CreditScore:  100,
			EduStudentID: result.StudentID,
			EduPassword:  input.EduPassword,
			EduBound:     true,
			EduGrade:     result.Grade,
			EduCollege:   result.College,
			EduMajor:     result.Major,
		}

		if err := h.db.Create(&user).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "鍒涘缓鐢ㄦ埛澶辫触"})
			return
		}
	} else {
		// 鑰佺敤鎴凤細楠岃瘉APP瀵嗙爜
		if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(input.Password)); err != nil {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "APP瀵嗙爜閿欒"})
			return
		}
	}

	token, _ := middleware.GenerateToken(user.ID, string(user.Role), user.TokenVersion, h.jwtSecret)
	c.JSON(http.StatusOK, gin.H{
		"token": token,
		"user":  user,
	})
}

// ForgotPasswordInput 蹇樿板瘑鐮佽緭鍏
type ForgotPasswordInput struct {
	StudentID   string `json:"student_id" binding:"required,len=10"`
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
		c.JSON(http.StatusNotFound, gin.H{"error": "璇ュ﹀彿灏氭湭娉ㄥ唽锛岃峰厛娉ㄥ唽"})
		return
	}

	result, err := verifyEduWithPython(input.StudentID, input.EduPassword, input.NewPassword)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	if !result.Success {
		if result.Message == "" {
			result.Message = "鏁欏姟楠岃瘉澶辫触"
		}
		c.JSON(http.StatusUnauthorized, gin.H{"error": result.Message})
		return
	}
	if result.StudentID != "" && result.StudentID != input.StudentID {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "鏁欏姟璐﹀彿涓庡綋鍓嶅﹀彿涓嶄竴鑷"})
		return
	}

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "瀵嗙爜鍔犲瘑澶辫触"})
		return
	}

	updates := map[string]interface{}{
		"password_hash":  string(hashedPassword),
		"edu_student_id": input.StudentID,
		"edu_password":   input.EduPassword,
		"edu_bound":      true,
	}
	if result.Grade != "" {
		updates["edu_grade"] = result.Grade
	}
	if result.College != "" {
		updates["edu_college"] = result.College
	}
	if result.Major != "" {
		updates["edu_major"] = result.Major
	}

	if err := h.db.Model(&user).Updates(updates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "瀵嗙爜閲嶇疆澶辫触"})
		return
	}

	clearLoginFailures(normalizeLoginAccount(input.StudentID))
	c.JSON(http.StatusOK, gin.H{"message": "瀵嗙爜宸查噸缃锛岃蜂娇鐢ㄦ柊瀵嗙爜鐧诲綍"})
}

func verifyEduWithPython(studentID, eduPassword, appPassword string) (*eduVerifyResult, error) {
	client := resty.New()
	client.SetTimeout(10 * time.Second)

	resp, err := client.R().
		SetHeader("Content-Type", "application/json").
		SetBody(map[string]string{
			"student_id":   studentID,
			"edu_password": eduPassword,
			"password":     appPassword,
		}).
		Post(EduServiceConfig.BaseURL + "/api/edu/login_edu")
	if err != nil {
		return nil, err
	}
	if resp.StatusCode() != http.StatusOK {
		var errResp struct {
			Error  string `json:"error"`
			Detail string `json:"detail"`
		}
		_ = json.Unmarshal(resp.Body(), &errResp)
		if errResp.Error != "" {
			return nil, errors.New(errResp.Error)
		}
		if errResp.Detail != "" {
			return nil, errors.New(errResp.Detail)
		}
		return nil, errors.New("鏁欏姟鏈嶅姟楠岃瘉澶辫触")
	}

	var result eduVerifyResult
	if err := json.Unmarshal(resp.Body(), &result); err != nil {
		return nil, errors.New("瑙ｆ瀽鏁欏姟鏈嶅姟鍝嶅簲澶辫触")
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
			"error": fmt.Sprintf("杩炵画鐧诲綍澶辫触娆℃暟杩囧氾紝璇峰湪%s鍚庨噸璇曪紝鎴栦娇鐢ㄥ繕璁板瘑鐮", formatRetryAfterCN(remaining)),
		})
		return
	}

	var user models.User
	if err := h.db.Where("student_id = ?", input.StudentID).First(&user).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "璇ヨ处鍙峰皻鏈娉ㄥ唽锛岃峰厛娉ㄥ唽"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "鏌ヨ㈣处鍙峰け璐"})
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(input.Password)); err != nil {
		lockFor := registerLoginFailure(account, now)
		if lockFor > 0 {
			c.Header("Retry-After", strconv.Itoa(int(lockFor.Round(time.Second).Seconds())))
			c.JSON(http.StatusTooManyRequests, gin.H{
				"error": fmt.Sprintf("杩炵画鐧诲綍澶辫触娆℃暟杩囧氾紝璇峰湪%s鍚庨噸璇曪紝鎴栦娇鐢ㄥ繕璁板瘑鐮", formatRetryAfterCN(lockFor)),
			})
			return
		}
		c.JSON(http.StatusUnauthorized, gin.H{"error": "瀵嗙爜閿欒锛岃烽噸鏂拌緭鍏"})
		return
	}

	clearLoginFailures(account)
	token, _ := middleware.GenerateToken(user.ID, string(user.Role), user.TokenVersion, h.jwtSecret)
	c.JSON(http.StatusOK, gin.H{
		"token": token,
		"user":  user,
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
		c.JSON(http.StatusNotFound, gin.H{"error": "鐢ㄦ埛涓嶅瓨鍦"})
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(input.OldPassword)); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "鏃у瘑鐮侀敊璇"})
		return
	}

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(input.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "瀵嗙爜鍔犲瘑澶辫触"})
		return
	}
	h.db.Model(&user).Updates(map[string]interface{}{"password_hash": string(hashedPassword), "token_version": gorm.Expr("token_version + 1")})
	c.JSON(http.StatusOK, gin.H{"message": "瀵嗙爜淇鏀规垚鍔"})
}

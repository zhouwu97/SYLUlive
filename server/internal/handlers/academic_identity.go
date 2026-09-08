package handlers

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/utils"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const (
	academicChallengeTokenVersion = 1
	academicChallengeTTL          = 90 * time.Second
	academicChallengeRateWindow   = 10 * time.Minute
	academicChallengeUserLimit    = 5
	academicChallengeIPLimit      = 20
	academicChallengeMethod       = "school_profile"
	academicChallengeVersion      = "v1"
)

var (
	// ErrAcademicProviderUnavailable 表示真实学校协议尚未接入或学校当前不可用。
	ErrAcademicProviderUnavailable = errors.New("教务 Provider 暂不可用")
	// ErrAcademicIdentityRejected 表示学校明确拒绝了本次身份验证。
	ErrAcademicIdentityRejected = errors.New("教务身份验证未通过")
	// ErrAcademicCredentialRejected 只表示学校明确返回密码错误，不能由模糊登录失败推导。
	ErrAcademicCredentialRejected = errors.New("教务密码被学校拒绝")
	// ErrAcademicChallengeRejected 表示学校拒绝验证码或挑战上下文。
	ErrAcademicChallengeRejected = errors.New("教务挑战未通过")
	// ErrAcademicAuthRejectedAmbiguous 表示学校没有提供足以区分密码和验证码的错误语义。
	ErrAcademicAuthRejectedAmbiguous = errors.New("教务认证结果无法确定")
	// ErrAcademicAccountRejected 与 ErrAcademicAccountRestricted 保留账号状态领域区别。
	ErrAcademicAccountRejected   = errors.New("教务账号不存在")
	ErrAcademicAccountRestricted = errors.New("教务账号受限")
	ErrAcademicRateLimited       = errors.New("教务请求过于频繁")
	// ErrAcademicIdentityMismatch 表示学校返回的身份与请求身份不一致。
	ErrAcademicIdentityMismatch = errors.New("学校返回的学生身份与请求不一致")
	// ErrAcademicIdentityUnverified 表示旧 Provider 没有返回独立学校学号字段。
	ErrAcademicIdentityUnverified = errors.New("学校没有返回可独立核验的学生身份")
)

// ClassifyAcademicIdentityFailure 只将学校协议中已确认的精确 code/message 映射为明确类别，
// 其余认证失败一律保留 ambiguous，避免把“账号、密码或验证码错误”误判成密码失效。
func ClassifyAcademicIdentityFailure(statusCode int, code, message string) error {
	code = strings.ToUpper(strings.TrimSpace(code))
	message = strings.TrimSpace(message)
	switch code {
	case "EDU_IDENTITY_UNVERIFIED", "ACADEMIC_IDENTITY_UNVERIFIED":
		return ErrAcademicIdentityUnverified
	case "EDU_IDENTITY_MISMATCH", "ACADEMIC_IDENTITY_MISMATCH":
		return ErrAcademicIdentityMismatch
	case "CAPTCHA_INVALID", "INVALID_CAPTCHA", "CAPTCHA_ERROR", "VERIFICATION_CODE_INVALID", "VERIFICATION_CODE_ERROR":
		return ErrAcademicChallengeRejected
	case "PASSWORD_INVALID", "INVALID_PASSWORD", "PASSWORD_INCORRECT", "PASSWORD_ERROR":
		return ErrAcademicCredentialRejected
	case "ACCOUNT_NOT_FOUND", "ACCOUNT_UNKNOWN", "USER_NOT_FOUND":
		return ErrAcademicAccountRejected
	case "ACCOUNT_LOCKED", "ACCOUNT_DISABLED", "ACCOUNT_RESTRICTED", "NOT_ENROLLED":
		return ErrAcademicAccountRestricted
	case "RATE_LIMITED", "TOO_MANY_REQUESTS":
		return ErrAcademicRateLimited
	}
	switch message {
	case "验证码错误", "验证码不正确", "图形验证码错误":
		return ErrAcademicChallengeRejected
	case "密码错误", "密码不正确", "密码无效":
		return ErrAcademicCredentialRejected
	case "账号不存在", "用户不存在", "账号未注册":
		return ErrAcademicAccountRejected
	case "账号已冻结", "账号已锁定", "账号未开通":
		return ErrAcademicAccountRestricted
	}
	if statusCode == http.StatusTooManyRequests {
		return ErrAcademicRateLimited
	}
	if statusCode >= 500 || statusCode == 0 {
		return ErrAcademicProviderUnavailable
	}
	return ErrAcademicAuthRejectedAmbiguous
}

// classifyAcademicIdentityFailure 保留 handler 包内测试与旧调用方的简短函数名。
func classifyAcademicIdentityFailure(statusCode int, code, message string) error {
	return ClassifyAcademicIdentityFailure(statusCode, code, message)
}

// AcademicIdentityProvider 是 provider-specific 学校协议的最小服务端边界。
// Provider 可以持有一次请求内的临时状态，但不得把密码或学校 Session 写入本服务数据库。
type AcademicIdentityProvider interface {
	ProviderID() models.AcademicProviderID
	PrepareChallenge(context.Context, uint, string) (AcademicProviderChallenge, error)
	Verify(context.Context, AcademicProviderVerifyRequest) (AcademicVerifiedProfile, error)
}

// AcademicProviderChallenge 是学校协议层返回的临时挑战材料。
// ChallengeState 会被封装在服务端 AEAD token 中，不直接暴露给客户端。
type AcademicProviderChallenge struct {
	Required                   bool
	Type                       string
	Captcha                    string
	SchoolPublicKey            string
	SchoolPublicKeyFingerprint string
	ChallengeState             []byte
}

// AcademicProviderVerifyRequest 是一次性学校验证输入。
// 研究生使用设备生成的 EncryptedPassword；本科 pre_verify 仅在当前请求内接收 Password，绝不落库。
type AcademicProviderVerifyRequest struct {
	UserID     uint
	ProviderID string
	StudentID  string
	// Password 仅供本科非持久化 pre_verify Provider 在当前请求内转发；研究生必须使用密文。
	Password                   string
	Captcha                    string
	EncryptedPassword          string
	SchoolPublicKeyFingerprint string
	ChallengeState             []byte
}

// AcademicVerifiedProfile 必须由学校响应解析得到，不能由客户端请求直接填充。
type AcademicVerifiedProfile struct {
	ProviderID string
	StudentID  string
	Name       string
}

type unavailableAcademicProvider struct {
	id       string
	required bool
}

func (p unavailableAcademicProvider) ProviderID() models.AcademicProviderID {
	return models.AcademicProviderID(p.id)
}

func (p unavailableAcademicProvider) PrepareChallenge(context.Context, uint, string) (AcademicProviderChallenge, error) {
	return AcademicProviderChallenge{Required: p.required}, ErrAcademicProviderUnavailable
}

func (p unavailableAcademicProvider) Verify(context.Context, AcademicProviderVerifyRequest) (AcademicVerifiedProfile, error) {
	return AcademicVerifiedProfile{}, ErrAcademicProviderUnavailable
}

// AcademicIdentityHandler 提供 provider-aware 学生身份挑战和绑定接口。
type AcademicIdentityHandler struct {
	db        *gorm.DB
	aead      cipher.AEAD
	providers map[string]AcademicIdentityProvider
	mu        sync.RWMutex
	now       func() time.Time
}

// NewAcademicIdentityHandler 使用 ACADEMIC_CHALLENGE_KEY 创建挑战处理器。
// 未配置密钥时只使用随机进程密钥，重启后旧 token 全部失效；生产环境必须配置稳定的随机密钥。
func NewAcademicIdentityHandler(db *gorm.DB, rawKey string) (*AcademicIdentityHandler, error) {
	key, err := academicChallengeKey(rawKey)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("创建教务 challenge 密钥失败: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("创建教务 challenge AEAD 失败: %w", err)
	}
	return &AcademicIdentityHandler{
		db:   db,
		aead: aead,
		providers: map[string]AcademicIdentityProvider{
			// 新本科客户端复用非持久化 pre_verify；旧客户端仍可继续使用 /api/edu/bind。
			models.AcademicProviderUndergraduate: undergraduateAcademicIdentityProvider{},
			// 研究生真实协议尚待接入，默认拒绝，不产生伪造的学校 challenge。
			models.AcademicProviderGraduate: unavailableAcademicProvider{id: models.AcademicProviderGraduate, required: true},
		},
		now: time.Now,
	}, nil
}

func academicChallengeKey(raw string) ([]byte, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		key := make([]byte, 32)
		if _, err := rand.Read(key); err != nil {
			return nil, fmt.Errorf("生成临时教务 challenge 密钥失败: %w", err)
		}
		return key, nil
	}
	if decoded, err := hex.DecodeString(raw); err == nil && len(decoded) == 32 {
		return decoded, nil
	}
	if decoded, err := base64.RawURLEncoding.DecodeString(raw); err == nil && len(decoded) == 32 {
		return decoded, nil
	}
	// 兼容部署系统以普通环境变量传入随机密钥；先做固定长度 KDF，避免 AES 接受弱长度。
	digest := sha256.Sum256([]byte(raw))
	return digest[:], nil
}

// SetProvider 仅用于注册真实 provider 或隔离测试 fixture；同一 Provider 不应持有跨用户会话。
func (h *AcademicIdentityHandler) SetProvider(provider AcademicIdentityProvider) error {
	if h == nil || provider == nil {
		return errors.New("academic provider 不能为空")
	}
	id := strings.TrimSpace(string(provider.ProviderID()))
	if id != models.AcademicProviderUndergraduate && id != models.AcademicProviderGraduate {
		return errors.New("不支持的 academic provider")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.providers[id] = provider
	return nil
}

func (h *AcademicIdentityHandler) provider(id string) (AcademicIdentityProvider, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	provider, ok := h.providers[id]
	return provider, ok
}

type academicChallengeClaims struct {
	Operation             string `json:"op,omitempty"`
	CurrentBindingID      uint   `json:"bid,omitempty"`
	CurrentBindingVersion uint   `json:"bv,omitempty"`
	CurrentProviderID     string `json:"cpid,omitempty"`
	CurrentStudentID      string `json:"csid,omitempty"`
	Version               int    `json:"v"`
	UserID                uint   `json:"uid"`
	ProviderID            string `json:"pid"`
	StudentID             string `json:"sid"`
	Nonce                 string `json:"nonce"`
	ExpiresAt             int64  `json:"exp"`
	Fingerprint           string `json:"fp"`
	State                 string `json:"state,omitempty"`
}

func (h *AcademicIdentityHandler) sealChallenge(claims academicChallengeClaims) (string, error) {
	plaintext, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, h.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	ciphertext := h.aead.Seal(nil, nonce, plaintext, []byte("academic-identity-challenge-v1"))
	sealed := append(nonce, ciphertext...)
	return "v1." + base64.RawURLEncoding.EncodeToString(sealed), nil
}

func (h *AcademicIdentityHandler) unsealChallenge(token string) (academicChallengeClaims, error) {
	var claims academicChallengeClaims
	prefix, encoded, ok := strings.Cut(strings.TrimSpace(token), ".")
	if !ok || prefix != "v1" || encoded == "" {
		return claims, errors.New("challenge token 格式无效")
	}
	sealed, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(sealed) <= h.aead.NonceSize() {
		return claims, errors.New("challenge token 编码无效")
	}
	nonce, ciphertext := sealed[:h.aead.NonceSize()], sealed[h.aead.NonceSize():]
	plaintext, err := h.aead.Open(nil, nonce, ciphertext, []byte("academic-identity-challenge-v1"))
	if err != nil {
		return claims, errors.New("challenge token 校验失败")
	}
	if err := json.Unmarshal(plaintext, &claims); err != nil || claims.Version != academicChallengeTokenVersion || claims.UserID == 0 || claims.ProviderID == "" || claims.StudentID == "" || claims.Nonce == "" {
		return claims, errors.New("challenge token 内容无效")
	}
	return claims, nil
}

type createAcademicChallengeInput struct {
	CurrentProviderID string `json:"current_provider_id"`
	CurrentStudentID  string `json:"current_student_id"`
	ProviderID        string `json:"provider_id" binding:"required"`
	StudentID         string `json:"student_id" binding:"required"`
	RedirectURI       string `json:"redirect_uri"`
}

type verifyAcademicIdentityInput struct {
	ProviderID                 string `json:"provider_id"`
	StudentID                  string `json:"student_id"`
	ChallengeToken             string `json:"challenge_token"`
	Password                   string `json:"password"`
	Captcha                    string `json:"captcha"`
	EncryptedPassword          string `json:"encrypted_password"`
	SchoolPublicKeyFingerprint string `json:"school_public_key_fingerprint"`
}

// CreateChallenge 只签发服务端密封的短期挑战，不接收密码或学校 Session。
func (h *AcademicIdentityHandler) CreateChallenge(c *gin.Context) {
	userID := c.GetUint("user_id")
	if userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"code": "authentication_required", "error": "未登录"})
		return
	}
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 32*1024)
	var input createAcademicChallengeInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "ACADEMIC_CHALLENGE_INVALID", "error": "参数错误"})
		return
	}
	providerID := strings.TrimSpace(input.ProviderID)
	studentID, studentErr := models.ValidateAcademicStudentID(input.StudentID)
	if !validAcademicProvider(providerID) || studentErr != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "ACADEMIC_IDENTITY_INVALID", "error": "Provider 或学号无效"})
		return
	}
	if input.RedirectURI != "" && !sameOriginRedirect(input.RedirectURI) {
		c.JSON(http.StatusBadRequest, gin.H{"code": "ACADEMIC_REDIRECT_INVALID", "error": "只允许同源相对跳转"})
		return
	}
	provider, ok := h.provider(providerID)
	if !ok {
		c.JSON(http.StatusBadRequest, gin.H{"code": "ACADEMIC_PROVIDER_UNSUPPORTED", "error": "不支持的教务 Provider"})
		return
	}
	var current models.AcademicIdentityBinding
	changing := c.GetBool("academic_change")
	if changing {
		if err := h.db.Where("user_id = ? AND provider_id = ? AND student_id = ?", userID, input.CurrentProviderID, input.CurrentStudentID).First(&current).Error; err != nil {
			c.JSON(http.StatusConflict, gin.H{"code": "ACADEMIC_BINDING_CHANGED", "error": "原学生身份已变化，请刷新后重试"})
			return
		}
	}
	now := h.now()
	ipHash := h.hashRequestIP(c.ClientIP())
	limited, err := h.challengeRateLimited(userID, ipHash, now)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ACADEMIC_CHALLENGE_STORE_FAILED", "error": "读取教务挑战状态失败"})
		return
	}
	if limited {
		c.Header("Retry-After", "600")
		c.JSON(http.StatusTooManyRequests, gin.H{"code": "ACADEMIC_CHALLENGE_RATE_LIMITED", "error": "教务挑战请求过于频繁，请稍后再试"})
		return
	}

	// 本科 Provider 不需要研究生 challenge；客户端应继续使用旧 /api/edu/bind 完成学校 profile 验证。
	if providerID == models.AcademicProviderUndergraduate && !changing {
		c.JSON(http.StatusOK, gin.H{
			"challenge_required": false,
			"provider_id":        providerID,
			"student_id":         studentID,
			"verification_mode":  "undergraduate_preverify",
			"verify_endpoint":    "/api/student-identity/verify",
			"legacy_endpoint":    "/api/edu/bind",
		})
		return
	}
	// 先落一条仅含 nonce 摘要的尝试记录，再访问学校 Provider。这样 Provider
	// 暂不可用或响应非法时也会计入用户/IP 限流，避免用失败请求冲垮学校入口。
	challengeID := uuid.NewString()
	expiresAt := now.Add(academicChallengeTTL)
	row := models.AcademicIdentityChallenge{
		UserID: userID, ProviderID: providerID, StudentID: studentID,
		NonceHash: hashString(challengeID), Fingerprint: "pending",
		RequestIPHash: ipHash, ExpiresAt: expiresAt, CreatedAt: now,
	}
	if err := h.db.Create(&row).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ACADEMIC_CHALLENGE_STORE_FAILED", "error": "保存教务挑战失败"})
		return
	}
	challenge, err := provider.PrepareChallenge(c.Request.Context(), userID, studentID)
	if err != nil {
		if errors.Is(err, ErrAcademicProviderUnavailable) {
			c.JSON(http.StatusServiceUnavailable, gin.H{"code": "ACADEMIC_PROVIDER_UNAVAILABLE", "error": "研究生教务验证暂不可用"})
			return
		}
		c.JSON(http.StatusBadGateway, gin.H{"code": "ACADEMIC_CHALLENGE_FAILED", "error": "获取教务挑战失败"})
		return
	}
	if providerID == models.AcademicProviderGraduate && (!challenge.Required || strings.TrimSpace(challenge.SchoolPublicKey) == "" || strings.TrimSpace(challenge.SchoolPublicKeyFingerprint) == "" || len(strings.TrimSpace(challenge.SchoolPublicKeyFingerprint)) > 128 || len(challenge.SchoolPublicKey) > 16*1024 || len(challenge.Captcha) > 2*1024*1024 || len(challenge.ChallengeState) > 32*1024) {
		c.JSON(http.StatusBadGateway, gin.H{"code": "ACADEMIC_CHALLENGE_INVALID", "error": "Provider 未返回可验证的公钥指纹"})
		return
	}
	claims := academicChallengeClaims{
		Version:     academicChallengeTokenVersion,
		UserID:      userID,
		ProviderID:  providerID,
		StudentID:   studentID,
		Nonce:       challengeID,
		ExpiresAt:   expiresAt.Unix(),
		Fingerprint: strings.TrimSpace(challenge.SchoolPublicKeyFingerprint),
		State:       base64.RawStdEncoding.EncodeToString(challenge.ChallengeState),
	}
	if changing {
		claims.Operation = "change"
		claims.CurrentBindingID = current.ID
		claims.CurrentBindingVersion = current.BindingVersion
		claims.CurrentProviderID = current.ProviderID
		claims.CurrentStudentID = current.StudentID
	}
	token, err := h.sealChallenge(claims)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ACADEMIC_CHALLENGE_FAILED", "error": "封装教务挑战失败"})
		return
	}
	if err := h.db.Model(&models.AcademicIdentityChallenge{}).Where("id = ? AND consumed_at IS NULL", row.ID).Updates(map[string]interface{}{
		"fingerprint": claims.Fingerprint,
		"expires_at":  expiresAt,
	}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ACADEMIC_CHALLENGE_STORE_FAILED", "error": "保存教务挑战失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"challenge_required":            challenge.Required,
		"operation":                     claims.Operation,
		"verification_mode":             map[bool]string{true: "undergraduate_preverify", false: "school_login"}[providerID == models.AcademicProviderUndergraduate],
		"verify_endpoint":               map[bool]string{true: "/api/student-identity/change", false: "/api/student-identity/verify"}[changing],
		"challenge_type":                valueOrDefault(challenge.Type, "image_captcha"),
		"provider_id":                   providerID,
		"student_id":                    studentID,
		"challenge_token":               token,
		"captcha":                       challenge.Captcha,
		"school_public_key":             challenge.SchoolPublicKey,
		"school_public_key_fingerprint": claims.Fingerprint,
		"expires_at":                    expiresAt.UTC().Format(time.RFC3339),
	})
}

// Verify 消费一次 challenge token，并仅在学校返回匹配 profile 后写入身份绑定。
func (h *AcademicIdentityHandler) Verify(c *gin.Context) {
	userID := c.GetUint("user_id")
	if userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"code": "authentication_required", "error": "未登录"})
		return
	}
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 128*1024)
	var input verifyAcademicIdentityInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "ACADEMIC_VERIFY_INVALID", "error": "参数错误"})
		return
	}
	if len(input.ChallengeToken) > 64*1024 || len(input.EncryptedPassword) > 32*1024 || len(input.Captcha) > 256 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "ACADEMIC_VERIFY_INVALID", "error": "教务验证参数过大"})
		return
	}
	if strings.TrimSpace(input.ProviderID) == models.AcademicProviderUndergraduate && !c.GetBool("academic_change") {
		h.verifyUndergraduate(c, userID, input)
		return
	}
	claims, err := h.unsealChallenge(input.ChallengeToken)
	if err != nil || (claims.Operation == "change") != c.GetBool("academic_change") {
		c.JSON(http.StatusUnauthorized, gin.H{"code": "ACADEMIC_CHALLENGE_INVALID", "error": "教务挑战无效或身份不匹配"})
		return
	}
	consumed, err := h.consumeChallenge(claims, h.now())
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusConflict, gin.H{"code": "ACADEMIC_CHALLENGE_REPLAYED", "error": "教务挑战已使用或已过期"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ACADEMIC_CHALLENGE_STORE_FAILED", "error": "更新教务挑战状态失败"})
		return
	}
	if !consumed {
		c.JSON(http.StatusConflict, gin.H{"code": "ACADEMIC_CHALLENGE_REPLAYED", "error": "教务挑战已使用或已过期"})
		return
	}
	if claims.ExpiresAt <= h.now().Unix() {
		c.JSON(http.StatusUnauthorized, gin.H{"code": "ACADEMIC_CHALLENGE_EXPIRED", "error": "教务挑战已过期，请重新获取"})
		return
	}
	// Challenge 第一次 Verify 尝试即消费；即使请求身份、指纹或验证码错误，也禁止重放同一学校会话。
	if claims.UserID != userID || claims.ProviderID != strings.TrimSpace(input.ProviderID) || claims.StudentID != strings.TrimSpace(input.StudentID) || claims.Fingerprint != strings.TrimSpace(input.SchoolPublicKeyFingerprint) {
		c.JSON(http.StatusUnauthorized, gin.H{"code": "ACADEMIC_CHALLENGE_INVALID", "error": "教务挑战无效或身份不匹配"})
		return
	}
	if claims.ProviderID == models.AcademicProviderGraduate && (strings.TrimSpace(input.EncryptedPassword) == "" || strings.TrimSpace(input.SchoolPublicKeyFingerprint) == "") {
		c.JSON(http.StatusBadRequest, gin.H{"code": "ACADEMIC_VERIFY_INVALID", "error": "参数错误"})
		return
	}
	if strings.Contains(strings.ToLower(input.EncryptedPassword), "password=") {
		// 这是常见的把明文表单误塞进密文字段的错误，直接拒绝以避免误存或转发明文。
		c.JSON(http.StatusBadRequest, gin.H{"code": "ACADEMIC_PLAINTEXT_PASSWORD_REJECTED", "error": "必须使用学校公钥加密教务密码"})
		return
	}
	if claims.ProviderID == models.AcademicProviderUndergraduate && (input.Password == "" || len(input.Password) > 32*1024) {
		c.JSON(http.StatusBadRequest, gin.H{"code": "ACADEMIC_VERIFY_INVALID", "error": "请输入教务密码"})
		return
	}
	provider, ok := h.provider(claims.ProviderID)
	if !ok {
		c.JSON(http.StatusBadRequest, gin.H{"code": "ACADEMIC_PROVIDER_UNSUPPORTED", "error": "不支持的教务 Provider"})
		return
	}
	state, err := base64.RawStdEncoding.DecodeString(claims.State)
	if claims.State != "" && err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"code": "ACADEMIC_CHALLENGE_INVALID", "error": "教务挑战状态无效"})
		return
	}
	profile, err := provider.Verify(c.Request.Context(), AcademicProviderVerifyRequest{
		UserID: userID, ProviderID: claims.ProviderID, StudentID: claims.StudentID,
		Password: input.Password, Captcha: input.Captcha, EncryptedPassword: input.EncryptedPassword,
		SchoolPublicKeyFingerprint: claims.Fingerprint, ChallengeState: state,
	})
	if err != nil {
		writeAcademicVerificationError(c, err)
		return
	}
	if strings.TrimSpace(profile.ProviderID) != claims.ProviderID || strings.TrimSpace(profile.StudentID) != claims.StudentID {
		c.JSON(http.StatusUnauthorized, gin.H{"code": "ACADEMIC_IDENTITY_MISMATCH", "error": "学校返回的学生身份与请求不一致"})
		return
	}
	verifiedAt := h.now()
	persistErr := error(nil)
	if claims.Operation == "change" {
		persistErr = h.changeBinding(claims, verifiedAt)
	} else {
		persistErr = h.persistBinding(userID, claims.ProviderID, claims.StudentID, verifiedAt, academicChallengeMethod, academicChallengeVersion)
	}
	if err := persistErr; err != nil {
		if errors.Is(err, errAcademicBindingChanged) {
			c.JSON(http.StatusConflict, gin.H{"code": "ACADEMIC_BINDING_CHANGED", "error": "原学生身份已变化，请重新验证"})
			return
		}
		if errors.Is(err, errAcademicIdentityAlreadyBound) {
			c.JSON(http.StatusConflict, gin.H{"code": "ACADEMIC_IDENTITY_ALREADY_BOUND", "error": "该学号已绑定其他账号"})
			return
		}
		if errors.Is(err, errAcademicIdentityImmutable) {
			c.JSON(http.StatusConflict, gin.H{"code": "ACADEMIC_IDENTITY_IMMUTABLE", "error": "该 Provider 的学生身份已绑定，不能直接更换"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ACADEMIC_IDENTITY_STORE_FAILED", "error": "保存学生身份失败"})
		return
	}
	h.writeVerifiedBinding(c, userID, claims.ProviderID, claims.StudentID)
}

// verifyUndergraduate 是新客户端使用的本科 verify-only 路径。
// 它只把密码短暂转发给非持久化 pre_verify Provider；成功条件必须包含
// 独立的 school_verified_student_id，旧接口回显的 student_id 会被忽略。
func (h *AcademicIdentityHandler) verifyUndergraduate(c *gin.Context, userID uint, input verifyAcademicIdentityInput) {
	if strings.TrimSpace(input.ChallengeToken) != "" || strings.TrimSpace(input.Captcha) != "" || strings.TrimSpace(input.EncryptedPassword) != "" {
		c.JSON(http.StatusBadRequest, gin.H{"code": "ACADEMIC_VERIFY_INVALID", "error": "本科 verify-only 不接受研究生 challenge 字段"})
		return
	}
	studentID, err := models.ValidateAcademicStudentID(input.StudentID)
	if err != nil || studentID == "" || strings.TrimSpace(input.Password) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"code": "ACADEMIC_VERIFY_INVALID", "error": "参数错误"})
		return
	}
	if strings.Contains(strings.ToLower(input.Password), "password=") || len(input.Password) > 32*1024 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "ACADEMIC_VERIFY_INVALID", "error": "参数错误"})
		return
	}
	now := h.now()
	ipHash := h.hashRequestIP(c.ClientIP())
	limited, err := h.challengeRateLimited(userID, ipHash, now)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ACADEMIC_CHALLENGE_STORE_FAILED", "error": "读取教务挑战状态失败"})
		return
	}
	if limited {
		c.Header("Retry-After", "600")
		c.JSON(http.StatusTooManyRequests, gin.H{"code": "ACADEMIC_CHALLENGE_RATE_LIMITED", "error": "教务验证请求过于频繁，请稍后再试"})
		return
	}
	if err := h.recordAcademicAttempt(userID, models.AcademicProviderUndergraduate, studentID, ipHash, now); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ACADEMIC_CHALLENGE_STORE_FAILED", "error": "保存教务验证状态失败"})
		return
	}
	provider, ok := h.provider(models.AcademicProviderUndergraduate)
	if !ok {
		writeAcademicVerificationError(c, ErrAcademicProviderUnavailable)
		return
	}
	profile, err := provider.Verify(c.Request.Context(), AcademicProviderVerifyRequest{
		UserID: userID, ProviderID: models.AcademicProviderUndergraduate, StudentID: studentID,
		Password: input.Password,
	})
	if err != nil {
		writeAcademicVerificationError(c, err)
		return
	}
	if strings.TrimSpace(profile.ProviderID) != models.AcademicProviderUndergraduate || strings.TrimSpace(profile.StudentID) != studentID {
		c.JSON(http.StatusUnauthorized, gin.H{"code": "ACADEMIC_IDENTITY_MISMATCH", "error": "学校返回的学生身份与请求不一致"})
		return
	}
	verifiedAt := h.now()
	if err := h.persistBinding(userID, models.AcademicProviderUndergraduate, studentID, verifiedAt, academicChallengeMethod, "undergraduate-preverify-v1"); err != nil {
		if errors.Is(err, errAcademicIdentityAlreadyBound) {
			c.JSON(http.StatusConflict, gin.H{"code": "ACADEMIC_IDENTITY_ALREADY_BOUND", "error": "该学号已绑定其他账号"})
			return
		}
		if errors.Is(err, errAcademicIdentityImmutable) {
			c.JSON(http.StatusConflict, gin.H{"code": "ACADEMIC_IDENTITY_IMMUTABLE", "error": "该 Provider 的学生身份已绑定，不能直接更换"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ACADEMIC_IDENTITY_STORE_FAILED", "error": "保存学生身份失败"})
		return
	}
	h.writeVerifiedBinding(c, userID, models.AcademicProviderUndergraduate, studentID)
}

// 返回实际保存的版本和换绑时间，重复验证不能伪造一次新换绑。
func (h *AcademicIdentityHandler) writeVerifiedBinding(c *gin.Context, userID uint, providerID, studentID string) {
	var binding models.AcademicIdentityBinding
	if err := h.db.Where("user_id = ? AND provider_id = ? AND student_id = ?", userID, providerID, studentID).First(&binding).Error; err != nil {
		c.JSON(http.StatusConflict, gin.H{"code": "ACADEMIC_BINDING_CHANGED", "error": "学生身份状态已变化，请刷新后重试"})
		return
	}
	c.JSON(http.StatusOK, academicBindingPayload(binding))
}

func writeAcademicVerificationError(c *gin.Context, err error) {
	var graduateStageErr *graduateProviderStageError
	if errors.As(err, &graduateStageErr) {
		// 只记录固定协议阶段和 HTTP 状态，禁止把学校 URL、响应体、Cookie、密码或验证码写入日志。
		slog.Warn("研究生教务 Provider 不可用", "stage", graduateStageErr.Stage, "status", graduateStageErr.Status)
	}
	switch {
	case errors.Is(err, ErrAcademicProviderUnavailable):
		c.JSON(http.StatusServiceUnavailable, gin.H{"code": "ACADEMIC_PROVIDER_UNAVAILABLE", "error": "教务 Provider 暂不可用"})
	case errors.Is(err, ErrAcademicChallengeRejected):
		c.JSON(http.StatusUnauthorized, gin.H{"code": "ACADEMIC_CHALLENGE_REJECTED", "error": "教务验证码或挑战无效"})
	case errors.Is(err, ErrAcademicCredentialRejected):
		c.JSON(http.StatusUnauthorized, gin.H{"code": "ACADEMIC_CREDENTIAL_REJECTED", "error": "教务密码需要更新"})
	case errors.Is(err, ErrAcademicAccountRejected):
		c.JSON(http.StatusUnauthorized, gin.H{"code": "ACADEMIC_ACCOUNT_REJECTED", "error": "教务账号无法识别"})
	case errors.Is(err, ErrAcademicAccountRestricted):
		c.JSON(http.StatusForbidden, gin.H{"code": "ACADEMIC_ACCOUNT_RESTRICTED", "error": "教务账号当前受限"})
	case errors.Is(err, ErrAcademicAuthRejectedAmbiguous):
		c.JSON(http.StatusUnauthorized, gin.H{"code": "ACADEMIC_AUTH_REJECTED_AMBIGUOUS", "error": "教务认证未通过，无法确定失败原因"})
	case errors.Is(err, ErrAcademicRateLimited):
		c.JSON(http.StatusTooManyRequests, gin.H{"code": "ACADEMIC_RATE_LIMITED", "error": "教务请求过于频繁，请稍后再试"})
	case errors.Is(err, ErrAcademicIdentityRejected):
		c.JSON(http.StatusUnauthorized, gin.H{"code": "ACADEMIC_IDENTITY_REJECTED", "error": "教务身份验证未通过"})
	case errors.Is(err, ErrAcademicIdentityMismatch):
		c.JSON(http.StatusUnauthorized, gin.H{"code": "ACADEMIC_IDENTITY_MISMATCH", "error": "学校返回的学生身份与请求不一致"})
	case errors.Is(err, ErrAcademicIdentityUnverified):
		c.JSON(http.StatusUnprocessableEntity, gin.H{"code": "ACADEMIC_IDENTITY_UNVERIFIED", "error": "学校未返回可独立核验的学生学号"})
	default:
		c.JSON(http.StatusBadGateway, gin.H{"code": "ACADEMIC_VERIFY_FAILED", "error": "教务身份验证失败"})
	}
}

// List 返回当前账号的 provider-aware 身份列表，同时对迁移前本科身份提供兼容投影。
func (h *AcademicIdentityHandler) List(c *gin.Context) {
	userID := c.GetUint("user_id")
	if userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"code": "authentication_required", "error": "未登录"})
		return
	}
	var bindings []models.AcademicIdentityBinding
	if err := h.db.Where("user_id = ?", userID).Order("provider_id ASC, student_id ASC").Find(&bindings).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "ACADEMIC_IDENTITY_READ_FAILED", "error": "读取学生身份失败"})
		return
	}
	response := make([]gin.H, 0, len(bindings)+1)
	for _, binding := range bindings {
		response = append(response, academicBindingPayload(binding))
	}
	// 迁移前旧本科身份可能尚未回填 binding 表；即使用户已有研究生 binding，
	// 也要把这条独立的旧本科身份投影出来，避免 GET 结果丢失旧客户端的可信身份。
	var user models.User
	if err := h.db.Select("id", "student_id", "student_verified_at", "academic_provider_id").First(&user, userID).Error; err == nil && user.StudentVerifiedAt != nil && strings.TrimSpace(user.StudentID) != "" {
		providerID := strings.TrimSpace(string(user.AcademicProviderID))
		if providerID == "" {
			providerID = models.AcademicProviderUndergraduate
		}
		legacyPresent := false
		for _, binding := range bindings {
			if binding.ProviderID == providerID && binding.StudentID == user.StudentID {
				legacyPresent = true
				break
			}
		}
		if !legacyPresent {
			response = append(response, gin.H{
				"provider_id": userAcademicProvider(providerID), "student_id": user.StudentID,
				"verified": true, "verified_at": user.StudentVerifiedAt.UTC().Format(time.RFC3339),
				"verification_method": "legacy_undergraduate", "verification_version": "legacy",
			})
		}
	}
	c.JSON(http.StatusOK, gin.H{"identities": response})
}

func academicBindingPayload(binding models.AcademicIdentityBinding) gin.H {
	return gin.H{
		"provider_id":          binding.ProviderID,
		"student_id":           binding.StudentID,
		"verified":             true,
		"verified_at":          binding.VerifiedAt.UTC().Format(time.RFC3339),
		"verification_method":  binding.VerificationMethod,
		"verification_version": binding.VerificationVersion,
		"binding_version":      binding.BindingVersion,
		"changed_at":           binding.ChangedAt,
	}
}

func userAcademicProvider(id string) string {
	if id == "" {
		return models.AcademicProviderUndergraduate
	}
	return id
}

func validAcademicProvider(id string) bool {
	return id == models.AcademicProviderUndergraduate || id == models.AcademicProviderGraduate
}

func sameOriginRedirect(raw string) bool {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.IsAbs() || parsed.Host != "" || parsed.User != nil || strings.HasPrefix(parsed.Path, "//") || !strings.HasPrefix(parsed.Path, "/") {
		return false
	}
	return true
}

func valueOrDefault(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func hashString(value string) string {
	digest := sha256.Sum256([]byte(value))
	return hex.EncodeToString(digest[:])
}

func (h *AcademicIdentityHandler) hashRequestIP(ip string) string {
	return hashString(strings.TrimSpace(ip))
}

func (h *AcademicIdentityHandler) challengeRateLimited(userID uint, ipHash string, now time.Time) (bool, error) {
	cutoff := now.Add(-academicChallengeRateWindow)
	var userCount, ipCount int64
	if err := h.db.Model(&models.AcademicIdentityChallenge{}).Where("user_id = ? AND created_at >= ?", userID, cutoff).Count(&userCount).Error; err != nil {
		return false, err
	}
	if userCount >= academicChallengeUserLimit {
		return true, nil
	}
	if err := h.db.Model(&models.AcademicIdentityChallenge{}).Where("request_ip_hash = ? AND created_at >= ?", ipHash, cutoff).Count(&ipCount).Error; err != nil {
		return false, err
	}
	return ipCount >= academicChallengeIPLimit, nil
}

func (h *AcademicIdentityHandler) recordAcademicAttempt(userID uint, providerID, studentID, ipHash string, now time.Time) error {
	consumedAt := now
	return h.db.Create(&models.AcademicIdentityChallenge{
		UserID: userID, ProviderID: providerID, StudentID: studentID,
		NonceHash: hashString(uuid.NewString()), Fingerprint: "verify-only",
		RequestIPHash: ipHash, ExpiresAt: now.Add(academicChallengeTTL), ConsumedAt: &consumedAt, CreatedAt: now,
	}).Error
}

func (h *AcademicIdentityHandler) consumeChallenge(claims academicChallengeClaims, now time.Time) (bool, error) {
	consumedAt := now
	result := h.db.Model(&models.AcademicIdentityChallenge{}).
		Where("nonce_hash = ? AND consumed_at IS NULL", hashString(claims.Nonce)).
		Updates(map[string]interface{}{"consumed_at": consumedAt})
	if result.Error != nil {
		return false, result.Error
	}
	return result.RowsAffected == 1, nil
}

var (
	errAcademicIdentityAlreadyBound = errors.New("academic identity already bound")
	errAcademicIdentityImmutable    = errors.New("academic identity immutable")
)

func (h *AcademicIdentityHandler) persistBinding(userID uint, providerID, studentID string, verifiedAt time.Time, method, version string) error {
	return persistAcademicIdentityBinding(h.db, userID, providerID, studentID, verifiedAt, method, version)
}

// persistAcademicIdentityBinding 在既有教务绑定事务内复用，避免旧本科接口只更新 User 而遗漏新身份表。
// 旧版测试库或尚未执行迁移时保留旧 API 行为；正式启动入口会通过 AutoMigrate 创建该表。
func persistAcademicIdentityBinding(db *gorm.DB, userID uint, providerID, studentID string, verifiedAt time.Time, method, version string) error {
	if db == nil || !db.Migrator().HasTable(&models.AcademicIdentityBinding{}) {
		return nil
	}
	return db.Transaction(func(tx *gorm.DB) error {
		var conflict models.AcademicIdentityBinding
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("provider_id = ? AND student_id = ?", providerID, studentID).First(&conflict).Error
		if err == nil && conflict.UserID != userID {
			return errAcademicIdentityAlreadyBound
		}
		if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		var current models.AcademicIdentityBinding
		err = tx.Where("user_id = ? AND provider_id = ?", userID, providerID).First(&current).Error
		if err == nil {
			if current.StudentID != studentID {
				return errAcademicIdentityImmutable
			}
			return tx.Model(&current).Updates(map[string]interface{}{
				"verified_at": verifiedAt, "verification_method": method, "verification_version": version,
			}).Error
		}
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		binding := models.AcademicIdentityBinding{
			UserID: userID, ProviderID: providerID, StudentID: studentID,
			VerifiedAt: verifiedAt, VerificationMethod: method, VerificationVersion: version,
		}
		if err := tx.Create(&binding).Error; err != nil {
			if utils.IsPostgresUniqueViolation(err) || strings.Contains(strings.ToLower(err.Error()), "unique") {
				return errAcademicIdentityAlreadyBound
			}
			return err
		}
		// 旧用户字段只承担本科兼容职责，研究生身份不写入旧 student_id，避免误走本科路由。
		if providerID == models.AcademicProviderUndergraduate {
			if err := tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
				"academic_provider_id":         providerID,
				"student_verification_method":  method,
				"student_verification_version": version,
			}).Error; err != nil {
				return err
			}
		}
		return nil
	})
}

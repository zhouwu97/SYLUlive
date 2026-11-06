package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
)

// 学校会话仅用于本次固定学校入口探活，不落库、不写日志、不接受客户端身份结论。
type academicSessionProof struct {
	Cookies       []string `json:"cookies"`
	SessionPrefix string   `json:"session_path_prefix,omitempty"`
}

type academicSessionVerifier interface {
	VerifySchoolSession(context.Context, string, academicSessionProof) (AcademicVerifiedProfile, error)
}

func sessionProofCookies(proof academicSessionProof, provider string) ([]*http.Cookie, error) {
	if len(proof.Cookies) == 0 || len(proof.Cookies) > 24 ||
		(provider == models.AcademicProviderUndergraduate && proof.SessionPrefix != "") ||
		(proof.SessionPrefix != "" && !graduateValidatedSessionPrefix.MatchString(proof.SessionPrefix)) {
		return nil, ErrAcademicChallengeRejected
	}
	result := make([]*http.Cookie, 0, len(proof.Cookies))
	seen := make(map[string]bool)
	for _, raw := range proof.Cookies {
		if len(raw) > 4096 || strings.ContainsAny(raw, "\r\n\x00") {
			return nil, ErrAcademicChallengeRejected
		}
		cookie, err := http.ParseSetCookie(raw)
		if err != nil || cookie.Valid() != nil || cookie.Name == "" || cookie.Value == "" || seen[cookie.Name] {
			return nil, ErrAcademicChallengeRejected
		}
		seen[cookie.Name] = true
		// 只取名字和值，客户端 Domain/Path/Expires 均不能改变服务端请求目的地。
		result = append(result, &http.Cookie{Name: cookie.Name, Value: cookie.Value, Path: "/"})
	}
	return result, nil
}

func (h *AcademicIdentityHandler) VerifySession(c *gin.Context) {
	if !configUserMatches(c) {
		return
	}
	userID := c.GetUint("user_id")
	if userID == 0 {
		c.JSON(401, gin.H{"code": "authentication_required"})
		return
	}
	var input struct {
		ProviderID string               `json:"provider_id"`
		StudentID  string               `json:"student_id"`
		Proof      academicSessionProof `json:"school_session"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 24*1024))
	decoder.DisallowUnknownFields()
	var extra any
	if decoder.Decode(&input) != nil || decoder.Decode(&extra) != io.EOF || !validAcademicProvider(input.ProviderID) {
		c.JSON(400, gin.H{"code": "ACADEMIC_SESSION_INVALID"})
		return
	}
	if _, err := models.ValidateAcademicStudentID(input.StudentID); err != nil {
		c.JSON(400, gin.H{"code": "ACADEMIC_SESSION_INVALID"})
		return
	}
	if _, err := sessionProofCookies(input.Proof, input.ProviderID); err != nil {
		c.JSON(400, gin.H{"code": "ACADEMIC_SESSION_INVALID"})
		return
	}
	provider, ok := h.provider(input.ProviderID)
	verifier, supported := provider.(academicSessionVerifier)
	if !ok || !supported {
		writeAcademicVerificationError(c, ErrAcademicProviderUnavailable)
		return
	}
	var config models.AcademicAccountConfig
	ipHash := h.hashRequestIP(c.ClientIP())
	var attempt models.AcademicIdentityChallenge
	err := h.db.Transaction(func(tx *gorm.DB) error {
		// 同 IP 和同账号的检查、占额原子提交；网络请求在事务外执行。
		if tx.Dialector.Name() == "postgres" {
			if err := tx.Exec("SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", "academic-session-ip:"+ipHash).Error; err != nil {
				return err
			}
		}
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			return err
		}
		if user.AccountStatus != "" && user.AccountStatus != "active" {
			return errAcademicBindingChanged
		}
		consent, err := models.LegalConsentStateForUser(tx, user)
		if err != nil {
			return err
		}
		if consent != models.LegalConsentStateActive {
			return errAcademicBindingChanged
		}
		if err := tx.Where("user_id = ? AND provider_id = ? AND student_id = ? AND state = ?", userID, input.ProviderID, input.StudentID, "active").First(&config).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return errAcademicBindingChanged
			}
			return err
		}
		now := h.now()
		limited, err := academicChallengeRateLimited(tx, userID, ipHash, now)
		if err != nil {
			return err
		}
		if limited {
			return ErrAcademicRateLimited
		}
		attempt = models.AcademicIdentityChallenge{UserID: userID, ProviderID: input.ProviderID, StudentID: input.StudentID,
			NonceHash: hashString(uuid.NewString()), Fingerprint: "session-profile-v1", RequestIPHash: ipHash,
			ExpiresAt: now.Add(academicChallengeTTL), CreatedAt: now}
		return tx.Create(&attempt).Error
	})
	if err != nil {
		if errors.Is(err, errAcademicBindingChanged) {
			c.JSON(409, gin.H{"code": "ACADEMIC_BINDING_CHANGED"})
		} else {
			if errors.Is(err, ErrAcademicRateLimited) {
				c.Header("Retry-After", "600")
			}
			writeAcademicVerificationError(c, err)
		}
		return
	}
	// Cookie 是凭证，不是证据正文；只有服务端向学校重新读取到的学号才是绑定依据。
	profile, err := verifier.VerifySchoolSession(c.Request.Context(), input.StudentID, input.Proof)
	if err != nil {
		writeAcademicVerificationError(c, err)
		return
	}
	if profile.ProviderID != input.ProviderID || profile.StudentID != input.StudentID {
		writeAcademicVerificationError(c, ErrAcademicIdentityMismatch)
		return
	}
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			return err
		}
		if user.AccountStatus != "" && user.AccountStatus != "active" {
			return errAcademicBindingChanged
		}
		consent, err := models.LegalConsentStateForUser(tx, user)
		if err != nil {
			return err
		}
		if consent != models.LegalConsentStateActive {
			return errAcademicBindingChanged
		}
		var current models.AcademicAccountConfig
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&current, config.ID).Error; err != nil {
			return err
		}
		if current.Revision != config.Revision || current.State != "active" || current.StudentID != input.StudentID {
			return errAcademicBindingChanged
		}
		consumed := h.now()
		result := tx.Model(&models.AcademicIdentityChallenge{}).Where("id = ? AND consumed_at IS NULL AND expires_at > ?", attempt.ID, consumed).Update("consumed_at", consumed)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return errAcademicBindingChanged
		}
		return persistAcademicIdentityBinding(tx, userID, input.ProviderID, input.StudentID, consumed, models.AcademicVerificationMethodSchoolProfile, "session-profile-v1")
	})
	if err != nil {
		switch {
		case errors.Is(err, errAcademicIdentityAlreadyBound):
			c.JSON(409, gin.H{"code": "ACADEMIC_IDENTITY_ALREADY_BOUND"})
		case errors.Is(err, errAcademicIdentityImmutable):
			c.JSON(409, gin.H{"code": "ACADEMIC_IDENTITY_IMMUTABLE"})
		case errors.Is(err, errAcademicBindingChanged):
			c.JSON(409, gin.H{"code": "ACADEMIC_BINDING_CHANGED"})
		default:
			c.JSON(503, gin.H{"code": "ACADEMIC_IDENTITY_STORE_FAILED"})
		}
		return
	}
	h.writeVerifiedBinding(c, userID, input.ProviderID, input.StudentID)
}

func (undergraduateAcademicIdentityProvider) VerifySchoolSession(ctx context.Context, studentID string, proof academicSessionProof) (AcademicVerifiedProfile, error) {
	cookies, err := sessionProofCookies(proof, models.AcademicProviderUndergraduate)
	if err != nil {
		return AcademicVerifiedProfile{}, err
	}
	parts := make([]string, 0, len(cookies))
	for _, cookie := range cookies {
		parts = append(parts, cookie.Name+"="+cookie.Value)
	}
	response, err := pythonEduRequestWithContext(ctx, http.MethodPost, "/api/edu/verify_session", nil, map[string]string{"cookie": strings.Join(parts, "; ")})
	if err != nil {
		return AcademicVerifiedProfile{}, ErrAcademicProviderUnavailable
	}
	var result undergraduatePreVerifyResponse
	if json.Unmarshal(response.Body(), &result) != nil {
		return AcademicVerifiedProfile{}, ErrAcademicProviderUnavailable
	}
	if response.StatusCode() != 200 || !result.Success {
		return AcademicVerifiedProfile{}, classifyAcademicIdentityFailure(response.StatusCode(), result.Code, result.Message)
	}
	actual := strings.TrimSpace(result.SchoolVerifiedStudentID)
	if actual == "" {
		return AcademicVerifiedProfile{}, ErrAcademicIdentityUnverified
	}
	if actual != studentID {
		return AcademicVerifiedProfile{}, ErrAcademicIdentityMismatch
	}
	return AcademicVerifiedProfile{ProviderID: models.AcademicProviderUndergraduate, StudentID: actual}, nil
}

func (p *GraduateAcademicIdentityProvider) VerifySchoolSession(ctx context.Context, studentID string, proof academicSessionProof) (AcademicVerifiedProfile, error) {
	cookies, err := sessionProofCookies(proof, models.AcademicProviderGraduate)
	if err != nil {
		return AcademicVerifiedProfile{}, err
	}
	jar, err := newGraduateCookieJar()
	if err != nil {
		return AcademicVerifiedProfile{}, ErrAcademicProviderUnavailable
	}
	jar.SetCookies(p.baseURL, cookies)
	client := p.newClient(jar)
	client.CheckRedirect = func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }
	profile, err := p.fetchGraduateProfile(ctx, client, p.endpointWithPrefix(proof.SessionPrefix, "/student/default/getxscardinfo"), p.endpoint("/"))
	if err != nil {
		return AcademicVerifiedProfile{}, err
	}
	if profile.StudentID != studentID {
		return AcademicVerifiedProfile{}, ErrAcademicIdentityMismatch
	}
	return profile, nil
}

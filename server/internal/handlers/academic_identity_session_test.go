package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

type sessionFixtureProvider struct {
	academicIdentityFixtureProvider
	before  func()
	result  AcademicVerifiedProfile
	calls   int
	failure error
}

func (p *sessionFixtureProvider) VerifySchoolSession(_ context.Context, _ string, _ academicSessionProof) (AcademicVerifiedProfile, error) {
	p.calls++
	if p.before != nil {
		p.before()
	}
	return p.result, p.failure
}

func sessionFixture(t *testing.T) (*AcademicIdentityHandler, *gorm.DB, *sessionFixtureProvider, models.User, func(string, string) *httptest.ResponseRecorder) {
	h, db, _, user := newAcademicIdentityTestHandler(t)
	require.NoError(t, db.AutoMigrate(&models.AcademicAccountConfig{}, &models.UserLegalConsent{}))
	for _, doc := range []string{models.LegalDocumentUserAgreement, models.LegalDocumentPrivacyPolicy} {
		require.NoError(t, db.Create(&models.UserLegalConsent{UserID: user.ID, Document: doc, Version: models.LegalDocumentVersion, AcceptedAt: time.Now()}).Error)
	}
	require.NoError(t, db.Create(&models.AcademicAccountConfig{UserID: user.ID, ProviderID: models.AcademicProviderGraduate, StudentID: "G20260001", State: "active", Revision: 1}).Error)
	p := &sessionFixtureProvider{result: AcademicVerifiedProfile{ProviderID: models.AcademicProviderGraduate, StudentID: "G20260001"}}
	require.NoError(t, h.SetProvider(p))
	r := gin.New()
	r.POST("/verify-session", func(c *gin.Context) { c.Set("user_id", user.ID) }, h.VerifySession)
	request := func(body, expected string) *httptest.ResponseRecorder {
		req := httptest.NewRequest("POST", "/verify-session", bytes.NewBufferString(body))
		req.Header.Set("Content-Type", "application/json")
		if expected != "" {
			req.Header.Set("X-Expected-App-User", expected)
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		return w
	}
	return h, db, p, user, request
}

const sessionBody = `{"provider_id":"sylu_graduate","student_id":"G20260001","school_session":{"cookies":["SID=transient-secret; Path=/"],"session_path_prefix":"/(S(abc))"}}`

func TestUndergraduateSessionProofDoesNotSendCancelledCredentials(t *testing.T) {
	var calls atomic.Int32
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"success":true,"school_verified_student_id":"20260001"}`))
	}))
	defer remote.Close()
	previous := EduServiceConfig
	t.Cleanup(func() { EduServiceConfig = previous })
	EduServiceConfig.BaseURL = remote.URL
	EduServiceConfig.Token = "synthetic-internal-token"
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := (undergraduateAcademicIdentityProvider{}).VerifySchoolSession(ctx, "20260001", academicSessionProof{Cookies: []string{"SID=transient-secret"}})
	require.Error(t, err)
	require.Zero(t, calls.Load(), "已取消的学校会话核验不能再向远端发送凭据")
}

func TestUndergraduateSessionProofCancelsInFlightRequest(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer remote.Close()
	defer close(release)
	previous := EduServiceConfig
	t.Cleanup(func() { EduServiceConfig = previous })
	EduServiceConfig.BaseURL = remote.URL
	EduServiceConfig.Token = "synthetic-internal-token"
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	go func() {
		_, err := (undergraduateAcademicIdentityProvider{}).VerifySchoolSession(ctx, "20260001", academicSessionProof{Cookies: []string{"SID=transient-secret"}})
		result <- err
	}()
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("核验请求未到达隔离服务")
	}
	cancel()
	select {
	case err := <-result:
		require.Error(t, err)
	case <-time.After(3 * time.Second):
		t.Fatal("取消后核验仍在等待远端响应")
	}
}

func TestSessionBindingOnlyAcceptsFreshSchoolIdentity(t *testing.T) {
	_, db, p, user, request := sessionFixture(t)
	w := request(sessionBody, "")
	require.Equal(t, 200, w.Code, w.Body.String())
	require.NotContains(t, w.Body.String(), "transient-secret")
	var binding models.AcademicIdentityBinding
	require.NoError(t, db.First(&binding).Error)
	require.Equal(t, models.AcademicVerificationMethodSchoolProfile, binding.VerificationMethod)
	require.Equal(t, "session-profile-v1", binding.VerificationVersion)
	require.Equal(t, user.ID, binding.UserID)
	// 响应丢失后重试只能更新同一条绑定，不能重复创建或更换所有者。
	w = request(sessionBody, "")
	require.Equal(t, 200, w.Code, w.Body.String())
	var count int64
	require.NoError(t, db.Model(&models.AcademicIdentityBinding{}).Count(&count).Error)
	require.EqualValues(t, 1, count)
	require.Equal(t, 2, p.calls)
}

func TestSessionBindingRejectsForgedBodiesAndWrongAppUser(t *testing.T) {
	for _, body := range []string{
		`{"provider_id":"sylu_graduate","student_id":"G20260001","verified":true,"school_session":{"cookies":["SID=fake"]}}`,
		`{"provider_id":"sylu_graduate","student_id":"G20260001","school_session":{"cookies":["SID=fake"],"url":"http://127.0.0.1/"}}`,
		`{"provider_id":"sylu_graduate","student_id":"G20260001","school_session":{"cookies":["SID=fake\r\nX:bad"]}}`,
		`{"provider_id":"sylu_graduate","student_id":"G20260001","school_session":{"cookies":["SID=fake"],"session_path_prefix":"//evil/"}}`,
	} {
		t.Run(body, func(t *testing.T) {
			_, db, p, _, request := sessionFixture(t)
			w := request(body, "")
			require.Equal(t, 400, w.Code)
			require.Zero(t, p.calls)
			var count int64
			require.NoError(t, db.Model(&models.AcademicIdentityBinding{}).Count(&count).Error)
			require.Zero(t, count)
		})
	}
	_, _, p, _, request := sessionFixture(t)
	require.Equal(t, 409, request(sessionBody, "999").Code)
	require.Zero(t, p.calls)
}

func TestSessionBindingRejectsWrongSchoolIdentityAndExpiredCookie(t *testing.T) {
	for _, failure := range []error{nil, ErrAcademicIdentityUnverified, ErrAcademicProviderUnavailable} {
		_, db, p, _, request := sessionFixture(t)
		p.result.StudentID = "OTHER"
		p.failure = failure
		w := request(sessionBody, "")
		require.NotEqual(t, 200, w.Code)
		var count int64
		require.NoError(t, db.Model(&models.AcademicIdentityBinding{}).Count(&count).Error)
		require.Zero(t, count)
	}
}

func TestSessionBindingCannotResurrectAfterRevocationOrConfigChange(t *testing.T) {
	for _, action := range []string{"config_delete", "config_change", "unbind_attempt", "account_restricted", "consent_revoked"} {
		t.Run(action, func(t *testing.T) {
			_, db, p, user, request := sessionFixture(t)
			p.before = func() {
				switch action {
				case "config_delete":
					require.NoError(t, db.Model(&models.AcademicAccountConfig{}).Where("user_id = ?", user.ID).Updates(map[string]any{"state": "deleted", "revision": 2}).Error)
				case "config_change":
					require.NoError(t, db.Model(&models.AcademicAccountConfig{}).Where("user_id = ?", user.ID).Update("revision", 2).Error)
				case "unbind_attempt":
					require.NoError(t, db.Model(&models.AcademicIdentityChallenge{}).Where("user_id = ?", user.ID).Update("consumed_at", time.Now()).Error)
				case "account_restricted":
					require.NoError(t, db.Model(&models.User{}).Where("id = ?", user.ID).Update("account_status", "cancelled").Error)
				case "consent_revoked":
					require.NoError(t, db.Model(&models.User{}).Where("id = ?", user.ID).Update("legal_consent_revoked_at", time.Now()).Error)
				}
			}
			w := request(sessionBody, "")
			require.Equal(t, 409, w.Code, w.Body.String())
			var count int64
			require.NoError(t, db.Model(&models.AcademicIdentityBinding{}).Count(&count).Error)
			require.Zero(t, count)
		})
	}
}

func TestSessionBindingDoesNotStealAnotherUsersTrustedIdentity(t *testing.T) {
	h, db, _, _, request := sessionFixture(t)
	other := models.User{PasswordHash: "fixture"}
	require.NoError(t, db.Create(&other).Error)
	require.NoError(t, h.persistBinding(other.ID, models.AcademicProviderGraduate, "G20260001", time.Now(), models.AcademicVerificationMethodSchoolProfile, "v1"))
	w := request(sessionBody, "")
	require.Equal(t, http.StatusConflict, w.Code)
	var payload map[string]any
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &payload))
	require.Equal(t, "ACADEMIC_IDENTITY_ALREADY_BOUND", payload["code"])
}

func TestSessionBindingRateLimitReservesAttemptsBeforeSchoolRequest(t *testing.T) {
	_, db, p, _, request := sessionFixture(t)
	p.failure = ErrAcademicProviderUnavailable
	for i := 0; i < academicChallengeUserLimit; i++ {
		require.Equal(t, http.StatusServiceUnavailable, request(sessionBody, "").Code)
	}
	w := request(sessionBody, "")
	require.Equal(t, http.StatusTooManyRequests, w.Code)
	require.Equal(t, "600", w.Header().Get("Retry-After"))
	require.Equal(t, academicChallengeUserLimit, p.calls)
	var count int64
	require.NoError(t, db.Model(&models.AcademicIdentityChallenge{}).Count(&count).Error)
	require.EqualValues(t, academicChallengeUserLimit, count)
}

func TestSessionBindingRequiresActiveConfigAndLiveAttempt(t *testing.T) {
	for _, action := range []string{"missing_config", "expired_attempt"} {
		t.Run(action, func(t *testing.T) {
			h, db, p, user, request := sessionFixture(t)
			if action == "missing_config" {
				require.NoError(t, db.Where("user_id = ?", user.ID).Delete(&models.AcademicAccountConfig{}).Error)
			} else {
				p.before = func() { h.now = func() time.Time { return time.Now().Add(academicChallengeTTL + time.Second) } }
			}
			require.Equal(t, http.StatusConflict, request(sessionBody, "").Code)
			if action == "missing_config" {
				require.Zero(t, p.calls)
			}
			var count int64
			require.NoError(t, db.Model(&models.AcademicIdentityBinding{}).Count(&count).Error)
			require.Zero(t, count)
		})
	}
}

func TestSessionBindingUnbindAtomicallyPreventsLateAndSubsequentProof(t *testing.T) {
	h, db, p, user, request := sessionFixture(t)
	p.before = func() {
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Set("user_id", user.ID)
		c.Request = httptest.NewRequest(http.MethodDelete, "/student-identity", bytes.NewBufferString(`{"provider_id":"sylu_graduate","student_id":"G20260001"}`))
		c.Request.Header.Set("Content-Type", "application/json")
		h.Unbind(c)
		require.Equal(t, 200, w.Code, w.Body.String())
	}
	require.Equal(t, 409, request(sessionBody, "").Code)
	require.Equal(t, 409, request(sessionBody, "").Code)
	require.Equal(t, 1, p.calls, "解绑后的新请求也不能利用旧学校会话恢复绑定")
	var config models.AcademicAccountConfig
	require.NoError(t, db.Where("user_id = ?", user.ID).First(&config).Error)
	require.Equal(t, "deleted", config.State)
	require.Empty(t, config.StudentID)
	require.EqualValues(t, 2, config.Revision)
}

func TestGraduateSessionProofOnlyReadsFixedSchoolProfileAndDoesNotFollowRedirects(t *testing.T) {
	for _, redirect := range []bool{false, true} {
		t.Run(map[bool]string{false: "profile", true: "redirect"}[redirect], func(t *testing.T) {
			var leaked bool
			foreign := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { leaked = true }))
			defer foreign.Close()
			school := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				require.Equal(t, "/(S(abc))/student/default/getxscardinfo", r.URL.Path)
				require.Empty(t, r.URL.Query().Get("student_id"))
				require.Empty(t, r.URL.Query().Get("su"))
				require.Contains(t, r.Header.Get("Cookie"), "SID=fixture")
				if redirect {
					http.Redirect(w, r, foreign.URL, http.StatusFound)
					return
				}
				_, _ = w.Write([]byte(`[{"xh":"G20260001","xm":"fixture"}]`))
			}))
			defer school.Close()
			base, err := url.Parse(school.URL)
			require.NoError(t, err)
			provider := &GraduateAcademicIdentityProvider{baseURL: base, transport: school.Client().Transport}
			profile, err := provider.VerifySchoolSession(context.Background(), "G20260001", academicSessionProof{Cookies: []string{"SID=fixture; Domain=evil.invalid; Path=/elsewhere"}, SessionPrefix: "/(S(abc))"})
			if redirect {
				require.Error(t, err)
			} else {
				require.NoError(t, err)
				require.Equal(t, "G20260001", profile.StudentID)
			}
			require.False(t, leaked)
		})
	}
}

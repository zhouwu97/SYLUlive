package handlers

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func integrationAuthFlowFixture(t *testing.T) (reauthenticationFixture, *IntegrationHandler) {
	t.Helper()
	f := newReauthenticationFixture(t, nil)
	require.NoError(t, f.db.AutoMigrate(&models.AcademicIdentityBinding{}, &models.IntegrationDeviceRequest{}, &models.IntegrationBinding{}, &models.IntegrationCredential{}, &models.IntegrationAudit{}, &models.IntegrationRateBucket{}, &models.IntegrationAction{}, &models.ManagedBot{}, &models.Post{}, &models.Reply{}, &models.WaterSection{}, &models.WaterSectionMute{}))
	require.NoError(t, f.db.Create(&models.AcademicIdentityBinding{UserID: f.user.ID, ProviderID: models.AcademicProviderUndergraduate, StudentID: "synthetic-flow", BindingVersion: 1, VerifiedAt: time.Now(), VerificationMethod: models.AcademicVerificationMethodSchoolProfile, VerificationVersion: "v1"}).Error)
	h := NewIntegrationHandler(f.db, IntegrationOptions{ProposalsEnabled: true, OwnerPublishEnabled: true})
	h.Register(f.r, f.h.jwtSecret)
	return f, h
}

func integrationFlowRequest(t *testing.T, f reauthenticationFixture, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+f.token)
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	f.r.ServeHTTP(w, r)
	return w
}

func flowConsent(t *testing.T, f reauthenticationFixture, h *IntegrationHandler) services.IntegrationConsent {
	t.Helper()
	device, err := h.auth.RequestDevice(context.Background(), uuid.NewString(), "synthetic-flow", "profile:read_minimal community:read actions:read_own community:propose")
	require.NoError(t, err)
	w := integrationFlowRequest(t, f, "POST", "/api/connected-apps/device-requests/lookup", `{"user_code":"`+device.UserCode+`"}`)
	require.Equal(t, 200, w.Code, w.Body.String())
	var consent services.IntegrationConsent
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &consent))
	return consent
}

func TestIntegrationOldSessionCanReviewAndRejectWithoutPassword(t *testing.T) {
	f, h := integrationAuthFlowFixture(t)
	consent := flowConsent(t, f, h)
	decision, _ := json.Marshal(services.IntegrationConsentDecision{Allow: false, Nonce: consent.Nonce})
	w := integrationFlowRequest(t, f, "POST", "/api/connected-apps/device-requests/"+consent.ID+"/decision", string(decision))
	require.Equal(t, 200, w.Code, w.Body.String())
	var active int64
	require.NoError(t, f.db.Model(&models.IntegrationBinding{}).Where("state = ?", "active").Count(&active).Error)
	require.Zero(t, active, "拒绝不能创建有效授权")
}

func TestIntegrationApprovalReusesThirtyMinuteProofAndStillExpires(t *testing.T) {
	for _, age := range []time.Duration{15 * time.Minute, 29*time.Minute + 59*time.Second, 30*time.Minute + time.Second, time.Hour, -2 * time.Minute} {
		t.Run(age.String(), func(t *testing.T) {
			f, h := integrationAuthFlowFixture(t)
			now := time.Now().Truncate(time.Millisecond)
			h.auth.Now = func() time.Time { return now }
			require.NoError(t, f.db.Model(&models.RefreshToken{}).Where("token_family = ?", f.family).Update("authenticated_at", now.Add(-age)).Error)
			consent := flowConsent(t, f, h)
			decision, _ := json.Marshal(services.IntegrationConsentDecision{Allow: true, Nonce: consent.Nonce, Scopes: consent.RequestedScopes})
			w := integrationFlowRequest(t, f, "POST", "/api/connected-apps/device-requests/"+consent.ID+"/decision", string(decision))
			if age >= 0 && age <= 30*time.Minute {
				require.Equal(t, 200, w.Code, w.Body.String())
			} else {
				require.Equal(t, 403, w.Code, w.Body.String())
				require.Contains(t, w.Body.String(), "recent_authentication_required")
			}
		})
	}
}

func TestIntegrationOnePasswordVerificationCoversFollowingApproval(t *testing.T) {
	f, h := integrationAuthFlowFixture(t)
	consent := flowConsent(t, f, h)
	body, _ := json.Marshal(services.IntegrationConsentDecision{Allow: true, Nonce: consent.Nonce, Scopes: consent.RequestedScopes})
	path := "/api/connected-apps/device-requests/" + consent.ID + "/decision"
	w := integrationFlowRequest(t, f, "POST", path, string(body))
	require.Equal(t, 403, w.Code, w.Body.String())
	w = f.send(t, f.token, f.body("synthetic-password"))
	require.Equal(t, 200, w.Code, w.Body.String())
	var verified struct {
		ValidUntil time.Time `json:"valid_until"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &verified))
	require.WithinDuration(t, time.Now().Add(30*time.Minute), verified.ValidUntil, time.Second)
	h.auth.Now = func() time.Time { return time.Now().Add(25 * time.Minute) }
	// 新请求在当前测试时间创建；验证证明属于当前会话，并可跨步骤复用。
	consent = flowConsent(t, f, h)
	body, _ = json.Marshal(services.IntegrationConsentDecision{Allow: true, Nonce: consent.Nonce, Scopes: consent.RequestedScopes})
	w = integrationFlowRequest(t, f, "POST", "/api/connected-apps/device-requests/"+consent.ID+"/decision", string(body))
	require.Equal(t, 200, w.Code, w.Body.String())
}

func TestIntegrationOldSessionCanPreviewAndRejectButCannotPublishDraft(t *testing.T) {
	f, h := integrationAuthFlowFixture(t)
	consent := flowConsent(t, f, h)
	binding, err := h.auth.DecideConsent(context.Background(), f.user.ID, consent.ID, services.IntegrationConsentDecision{Allow: true, Nonce: consent.Nonce, Scopes: consent.RequestedScopes})
	require.NoError(t, err)
	require.NoError(t, f.db.Create(&models.WaterSection{Slug: "campus_life", Title: "校园生活", Status: "active"}).Error)
	action, err := h.actions().Propose(context.Background(), binding, services.IntegrationProposal{OperationID: uuid.NewString(), Kind: "post", Title: "合成待确认草稿", Content: "公开测试正文", PostType: "campus_life"})
	require.NoError(t, err)
	path := "/api/connected-apps/actions/" + action.ID
	w := integrationFlowRequest(t, f, "GET", path, "")
	require.Equal(t, 200, w.Code, w.Body.String())
	var preview services.IntegrationActionPreview
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &preview))
	decision := services.IntegrationActionDecision{Allow: true, Nonce: preview.Nonce, Version: action.Version, PayloadHash: action.PayloadHash}
	body, _ := json.Marshal(decision)
	w = integrationFlowRequest(t, f, "POST", path+"/decision", string(body))
	require.Equal(t, 403, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), "recent_authentication_required")
	decision.Allow = false
	body, _ = json.Marshal(decision)
	w = integrationFlowRequest(t, f, "POST", path+"/decision", string(body))
	require.Equal(t, 200, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), `"state":"rejected"`)
}

func TestIntegrationScopeEditListsTogglesAndBlocksOnlyNewDisabledScopes(t *testing.T) {
	f, h := integrationAuthFlowFixture(t)
	now := time.Now().Truncate(time.Millisecond)
	h.auth.Now = func() time.Time { return now }
	require.NoError(t, f.db.Model(&models.RefreshToken{}).Where("token_family = ?", f.family).Update("authenticated_at", now.Add(-time.Minute)).Error)
	consent := flowConsent(t, f, h)
	decision, _ := json.Marshal(services.IntegrationConsentDecision{Allow: true, Nonce: consent.Nonce, Scopes: consent.RequestedScopes})
	w := integrationFlowRequest(t, f, "POST", "/api/connected-apps/device-requests/"+consent.ID+"/decision", string(decision))
	require.Equal(t, 200, w.Code, w.Body.String())

	w = integrationFlowRequest(t, f, "GET", "/api/connected-apps", "")
	require.Equal(t, 200, w.Code, w.Body.String())
	var list struct {
		Bindings         []models.IntegrationBinding `json:"bindings"`
		ProposalsEnabled *bool                       `json:"proposals_enabled"`
		AutoReplyEnabled *bool                       `json:"auto_reply_enabled"`
		AutoPostEnabled  *bool                       `json:"auto_post_enabled"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &list))
	require.True(t, *list.ProposalsEnabled)
	require.False(t, *list.AutoReplyEnabled)
	require.False(t, *list.AutoPostEnabled)
	binding := list.Bindings[0]
	path := "/api/connected-apps/" + binding.ID + "/scopes"

	body, _ := json.Marshal(services.IntegrationScopeUpdate{Scopes: append(strings.Fields(binding.Scopes), services.IntegrationAutoPostScope), ExpectedEpoch: binding.Epoch})
	w = integrationFlowRequest(t, f, "POST", path, string(body))
	require.Equal(t, 403, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), "bot_post_disabled")

	body, _ = json.Marshal(services.IntegrationScopeUpdate{Scopes: []string{"community:read", "actions:read_own"}, ExpectedEpoch: binding.Epoch})
	w = integrationFlowRequest(t, f, "POST", path, string(body))
	require.Equal(t, 200, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), `"scopes":"actions:read_own community:read"`)
}

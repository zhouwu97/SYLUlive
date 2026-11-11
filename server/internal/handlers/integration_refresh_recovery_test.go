package handlers

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"shenliyuan/internal/services"
)

func TestIntegrationHTTPRefreshRequestRecoversSameResult(t *testing.T) {
	f, h := integrationAuthFlowFixture(t)
	now := time.Now()
	h.auth.Now = func() time.Time { return now }
	device, err := h.auth.RequestDevice(context.Background(), uuid.NewString(), "合成恢复测试", "profile:read_minimal community:read")
	require.NoError(t, err)
	consent, err := h.auth.LookupConsent(context.Background(), f.user.ID, device.UserCode)
	require.NoError(t, err)
	_, err = h.auth.DecideConsent(context.Background(), f.user.ID, consent.ID, services.IntegrationConsentDecision{Allow: true, Scopes: consent.RequestedScopes, Nonce: consent.Nonce})
	require.NoError(t, err)
	now = now.Add(6 * time.Second)
	original, err := h.auth.ExchangeDevice(context.Background(), device.DeviceCode)
	require.NoError(t, err)
	form := url.Values{"client_id": {services.IntegrationClientID}, "grant_type": {"refresh_token"}, "refresh_token": {original.RefreshToken}, "refresh_request_id": {uuid.NewString()}}
	send := func() services.IntegrationTokenResponse {
		req := httptest.NewRequest("POST", "/api/oauth/token", strings.NewReader(form.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		w := httptest.NewRecorder()
		f.r.ServeHTTP(w, req)
		require.Equal(t, 200, w.Code)
		require.Equal(t, "no-store", w.Header().Get("Cache-Control"))
		var tokens services.IntegrationTokenResponse
		require.NoError(t, json.Unmarshal(w.Body.Bytes(), &tokens))
		return tokens
	}
	first := send()
	second := send()
	require.Equal(t, first.AccessToken, second.AccessToken)
	require.Equal(t, first.RefreshToken, second.RefreshToken)
}

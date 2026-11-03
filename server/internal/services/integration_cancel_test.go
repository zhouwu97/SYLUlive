package services

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

func TestIntegrationCancelDeviceRecoversPendingApprovedAndConsumedRequests(t *testing.T) {
	for _, stage := range []string{"unclaimed", "viewed", "approved", "consumed", "expired"} {
		t.Run(stage, func(t *testing.T) {
			db := integrationTestDB(t)
			integrationTestUser(t, db, 1)
			integrationTestUser(t, db, 2)
			auth := NewIntegrationAuthService(db)
			ctx := context.Background()
			now := time.Now()
			auth.Now = func() time.Time { return now }
			other, _ := integrationAuthorize(t, auth, 2, uuid.NewString())
			install := uuid.NewString()
			device, err := auth.RequestDevice(ctx, install, "QQ 123456789 · 合成助手", "profile:read_minimal")
			require.NoError(t, err)
			var consent IntegrationConsent
			var binding models.IntegrationBinding
			var tokens IntegrationTokenResponse
			if stage != "unclaimed" {
				consent, err = auth.LookupConsent(ctx, 1, device.UserCode)
				require.NoError(t, err)
			}
			if stage == "approved" || stage == "consumed" || stage == "expired" {
				binding, err = auth.DecideConsent(ctx, 1, consent.ID, IntegrationConsentDecision{Allow: true, Scopes: consent.RequestedScopes, Nonce: consent.Nonce})
				require.NoError(t, err)
			}
			if stage == "consumed" {
				now = now.Add(6 * time.Second)
				tokens, err = auth.ExchangeDevice(ctx, device.DeviceCode)
				require.NoError(t, err)
			}
			if stage == "expired" {
				now = now.Add(11 * time.Minute)
			}
			require.EqualError(t, auth.CancelDevice(ctx, device.UserCode), "invalid_request", "网页链接中的短代码不能撤销请求")
			require.NoError(t, auth.CancelDevice(ctx, device.DeviceCode))
			require.NoError(t, auth.CancelDevice(ctx, device.DeviceCode), "重复取消必须安全")
			var row models.IntegrationDeviceRequest
			require.NoError(t, db.Where("device_hash = ?", IntegrationSecretHash(device.DeviceCode)).Take(&row).Error)
			require.Equal(t, "denied", row.State)
			require.Empty(t, row.NonceHash)
			_, err = auth.LookupConsent(ctx, 1, device.UserCode)
			require.EqualError(t, err, "device_request_expired")
			if binding.ID != "" {
				require.Error(t, auth.CheckBinding(ctx, binding))
				var count int64
				require.NoError(t, db.Model(&models.IntegrationAudit{}).Where("binding_id = ? AND event = ?", binding.ID, "revoked").Count(&count).Error)
				require.EqualValues(t, 1, count)
			}
			if tokens.AccessToken != "" {
				_, err = auth.Authenticate(ctx, tokens.AccessToken)
				require.Error(t, err)
				_, err = auth.Refresh(ctx, tokens.RefreshToken)
				require.Error(t, err)
			}
			require.NoError(t, auth.CheckBinding(ctx, other), "取消一人的误绑不能撤销其他人")
			_, next := integrationAuthorize(t, auth, 1, install)
			require.NotEqual(t, device.UserCode, next.UserCode, "取消后可用同一QQ安装重新绑定")
		})
	}
}

func TestIntegrationCancelDeviceDoesNotRevokeReplacementAndRollsBackAuditFailure(t *testing.T) {
	db := integrationTestDB(t)
	integrationTestUser(t, db, 1)
	auth := NewIntegrationAuthService(db)
	ctx := context.Background()
	old, device := integrationAuthorize(t, auth, 1, uuid.NewString())
	require.NoError(t, auth.Revoke(ctx, 1, old.ID))
	replacement, next := integrationAuthorize(t, auth, 1, old.InstallationID)
	require.NoError(t, auth.CancelDevice(ctx, device.DeviceCode))
	require.NoError(t, auth.CheckBinding(ctx, replacement))
	require.EqualError(t, auth.CancelDevice(ctx, "sd_"+strings.Repeat("z", 43)), "device_request_unavailable")
	require.NoError(t, db.Migrator().DropTable(&models.IntegrationAudit{}))
	require.Error(t, auth.CancelDevice(ctx, next.DeviceCode))
	require.NoError(t, auth.CheckBinding(ctx, replacement), "审计失败不能部分撤销")
	var row models.IntegrationDeviceRequest
	require.NoError(t, db.Where("device_hash = ?", IntegrationSecretHash(next.DeviceCode)).Take(&row).Error)
	require.Equal(t, "approved", row.State)
}

func TestIntegrationCancelDeviceSerializesWithApproveAndExchange(t *testing.T) {
	for _, phase := range []string{"approve", "exchange"} {
		t.Run(phase, func(t *testing.T) {
			db := integrationTestDB(t)
			integrationTestUser(t, db, 1)
			auth := NewIntegrationAuthService(db)
			ctx := context.Background()
			device, err := auth.RequestDevice(ctx, uuid.NewString(), "QQ 123456789 · 并发合成助手", "profile:read_minimal")
			require.NoError(t, err)
			consent, err := auth.LookupConsent(ctx, 1, device.UserCode)
			require.NoError(t, err)
			decision := IntegrationConsentDecision{Allow: true, Scopes: consent.RequestedScopes, Nonce: consent.Nonce}
			if phase == "exchange" {
				_, err = auth.DecideConsent(ctx, 1, consent.ID, decision)
				require.NoError(t, err)
				require.NoError(t, db.Model(&models.IntegrationDeviceRequest{}).Where("id = ?", consent.ID).Update("next_poll_at", time.Now().Add(-time.Second)).Error)
			}
			start, cancelled, finished := make(chan struct{}), make(chan error, 1), make(chan struct{})
			go func() { <-start; cancelled <- auth.CancelDevice(ctx, device.DeviceCode) }()
			go func() {
				defer close(finished)
				<-start
				if phase == "approve" {
					_, _ = auth.DecideConsent(ctx, 1, consent.ID, decision)
				} else {
					_, _ = auth.ExchangeDevice(ctx, device.DeviceCode)
				}
			}()
			close(start)
			require.NoError(t, <-cancelled)
			<-finished
			var active int64
			require.NoError(t, db.Model(&models.IntegrationBinding{}).Where("installation_id = ? AND state = ?", consent.InstallationID, "active").Count(&active).Error)
			require.Zero(t, active, "取消与批准／领证并发也不能留下活跃误绑")
		})
	}
}

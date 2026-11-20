package services

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

func TestIntegrationRefreshRecoversLostResponseAcrossRestart(t *testing.T) {
	db := integrationTestDB(t)
	integrationTestUser(t, db, 1)
	s := NewIntegrationAuthService(db)
	now := time.Now()
	s.Now = func() time.Time { return now }
	ctx := context.Background()
	binding, device := integrationAuthorize(t, s, 1, uuid.NewString())
	now = now.Add(6 * time.Second)
	original, err := s.ExchangeDevice(ctx, device.DeviceCode)
	require.NoError(t, err)
	requestID := uuid.NewString()
	first, err := s.RefreshWithRequest(ctx, original.RefreshToken, requestID)
	require.NoError(t, err)
	// 模拟回复丢失并重启，访问令牌过期后仍能恢复同一后继刷新凭据。
	now = now.Add(20 * time.Minute)
	restarted := NewIntegrationAuthService(db)
	restarted.Now = s.Now
	recovered, err := restarted.RefreshWithRequest(ctx, original.RefreshToken, requestID)
	require.NoError(t, err)
	require.Equal(t, first.AccessToken, recovered.AccessToken)
	require.Equal(t, first.RefreshToken, recovered.RefreshToken)
	require.NoError(t, restarted.CheckBinding(ctx, binding))
	_, err = restarted.Authenticate(ctx, recovered.AccessToken)
	require.NoError(t, err)
	next, err := restarted.RefreshWithRequest(ctx, recovered.RefreshToken, uuid.NewString())
	require.NoError(t, err)
	_, err = restarted.RefreshWithRequest(ctx, original.RefreshToken, requestID)
	require.EqualError(t, err, "invalid_grant")
	_, err = restarted.Authenticate(ctx, next.AccessToken)
	require.NoError(t, err, "旧的幂等请求不能撤销已经继续轮换的连接")
	var rows []models.IntegrationCredential
	require.NoError(t, db.Find(&rows).Error)
	raw, err := json.Marshal(rows)
	require.NoError(t, err)
	require.NotContains(t, string(raw), requestID)
	require.NotContains(t, string(raw), recovered.RefreshToken)
}

func TestIntegrationRefreshDifferentRequestStillRevokesReplay(t *testing.T) {
	db := integrationTestDB(t)
	integrationTestUser(t, db, 1)
	s := NewIntegrationAuthService(db)
	now := time.Now()
	s.Now = func() time.Time { return now }
	_, device := integrationAuthorize(t, s, 1, uuid.NewString())
	now = now.Add(6 * time.Second)
	original, err := s.ExchangeDevice(context.Background(), device.DeviceCode)
	require.NoError(t, err)
	first, err := s.RefreshWithRequest(context.Background(), original.RefreshToken, uuid.NewString())
	require.NoError(t, err)
	_, err = s.RefreshWithRequest(context.Background(), original.RefreshToken, uuid.NewString())
	require.EqualError(t, err, "invalid_grant")
	_, err = s.Authenticate(context.Background(), first.AccessToken)
	require.EqualError(t, err, "invalid_token")
}

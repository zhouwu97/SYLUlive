package ai

import (
	"context"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type mutablePermissionVersion struct{ version int64 }

func (reader *mutablePermissionVersion) PermissionVersion(context.Context, uint, models.AIUserPermissionScope) (int64, error) {
	return reader.version, nil
}

func TestScopedGrantIsOpaqueRunBoundedAndSingleUseBudgeted(t *testing.T) {
	now := time.Unix(100, 0)
	manager := NewScopedGrantManager(func() time.Time { return now })
	token, grant, err := manager.IssueRunGrant("run-1", 7, []string{"academic.summary"}, []string{"academic:summary"}, time.Minute, 1)
	require.NoError(t, err)
	require.True(t, len(token) > 10)
	require.Equal(t, "run-1", grant.RunID)
	require.NotContains(t, token, "run-1")

	verified, err := manager.Verify(token, "academic.summary")
	require.NoError(t, err)
	require.Equal(t, uint(7), verified.UserID)
	_, err = manager.Verify(token, "academic.summary")
	require.Error(t, err)

	_, err = manager.Verify(token, "schedule.free_windows")
	require.Error(t, err)
}

func TestScopedGrantExpiresClosed(t *testing.T) {
	now := time.Unix(100, 0)
	manager := NewScopedGrantManager(func() time.Time { return now })
	token, _, err := manager.IssueRunGrant("run-1", 7, []string{"system.status"}, nil, time.Second, 1)
	require.NoError(t, err)
	now = now.Add(2 * time.Second)
	_, err = manager.Verify(token, "system.status")
	require.Error(t, err)
}

func TestScopedGrantIsRejectedAfterPermissionVersionChanges(t *testing.T) {
	now := time.Unix(100, 0)
	reader := &mutablePermissionVersion{version: 1}
	manager := NewScopedGrantManager(
		func() time.Time { return now },
		WithScopedGrantPermissionVersionReader(reader),
	)
	token, _, err := manager.IssueRunGrantWithContext(
		context.Background(), "run-live-revoke", 7,
		[]string{"academic.summary"}, []string{"academic:summary"},
		models.AIUserPermissionPersonalDataAccess, time.Minute, 1,
	)
	require.NoError(t, err)
	reader.version = 2
	_, err = manager.VerifyContext(context.Background(), token, "academic.summary")
	require.EqualError(t, err, "mcp_grant_revoked")
}

func TestScopedGrantDatabaseStoreIsSharedAcrossInstances(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:scoped-grant-shared?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AIScopedGrant{}))
	managerA := NewScopedGrantManager(time.Now, WithScopedGrantDB(db))
	managerB := NewScopedGrantManager(time.Now, WithScopedGrantDB(db))
	token, _, err := managerA.IssueRunGrant("run-shared", 7, []string{"system.status"}, nil, time.Minute, 1)
	require.NoError(t, err)
	_, err = managerB.Verify(token, "system.status")
	require.NoError(t, err)
	_, err = managerA.Verify(token, "system.status")
	require.Error(t, err)

	token, _, err = managerA.IssueRunGrant("run-revoked-shared", 7, []string{"system.status"}, nil, time.Minute, 1)
	require.NoError(t, err)
	managerA.RevokeRun("run-revoked-shared")
	_, err = managerB.Verify(token, "system.status")
	require.EqualError(t, err, "mcp_grant_expired")
}

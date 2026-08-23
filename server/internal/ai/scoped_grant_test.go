package ai

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

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

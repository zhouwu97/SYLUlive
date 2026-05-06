package handlers

import (
	"testing"
	"time"
)

func TestLoginLockDurationForFailures(t *testing.T) {
	cases := []struct {
		failures int
		want     time.Duration
	}{
		{1, 0},
		{2, 0},
		{3, time.Minute},
		{4, 3 * time.Minute},
		{5, 5 * time.Minute},
		{6, 10 * time.Minute},
		{9, 10 * time.Minute},
	}

	for _, tc := range cases {
		if got := loginLockDurationForFailures(tc.failures); got != tc.want {
			t.Fatalf("failures=%d got=%v want=%v", tc.failures, got, tc.want)
		}
	}
}

func TestLoginThrottleEscalatesAndClears(t *testing.T) {
	account := "test-account"
	clearLoginFailures(account)
	base := time.Date(2026, 5, 6, 12, 0, 0, 0, time.UTC)

	if got := registerLoginFailure(account, base); got != 0 {
		t.Fatalf("first failure should not lock, got %v", got)
	}
	if got := registerLoginFailure(account, base); got != 0 {
		t.Fatalf("second failure should not lock, got %v", got)
	}
	if got := registerLoginFailure(account, base); got != time.Minute {
		t.Fatalf("third failure got %v want %v", got, time.Minute)
	}
	if remaining, locked := currentLoginLock(account, base.Add(30*time.Second)); !locked || remaining <= 0 {
		t.Fatalf("expected account to be locked after third failure")
	}
	if remaining, locked := currentLoginLock(account, base.Add(time.Minute)); locked || remaining != 0 {
		t.Fatalf("expected lock to expire at boundary, got locked=%v remaining=%v", locked, remaining)
	}
	if got := registerLoginFailure(account, base.Add(time.Minute)); got != 3*time.Minute {
		t.Fatalf("fourth failure got %v want %v", got, 3*time.Minute)
	}

	clearLoginFailures(account)
	if remaining, locked := currentLoginLock(account, base.Add(2*time.Minute)); locked || remaining != 0 {
		t.Fatalf("expected account to be cleared after success/reset")
	}
}

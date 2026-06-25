package services

import (
	"testing"
)

func TestSyncResultDefaults(t *testing.T) {
	r := &SyncResult{}
	if r.IsBootstrap {
		t.Error("new SyncResult should not be bootstrap by default")
	}
	if r.Added != 0 || r.Updated != 0 || r.Skipped != 0 {
		t.Error("new SyncResult counts should be zero")
	}
}

package tasks

import (
	"sync"
	"testing"
)

func TestMutexPreventsOverlap(t *testing.T) {
	var mu sync.Mutex

	if !mu.TryLock() {
		t.Fatal("initial lock should succeed")
	}
	if mu.TryLock() {
		t.Fatal("double lock should fail")
	}
}

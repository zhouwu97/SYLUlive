package services

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"shenliyuan/internal/competitionmatching"
	"shenliyuan/internal/models"
)

func TestImageFileIDsRejectNativeOverflow(t *testing.T) {
	raw := "4294967297"
	ids, err := ParseImageFileIDs(raw)
	if strconv.IntSize == 32 {
		if err == nil {
			t.Fatalf("overflow accepted as %v", ids)
		}
	} else if err != nil || len(ids) != 1 || uint64(ids[0]) != 4294967297 {
		t.Fatalf("valid 64-bit id rejected: %v %v", ids, err)
	}
}

func TestRankTraceHasHardLimit(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	engine := &competitionCandidateEngine{db: db, traceSamplePercent: 100}
	ordered := make([]competitionmatching.Ranked, 100)
	for i := range ordered {
		ordered[i].ID = uint(i + 1)
	}
	engine.saveRankTrace(context.Background(), 1, CandidateFilter{PageSize: int(^uint(0) >> 1)}, ordered, time.Now())
	var count int64
	if err := db.Model(&models.CompetitionRankTrace{}).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 50 {
		t.Fatalf("unbounded trace rows: %d", count)
	}
}

func TestPublicEmojiCannotReadOutsideUploadRoot(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	path := writeEmojiPNG(t, outside, "secret.png")
	if err := os.Symlink(path, filepath.Join(root, "link.png")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	service := NewEmojiFavoriteService(nil, root)
	if _, err := service.readUploadImage(filepath.Join(root, "link.png")); err == nil {
		t.Fatal("read image outside upload root")
	}
}

func TestUploadImageReadsOnlyInsideRoot(t *testing.T) {
	root := t.TempDir()
	file := writeEmojiPNG(t, root, "allowed.png")
	service := NewEmojiFavoriteService(nil, root)
	got, err := service.readUploadImage(file)
	if err != nil || len(got) == 0 {
		t.Fatalf("valid image rejected: %v", err)
	}
	if _, err := service.readUploadImage(filepath.Join(t.TempDir(), "outside.png")); err == nil {
		t.Fatal("accepted outside path")
	}
}

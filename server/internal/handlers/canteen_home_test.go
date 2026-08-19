package handlers

import (
	"testing"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"gorm.io/gorm"
)

// 构造一条食堂评价数据（带体验标签）。
func seedHomeRating(t *testing.T, db *gorm.DB, canteenID, userID, star int, tags []string, daysAgo int) {
	t.Helper()
	jsonTags := `[]`
	if len(tags) > 0 {
		jsonTags = `["` + joinTags(tags) + `"]`
	}
	rating := models.CanteenRating{
		CanteenID: uint(canteenID),
		UserID:    uint(userID),
		Star:      star,
		Comment:   "test",
		Tags:      jsonTags,
	}
	rating.CreatedAt = time.Now().AddDate(0, 0, -daysAgo)
	if err := db.Create(&rating).Error; err != nil {
		t.Fatalf("create rating: %v", err)
	}
}

func joinTags(tags []string) string {
	out := ""
	for i, t := range tags {
		if i > 0 {
			out += `","`
		}
		out += t
	}
	return out
}

func seedHomePhoto(t *testing.T, db *gorm.DB, dishID, fileID, canteenID uint, status string, daysAgo int) {
	t.Helper()
	photo := models.CanteenDishPhoto{
		DishID:    dishID,
		FileID:    fileID,
		UserID:    1,
		Status:    status,
		SortOrder: 0,
	}
	photo.CreatedAt = time.Now().AddDate(0, 0, -daysAgo)
	if err := db.Create(&photo).Error; err != nil {
		t.Fatalf("create photo: %v", err)
	}
}

// TestGetHomeFeedUsesVerifiedAndApprovedOnly 首页只包含 verified 食堂与 approved 实拍。
func TestGetHomeFeedUsesVerifiedAndApprovedOnly(t *testing.T) {
	db := newCanteenTestDB(t)
	h := NewCanteenHandler(db)

	// 3 个 verified 食堂 + 1 个未审核食堂
	verified := []models.Canteen{
		{Name: "A楼", Image: "/uploads/a.png", CreatedBy: 1, Verified: true},
		{Name: "B楼", Image: "/uploads/b.png", CreatedBy: 1, Verified: true},
		{Name: "C楼", Image: "/uploads/c.png", CreatedBy: 1, Verified: true},
		{Name: "未审核", Image: "/uploads/x.png", CreatedBy: 1, Verified: false},
	}
	ids := make([]uint, 0, len(verified))
	for i := range verified {
		if err := db.Create(&verified[i]).Error; err != nil {
			t.Fatalf("create canteen: %v", err)
		}
		ids = append(ids, verified[i].ID)
	}

	// 评价（verified 三家有评价；未审核也造一条，绝不应进入推荐）
	seedHomeRating(t, db, int(ids[0]), 2, 5, []string{"taste_good", "portion_enough"}, 1)
	seedHomeRating(t, db, int(ids[1]), 3, 4, []string{"taste_good"}, 2)
	seedHomeRating(t, db, int(ids[2]), 4, 4, []string{"price_fair"}, 3)
	seedHomeRating(t, db, int(ids[3]), 5, 5, []string{"taste_good"}, 1)

	// 一个 approved 实拍（A楼）、一个 pending（B楼，绝不应出现）
	dishA := models.CanteenDish{CanteenID: ids[0], Name: "米饭", NormalizedName: "饭", Status: models.DishStatusActive}
	dishB := models.CanteenDish{CanteenID: ids[1], Name: "面", NormalizedName: "面", Status: models.DishStatusActive}
	if err := db.Create(&dishA).Error; err != nil {
		t.Fatalf("create dish: %v", err)
	}
	if err := db.Create(&dishB).Error; err != nil {
		t.Fatalf("create dish: %v", err)
	}
	_ = db.Create(&models.File{Hash: "a", Path: "/uploads/p1.png", Size: 1, MimeType: "image/png"}).Error
	_ = db.Create(&models.File{Hash: "b", Path: "/uploads/p2.png", Size: 1, MimeType: "image/png"}).Error
	fileA, fileB := models.File{}, models.File{}
	db.Where("hash = ?", "a").First(&fileA)
	db.Where("hash = ?", "b").First(&fileB)
	seedHomePhoto(t, db, dishA.ID, fileA.ID, ids[0], models.DishPhotoStatusApproved, 1)
	seedHomePhoto(t, db, dishB.ID, fileB.ID, ids[1], models.DishPhotoStatusPending, 0)

	rows, err := h.queryCanteenStats()
	if err != nil {
		t.Fatalf("query stats: %v", err)
	}
	if len(rows) != 3 {
		t.Fatalf("expected 3 verified canteens, got %d", len(rows))
	}
	mean := globalMeanStars(rows)

	feed := h.BuildHomeFeed(toEntries(rows, mean), mean, 8, nil, nil)
	if len(feed) == 0 {
		t.Fatalf("expected non-empty feed")
	}
	seen := map[uint]int{}
	for i, item := range feed {
		seen[item.CanteenID]++
		if item.CanteenID == ids[3] {
			t.Fatalf("unverified canteen must not appear in feed (index %d)", i)
		}
		if seen[item.CanteenID] > 2 {
			t.Fatalf("canteen %d appears %d times, exceeds per-screen cap", item.CanteenID, seen[item.CanteenID])
		}
		if i > 0 && feed[i-1].CanteenID == item.CanteenID {
			t.Fatalf("same canteen %d adjacent at %d", item.CanteenID, i)
		}
	}
	// pending 实拍不应进入 recent_photo
	for i, item := range feed {
		if item.Type == "recent_photo" && item.CanteenID == ids[1] {
			t.Fatalf("pending photo leaked into feed (index %d)", i)
		}
	}
}

// TestBuildHomeFeedEmpty 无任何评价/实拍时首页应正常降级为空 feed，不 panic。
func TestBuildHomeFeedEmpty(t *testing.T) {
	db := newCanteenTestDB(t)
	h := NewCanteenHandler(db)
	_ = db.Create(&models.Canteen{Name: "A", Image: "/uploads/a.png", CreatedBy: 1, Verified: true}).Error

	rows, err := h.queryCanteenStats()
	if err != nil {
		t.Fatalf("query stats: %v", err)
	}
	mean := globalMeanStars(rows)
	feed := h.BuildHomeFeed(toEntries(rows, mean), mean, 8, nil, nil)
	if feed == nil || len(feed) != 0 {
		t.Fatalf("expected empty feed on no data, got %v", feed)
	}
}

func toEntries(rows []canteenStatsRow, mean float64) []canteenRankingEntry {
	entries := make([]canteenRankingEntry, 0, len(rows))
	for _, r := range rows {
		entries = append(entries, canteenRankingEntry{
			canteenStatsRow: r,
			RankingScore:    services.BayesianRatingScore(r.AverageStar, float64(r.RatingCount), mean, services.BayesianPriorWeight),
		})
	}
	return entries
}

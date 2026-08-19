//go:build integration

package models

import (
	"os"
	"testing"
	"time"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

// TestCanteenRatingMigrationIntegration 验证 EnsureRatingInteractionSchema 的 canteen 段：
// 重复评分清理、vote 整理、计数重算与唯一索引。需要 TEST_DATABASE_DSN。
func TestCanteenRatingMigrationIntegration(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_DSN")
	if dsn == "" {
		t.Skip("TEST_DATABASE_DSN 未设置，跳过 PostgreSQL 集成测试")
	}
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}

	// 隔离测试数据：清空目标表
	db.Exec("DELETE FROM canteen_rating_votes")
	db.Exec("DELETE FROM canteen_ratings")
	db.Exec("DELETE FROM canteens")
	db.Exec("DROP INDEX IF EXISTS uq_canteen_rating_user")

	if err := db.AutoMigrate(&Canteen{}, &CanteenRating{}, &CanteenRatingVote{}); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	canteen := Canteen{Name: "迁移测试食堂", Image: "/uploads/x.png", Verified: true}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatalf("create canteen: %v", err)
	}

	// 构造重复评分：用户 1 两条，用户 2 两条（其中一条与用户 1 投票重叠）
	now := time.Now()
	r1 := CanteenRating{CanteenID: canteen.ID, UserID: 1, Star: 5, Comment: "new", CreatedAt: now.Add(time.Hour)}
	r1old := CanteenRating{CanteenID: canteen.ID, UserID: 1, Star: 1, Comment: "old", CreatedAt: now}
	r2 := CanteenRating{CanteenID: canteen.ID, UserID: 2, Star: 4, CreatedAt: now.Add(2 * time.Hour)}
	r2old := CanteenRating{CanteenID: canteen.ID, UserID: 2, Star: 2, CreatedAt: now.Add(time.Minute)}
	if err := db.Create(&r1).Error; err != nil {
		t.Fatalf("create r1: %v", err)
	}
	if err := db.Create(&r1old).Error; err != nil {
		t.Fatalf("create r1old: %v", err)
	}
	if err := db.Create(&r2).Error; err != nil {
		t.Fatalf("create r2: %v", err)
	}
	if err := db.Create(&r2old).Error; err != nil {
		t.Fatalf("create r2old: %v", err)
	}

	// votes：r1old 上有 user 3 的 up，r2old 上有 user 3 的 down（r2 无 vote）
	if err := db.Create(&CanteenRatingVote{RatingID: r1old.ID, UserID: 3, VoteType: "up"}).Error; err != nil {
		t.Fatalf("create vote1: %v", err)
	}
	if err := db.Create(&CanteenRatingVote{RatingID: r2old.ID, UserID: 3, VoteType: "down"}).Error; err != nil {
		t.Fatalf("create vote2: %v", err)
	}

	// 执行迁移（幂等：跑两次）
	for i := 0; i < 2; i++ {
		if err := EnsureRatingInteractionSchema(db); err != nil {
			t.Fatalf("run %d: %v", i, err)
		}
	}

	// 断言：每个 (canteen,user) 仅一条
	var count int64
	db.Model(&CanteenRating{}).Where("canteen_id = ? AND user_id = ?", canteen.ID, 1).Count(&count)
	if count != 1 {
		t.Fatalf("user1 ratings count=%d want 1", count)
	}
	db.Model(&CanteenRating{}).Where("canteen_id = ? AND user_id = ?", canteen.ID, 2).Count(&count)
	if count != 1 {
		t.Fatalf("user2 ratings count=%d want 1", count)
	}

	// 断言保留的是最新一条
	var kept models2Rating
	if err := db.Model(&CanteenRating{}).Where("canteen_id = ? AND user_id = ?", canteen.ID, 1).First(&kept).Error; err != nil {
		t.Fatalf("get kept: %v", err)
	}
	if kept.Comment != "new" {
		t.Fatalf("kept comment=%q want new (updated_at 最新)", kept.Comment)
	}

	// 断言无孤儿 vote
	db.Model(&CanteenRatingVote{}).Where("rating_id NOT IN (SELECT id FROM canteen_ratings)").Count(&count)
	if count != 0 {
		t.Fatalf("orphan votes=%d want 0", count)
	}

	// 断言 vote 数：r1 保留的 rating 现在应持有 user3 的 up（原 r1old 的 vote 重挂），
	// r2 保留的 rating 应持有 user3 的 down。
	var voteCount int64
	db.Model(&CanteenRatingVote{}).Where("rating_id = ? AND vote_type = 'up'", kept.ID).Count(&voteCount)
	if voteCount != 1 {
		t.Fatalf("kept up votes=%d want 1", voteCount)
	}
	db.Model(&CanteenRatingVote{}).Where("rating_id = ? AND vote_type = 'down'", kept.ID).Count(&voteCount)
	if voteCount != 0 {
		t.Fatalf("kept down votes=%d want 0", voteCount)
	}

	// 断言 helpful/unhelpful 重算正确
	var r1kept CanteenRating
	db.First(&r1kept, kept.ID)
	if r1kept.HelpfulCount != 1 || r1kept.UnhelpfulCount != 0 {
		t.Fatalf("kept helpful=%d unhelpful=%d want 1/0", r1kept.HelpfulCount, r1kept.UnhelpfulCount)
	}
	var r2kept CanteenRating
	db.Model(&CanteenRating{}).Where("canteen_id = ? AND user_id = ?", canteen.ID, 2).First(&r2kept)
	if r2kept.HelpfulCount != 0 || r2kept.UnhelpfulCount != 1 {
		t.Fatalf("r2 helpful=%d unhelpful=%d want 0/1", r2kept.HelpfulCount, r2kept.UnhelpfulCount)
	}

	// 断言唯一索引存在
	var indexCount int64
	db.Raw("SELECT COUNT(*) FROM pg_indexes WHERE indexname = 'uq_canteen_rating_user'").Scan(&indexCount)
	if indexCount != 1 {
		t.Fatalf("unique index not created")
	}
}

// models2Rating 用于从 CanteenRating 查询最小字段（避免与 models 包内同名冲突）。
type models2Rating struct {
	ID        uint
	Comment   string
	HelpfulCount   int
	UnhelpfulCount int
}

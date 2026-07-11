package handlers

import (
	"fmt"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestRecalculatePostReplyStatsTracksOnlyNormalReplies(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:post_activity_%d?mode=memory&cache=shared", time.Now().UnixNano())), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.Post{}, &models.Reply{}); err != nil {
		t.Fatalf("migrate database: %v", err)
	}

	createdAt := time.Date(2026, 7, 11, 8, 0, 0, 0, time.UTC)
	user := models.User{StudentID: "20260002", PasswordHash: "x", Nickname: "测试用户"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	post := models.Post{BoardID: models.BoardShuitie, AuthorID: user.ID, Content: "帖子", Status: models.PostStatusNormal, CreatedAt: createdAt, LastActivityAt: createdAt}
	if err := db.Create(&post).Error; err != nil {
		t.Fatalf("create post: %v", err)
	}
	firstAt := createdAt.Add(time.Hour)
	lastAt := createdAt.Add(2 * time.Hour)
	first := models.Reply{PostID: post.ID, AuthorID: user.ID, Content: "第一条", Status: models.ReplyStatusNormal, CreatedAt: firstAt}
	last := models.Reply{PostID: post.ID, AuthorID: user.ID, Content: "第二条", Status: models.ReplyStatusNormal, CreatedAt: lastAt}
	if err := db.Create(&first).Error; err != nil {
		t.Fatalf("create first reply: %v", err)
	}
	if err := db.Create(&last).Error; err != nil {
		t.Fatalf("create last reply: %v", err)
	}

	if err := db.Transaction(func(tx *gorm.DB) error { return recalculatePostReplyStats(tx, post.ID) }); err != nil {
		t.Fatalf("recalculate after replies: %v", err)
	}
	assertPostActivity(t, db, post.ID, 2, lastAt)

	if err := db.Model(&last).Update("status", models.ReplyStatusDeleted).Error; err != nil {
		t.Fatalf("delete latest reply: %v", err)
	}
	if err := db.Transaction(func(tx *gorm.DB) error { return recalculatePostReplyStats(tx, post.ID) }); err != nil {
		t.Fatalf("recalculate after latest deletion: %v", err)
	}
	assertPostActivity(t, db, post.ID, 1, firstAt)

	if err := db.Model(&first).Update("status", models.ReplyStatusDeleted).Error; err != nil {
		t.Fatalf("delete first reply: %v", err)
	}
	if err := db.Transaction(func(tx *gorm.DB) error { return recalculatePostReplyStats(tx, post.ID) }); err != nil {
		t.Fatalf("recalculate after all deletions: %v", err)
	}
	assertPostActivity(t, db, post.ID, 0, createdAt)
}

func assertPostActivity(t *testing.T, db *gorm.DB, postID uint, wantCount int, wantAt time.Time) {
	t.Helper()
	var post models.Post
	if err := db.First(&post, postID).Error; err != nil {
		t.Fatalf("load post: %v", err)
	}
	if post.ReplyCount != wantCount {
		t.Fatalf("reply_count=%d, want %d", post.ReplyCount, wantCount)
	}
	if !post.LastActivityAt.Equal(wantAt) {
		t.Fatalf("last_activity_at=%s, want %s", post.LastActivityAt, wantAt)
	}
}

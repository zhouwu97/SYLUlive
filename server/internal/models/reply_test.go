package models

import (
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestReplyCompositeListIndex(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&Reply{}); err != nil {
		t.Fatal(err)
	}
	if !db.Migrator().HasIndex(&Reply{}, "idx_replies_post_status_created") {
		t.Fatal("评论列表缺少 post_id/status/created_at 复合索引")
	}
}

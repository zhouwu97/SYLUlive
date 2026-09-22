package models

import (
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestPublicPostStatusesWhitelist(t *testing.T) {
	for _, status := range PublicPostStatuses() {
		if !IsPublicPostStatus(status) {
			t.Fatalf("白名单状态 %s 判定为不可公开", status)
		}
	}
	for _, status := range []PostStatus{PostStatusDeleted, PostStatusModeratedHidden, PostStatus("quarantined_by_future_policy"), PostStatus("")} {
		if IsPublicPostStatus(status) {
			t.Fatalf("状态 %s 不应公开可读", status)
		}
	}
}

// TestPublicPostStatusesReturnsCopy 保证调用方排序或追加不会污染全局白名单。
func TestPublicPostStatusesReturnsCopy(t *testing.T) {
	first := PublicPostStatuses()
	original := first[0]
	first[0] = PostStatusDeleted
	if PublicPostStatuses()[0] != original {
		t.Fatal("PublicPostStatuses 返回了共享切片")
	}
}

// TestPublicPostStatusesMatchesReaderQuery 用真实查询确认白名单可以直接作为 IN 参数。
func TestPublicPostStatusesMatchesReaderQuery(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(&Post{}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	statuses := append(PublicPostStatuses(), PostStatusModeratedHidden, PostStatusDeleted)
	for i, status := range statuses {
		if err := db.Create(&Post{ID: uint(i + 1), Status: status, Title: "可见性", CreatedAt: now, LastActivityAt: now}).Error; err != nil {
			t.Fatal(err)
		}
	}
	var visible []Post
	if err := db.Where("status IN ?", PublicPostStatuses()).Order("id ASC").Find(&visible).Error; err != nil {
		t.Fatal(err)
	}
	if len(visible) != len(PublicPostStatuses()) {
		t.Fatalf("公共白名单查询返回 %d 条，期望 %d 条", len(visible), len(PublicPostStatuses()))
	}
}

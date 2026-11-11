package main

import (
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// 被驳回的提交保留记录后，可能和后来通过审核的同名店同时存在；
// 启动时的规范名回填不能把它们判成重复而拒绝启动，也不能把占位名改回真实店名。
func TestCanteenNameIndexSkipsRejectedSubmissions(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.Canteen{}); err != nil {
		t.Fatal(err)
	}
	rejectedAt := time.Now()
	rejected := models.Canteen{Name: "煎饼果子", Image: "/uploads/a.png", CreatedBy: 1, RejectedAt: &rejectedAt}
	if err := db.Create(&rejected).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Model(&rejected).Update("normalized_name", models.CanteenRejectedNormalizedName(rejected.ID)).Error; err != nil {
		t.Fatal(err)
	}
	live := models.Canteen{Name: "煎饼果子", NormalizedName: "", Image: "/uploads/b.png", CreatedBy: 2, Verified: true}
	if err := db.Create(&live).Error; err != nil {
		t.Fatal(err)
	}

	if err := ensureCanteenNormalizedNameIndex(db); err != nil {
		t.Fatalf("startup normalization must tolerate rejected duplicates: %v", err)
	}
	var reloadedRejected, reloadedLive models.Canteen
	db.First(&reloadedRejected, rejected.ID)
	db.First(&reloadedLive, live.ID)
	if reloadedRejected.NormalizedName != models.CanteenRejectedNormalizedName(rejected.ID) || reloadedLive.NormalizedName != "煎饼果子" {
		t.Fatalf("rejected=%q live=%q", reloadedRejected.NormalizedName, reloadedLive.NormalizedName)
	}
}

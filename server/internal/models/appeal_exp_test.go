package models

import (
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func newAppealExpTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&User{}); err != nil {
		t.Fatalf("迁移 users 表失败: %v", err)
	}
	return db
}

func readAdminExp(t *testing.T, db *gorm.DB, id uint) int {
	t.Helper()
	var stored User
	if err := db.First(&stored, id).Error; err != nil {
		t.Fatalf("读取管理员失败: %v", err)
	}
	return stored.AdminExp
}

// 每个申诉各扣一次：读-改-写实现会在连续/并发结案时丢掉其中一次扣减。
func TestPenalizeAdminExpOnAppealPassDeductsPerAppeal(t *testing.T) {
	db := newAppealExpTestDB(t)
	admin := User{StudentID: "2026000001", AdminExp: 10}
	if err := db.Create(&admin).Error; err != nil {
		t.Fatalf("创建管理员失败: %v", err)
	}

	for i := 0; i < 2; i++ {
		if err := PenalizeAdminExpOnAppealPass(db, admin.ID); err != nil {
			t.Fatalf("第 %d 次扣减失败: %v", i+1, err)
		}
	}

	if got := readAdminExp(t, db, admin.ID); got != 4 {
		t.Fatalf("两次扣减后经验应为 4，实际 %d", got)
	}
}

func TestPenalizeAdminExpOnAppealPassNeverGoesNegative(t *testing.T) {
	db := newAppealExpTestDB(t)
	admin := User{StudentID: "2026000002", AdminExp: 2}
	if err := db.Create(&admin).Error; err != nil {
		t.Fatalf("创建管理员失败: %v", err)
	}

	if err := PenalizeAdminExpOnAppealPass(db, admin.ID); err != nil {
		t.Fatalf("扣减失败: %v", err)
	}

	if got := readAdminExp(t, db, admin.ID); got != 0 {
		t.Fatalf("经验不足时应扣到 0，实际 %d", got)
	}
}

func TestRewardAdminExpOnAppealRejectAccumulates(t *testing.T) {
	db := newAppealExpTestDB(t)
	admin := User{StudentID: "2026000003", AdminExp: 1}
	if err := db.Create(&admin).Error; err != nil {
		t.Fatalf("创建管理员失败: %v", err)
	}

	if err := RewardAdminExpOnAppealReject(db, admin.ID); err != nil {
		t.Fatalf("奖励失败: %v", err)
	}

	if got := readAdminExp(t, db, admin.ID); got != 6 {
		t.Fatalf("申诉被驳回后经验应为 6，实际 %d", got)
	}
}

// 管理员记录不存在时不得报错，也不得影响结案事务（原实现静默跳过，行为保持一致）。
func TestPenalizeAdminExpOnAppealPassToleratesMissingAdmin(t *testing.T) {
	db := newAppealExpTestDB(t)

	if err := PenalizeAdminExpOnAppealPass(db, 9999); err != nil {
		t.Fatalf("管理员不存在时不应报错: %v", err)
	}
}

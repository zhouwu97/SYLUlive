package handlers

import (
	"errors"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func openAccountIdentityTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}); err != nil {
		t.Fatalf("迁移用户表失败: %v", err)
	}
	return db
}

func TestPrecheckEduBindingProtectsStudentIdentity(t *testing.T) {
	db := openAccountIdentityTestDB(t)
	now := time.Now()
	owner := models.User{
		StudentID: "2026000001", StudentVerifiedAt: &now, PasswordHash: "hash", Nickname: "学号拥有者",
	}
	target := models.User{Email: "target@example.com", PasswordHash: "hash", Nickname: "邮箱用户"}
	if err := db.Create(&owner).Error; err != nil {
		t.Fatalf("创建学号拥有者失败: %v", err)
	}
	if err := db.Create(&target).Error; err != nil {
		t.Fatalf("创建目标用户失败: %v", err)
	}

	if err := precheckEduBinding(db, target.ID, owner.StudentID); !errors.Is(err, errEduStudentAlreadyBound) {
		t.Fatalf("已占用学号预检查错误=%v，期望=%v", err, errEduStudentAlreadyBound)
	}
	if err := precheckEduBinding(db, owner.ID, "2026000002"); !errors.Is(err, errEduStudentIdentityImmutable) {
		t.Fatalf("已认证学号变更预检查错误=%v，期望=%v", err, errEduStudentIdentityImmutable)
	}
}

func TestFindLoginUserFallsBackToTenDigitLegacyQQ(t *testing.T) {
	db := openAccountIdentityTestDB(t)
	legacy := models.User{QQ: "1234567890", PasswordHash: "hash", Nickname: "旧 QQ 用户"}
	if err := db.Create(&legacy).Error; err != nil {
		t.Fatalf("创建旧 QQ 用户失败: %v", err)
	}
	handler := NewAuthHandler(db, "test-jwt-secret")

	user, err := handler.findLoginUser(legacy.QQ)
	if err != nil || user.ID != legacy.ID {
		t.Fatalf("十位 QQ 回退结果 id=%d err=%v，期望 id=%d", user.ID, err, legacy.ID)
	}

	now := time.Now()
	student := models.User{
		StudentID: legacy.QQ, StudentVerifiedAt: &now, PasswordHash: "hash", Nickname: "真实学号用户",
	}
	if err := db.Create(&student).Error; err != nil {
		t.Fatalf("创建真实学号用户失败: %v", err)
	}
	user, err = handler.findLoginUser(legacy.QQ)
	if err != nil || user.ID != student.ID {
		t.Fatalf("真实学号优先结果 id=%d err=%v，期望 id=%d", user.ID, err, student.ID)
	}
}

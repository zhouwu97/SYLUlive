package tasks

import (
	"strings"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newLotteryTaskTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.LotteryEvent{},
		&models.LotteryParticipant{},
		&models.Announcement{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

func TestExecuteDrawCreatesAnnouncementWhenSystemUserDoesNotExist(t *testing.T) {
	db := newLotteryTaskTestDB(t)

	user := models.User{
		StudentID:    "winner-001",
		PasswordHash: "test",
		Nickname:     "中奖同学",
		Exp:          10,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}

	event := models.LotteryEvent{
		Title:       "补偿抽奖",
		Description: "图片事故补偿",
		PrizeName:   "奶茶券",
		DrawTime:    time.Now().Add(-time.Minute),
		Status:      0,
	}
	if err := db.Create(&event).Error; err != nil {
		t.Fatalf("create event: %v", err)
	}

	participant := models.LotteryParticipant{
		LotteryID: event.ID,
		UserID:    user.ID,
		Weight:    1,
	}
	if err := db.Create(&participant).Error; err != nil {
		t.Fatalf("create participant: %v", err)
	}

	if err := ExecuteDraw(db, event.ID); err != nil {
		t.Fatalf("execute draw: %v", err)
	}

	var updated models.LotteryEvent
	if err := db.First(&updated, event.ID).Error; err != nil {
		t.Fatalf("load event: %v", err)
	}
	if updated.Status != 1 {
		t.Fatalf("expected event drawn, got status %d", updated.Status)
	}
	if updated.WinnerID == nil || *updated.WinnerID != user.ID {
		t.Fatalf("expected winner %d, got %v", user.ID, updated.WinnerID)
	}

	var announcement models.Announcement
	if err := db.First(&announcement).Error; err != nil {
		t.Fatalf("load announcement: %v", err)
	}
	if !strings.Contains(announcement.Title, event.Title) {
		t.Fatalf("announcement title %q does not mention event %q", announcement.Title, event.Title)
	}
	if !strings.Contains(announcement.Content, user.Nickname) {
		t.Fatalf("announcement content %q does not mention winner %q", announcement.Content, user.Nickname)
	}
	if !announcement.IsPinned {
		t.Fatal("lottery result announcement should be pinned so it is visible in active announcements")
	}

	var systemUser models.User
	if err := db.Where("student_id = ?", "system_auto").First(&systemUser).Error; err != nil {
		t.Fatalf("load system user: %v", err)
	}
	if systemUser.PasswordHash == "" {
		t.Fatal("system user should have a password hash placeholder")
	}
}

func TestCheckAndDrawLotteriesPublishesAnnouncementForDueEvent(t *testing.T) {
	db := newLotteryTaskTestDB(t)

	user := models.User{
		StudentID:    "due-winner-001",
		PasswordHash: "test",
		Nickname:     "到点中奖者",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}

	event := models.LotteryEvent{
		Title:       "到点开奖活动",
		Description: "测试自动开奖",
		PrizeName:   "补偿奖品",
		DrawTime:    time.Now().Add(-time.Second),
		Status:      0,
	}
	if err := db.Create(&event).Error; err != nil {
		t.Fatalf("create event: %v", err)
	}
	if err := db.Create(&models.LotteryParticipant{
		LotteryID: event.ID,
		UserID:    user.ID,
		Weight:    1,
	}).Error; err != nil {
		t.Fatalf("create participant: %v", err)
	}

	checkAndDrawLotteries(db)

	var updated models.LotteryEvent
	if err := db.First(&updated, event.ID).Error; err != nil {
		t.Fatalf("load event: %v", err)
	}
	if updated.Status != 1 {
		t.Fatalf("expected due event drawn, got status %d", updated.Status)
	}

	var announcement models.Announcement
	if err := db.First(&announcement).Error; err != nil {
		t.Fatalf("load announcement: %v", err)
	}
	if !announcement.IsPinned {
		t.Fatal("expected automatic draw to publish a pinned announcement")
	}
}

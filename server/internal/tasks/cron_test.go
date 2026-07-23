package tasks

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

type examPaperStorageJobProcessorStub struct {
	called chan int
}

func (s *examPaperStorageJobProcessorStub) ProcessDue(_ context.Context, limit int) (services.ExamPaperStorageJobProcessReport, error) {
	s.called <- limit
	return services.ExamPaperStorageJobProcessReport{Processed: 2, Completed: 2}, nil
}

type examPaperStorageMaintenanceStub struct {
	called chan context.Context
}

type eduCredentialCleanupJobProcessorStub struct {
	called chan int
}

func (s *eduCredentialCleanupJobProcessorStub) ProcessDue(_ context.Context, limit int) (services.EduCredentialCleanupJobProcessReport, error) {
	s.called <- limit
	return services.EduCredentialCleanupJobProcessReport{Processed: 1, Completed: 1}, nil
}

type eduBindingRecoveryProcessorStub struct {
	called chan int
}

func (s *eduBindingRecoveryProcessorStub) ProcessDue(_ context.Context, limit int) (services.EduBindingRecoveryReport, error) {
	s.called <- limit
	return services.EduBindingRecoveryReport{Processed: 1, Completed: 1}, nil
}

func (s *examPaperStorageMaintenanceStub) Run(ctx context.Context) (services.ExamPaperStorageMaintenanceReport, error) {
	s.called <- ctx
	return services.ExamPaperStorageMaintenanceReport{Referenced: 3}, nil
}

func TestStartExamPaperStorageCronRunsJobsAndMaintenanceImmediately(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	jobs := &examPaperStorageJobProcessorStub{called: make(chan int, 1)}
	maintenance := &examPaperStorageMaintenanceStub{called: make(chan context.Context, 1)}

	cron := StartExamPaperStorageCron(ctx, jobs, maintenance)

	select {
	case limit := <-jobs.called:
		if limit != 50 {
			t.Fatalf("后台任务批量大小错误: %d", limit)
		}
	case <-time.After(time.Second):
		t.Fatal("后台任务未在启动后立即消费 outbox")
	}
	select {
	case maintenanceCtx := <-maintenance.called:
		deadline, ok := maintenanceCtx.Deadline()
		if !ok {
			t.Fatal("完整性维护每轮必须设置截止时间")
		}
		remaining := time.Until(deadline)
		if remaining <= 29*time.Minute || remaining > examPaperStorageMaintenanceTimeout {
			t.Fatalf("完整性维护截止时间错误: %v", remaining)
		}
		select {
		case <-maintenanceCtx.Done():
		case <-time.After(time.Second):
			t.Fatal("维护返回后应释放子 context")
		}
	case <-time.After(time.Second):
		t.Fatal("后台任务未在启动后立即执行完整性维护")
	}
	cancel()
	done := make(chan struct{})
	go func() {
		cron.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("取消后存储后台任务未退出")
	}
	if len(jobs.called) != 0 || len(maintenance.called) != 0 {
		t.Fatal("取消后存储后台任务发生重入")
	}
}

func TestStartEduCredentialCleanupCronRunsJobsImmediately(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	jobs := &eduCredentialCleanupJobProcessorStub{called: make(chan int, 1)}
	cron := StartEduCredentialCleanupCron(ctx, jobs)

	select {
	case limit := <-jobs.called:
		if limit != 50 {
			t.Fatalf("后台任务批量大小错误: %d", limit)
		}
	case <-time.After(time.Second):
		t.Fatal("后台任务未在启动后立即消费教务凭证清理任务")
	}
	cancel()
	done := make(chan struct{})
	go func() {
		cron.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("取消后教务凭证清理任务未退出")
	}
}

func TestStartEduBindingRecoveryCronRunsJobsImmediately(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	recovery := &eduBindingRecoveryProcessorStub{called: make(chan int, 1)}
	cron := StartEduBindingRecoveryCron(ctx, recovery)

	select {
	case limit := <-recovery.called:
		if limit != 50 {
			t.Fatalf("后台恢复批量大小错误: %d", limit)
		}
	case <-time.After(time.Second):
		t.Fatal("后台恢复任务未在启动后立即执行")
	}
	cancel()
	done := make(chan struct{})
	go func() {
		cron.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("取消后教务绑定恢复任务未退出")
	}
}

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

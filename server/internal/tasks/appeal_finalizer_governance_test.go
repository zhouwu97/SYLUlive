package tasks

import (
	"fmt"
	"testing"
	"time"

	"shenliyuan/internal/models"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func newAppealFinalizerGovernanceDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:%s?mode=memory&cache=shared", t.Name())), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.Post{}, &models.Report{}, &models.Appeal{}, &models.AppealVote{}, &models.Notification{}); err != nil {
		t.Fatal(err)
	}
	return db
}

func TestFinalizeExpiredAppealRequiresFiveVotes(t *testing.T) {
	db := newAppealFinalizerGovernanceDB(t)
	deadline := time.Now().Add(-time.Minute)
	db.Create(&models.Post{ID: 1, AuthorID: 1, BoardID: models.BoardShuitie, Status: models.PostStatusDeleted})
	db.Create(&models.Appeal{ID: 1, PostID: 1, AppellantID: 1, AdminID: 2, Status: models.AppealStatusPending, RequiredVotes: 5, VotingDeadline: &deadline})
	db.Create(&models.AppealVote{AppealID: 1, VoterID: 3, Vote: "support"})

	if _, err := FinalizeExpiredAppeals(db, time.Now()); err != nil {
		t.Fatal(err)
	}
	var appeal models.Appeal
	if err := db.First(&appeal, 1).Error; err != nil {
		t.Fatal(err)
	}
	if appeal.Status != models.AppealStatusReview || appeal.ClosedAt != nil {
		t.Fatalf("票数不足必须保持 review_required 且未结案: status=%s closed_at=%v", appeal.Status, appeal.ClosedAt)
	}
}

func TestFinalizeExpiredAppealTieNeedsManualReview(t *testing.T) {
	db := newAppealFinalizerGovernanceDB(t)
	deadline := time.Now().Add(-time.Minute)
	db.Create(&models.Post{ID: 1, AuthorID: 1, BoardID: models.BoardShuitie, Status: models.PostStatusDeleted})
	db.Create(&models.Appeal{ID: 1, PostID: 1, AppellantID: 1, AdminID: 2, Status: models.AppealStatusPending, RequiredVotes: 5, VotingDeadline: &deadline})
	for i, vote := range []string{"support", "oppose", "support", "oppose", "support", "oppose"} {
		db.Create(&models.AppealVote{AppealID: 1, VoterID: uint(i + 3), Vote: vote})
	}
	if _, err := FinalizeExpiredAppeals(db, time.Now()); err != nil {
		t.Fatal(err)
	}
	var appeal models.Appeal
	db.First(&appeal, 1)
	if appeal.Status != models.AppealStatusReview || appeal.ClosedAt != nil {
		t.Fatalf("平票必须转人工复核: status=%s closed_at=%v", appeal.Status, appeal.ClosedAt)
	}
}

func TestFinalizeExpiredAppealPassRollsBackReportCountAndStatus(t *testing.T) {
	db := newAppealFinalizerGovernanceDB(t)
	deadline := time.Now().Add(-time.Minute)
	db.Create(&models.User{ID: 1, ReportCount: 2})
	db.Create(&models.User{ID: 2})
	db.Create(&models.Post{ID: 1, AuthorID: 1, BoardID: models.BoardShuitie, Status: models.PostStatusDeleted})
	db.Create(&models.Report{ID: 9, TargetType: "post", TargetID: 1, TargetAuthorID: uintPtr(1), Status: models.ReportStatusHandled})
	db.Create(&models.Appeal{ID: 1, ReportID: uintPtr(9), PostID: 1, AppellantID: 1, AdminID: 2, Status: models.AppealStatusPending, RequiredVotes: 5, VotingDeadline: &deadline, OriginalPostStatus: models.PostStatusNormal})
	for i := 0; i < 5; i++ {
		db.Create(&models.AppealVote{AppealID: 1, VoterID: uint(i + 3), Vote: "support"})
	}
	if _, err := FinalizeExpiredAppeals(db, time.Now()); err != nil {
		t.Fatal(err)
	}
	var post models.Post
	var report models.Report
	var user models.User
	db.First(&post, 1)
	db.First(&report, 9)
	db.First(&user, 1)
	if post.Status != models.PostStatusNormal || report.Status != models.ReportStatusOverturned || user.ReportCount != 1 {
		t.Fatalf("申诉通过未完整回滚: post=%s report=%s count=%d", post.Status, report.Status, user.ReportCount)
	}
}

func uintPtr(value uint) *uint { return &value }

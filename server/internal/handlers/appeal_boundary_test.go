package handlers

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func TestAdminResolveReviewRejectsOriginalHandler(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:appeal_boundary?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.Post{}, &models.Appeal{}, &models.AppealVote{}); err != nil {
		t.Fatal(err)
	}
	db.Create(&models.Appeal{ID: 1, PostID: 1, AppellantID: 1, AdminID: 2, Status: models.AppealStatusReview})

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/api/admin/appeals/1/review", strings.NewReader(`{"decision":"reject","reason":"复核"}`))
	context.Params = gin.Params{{Key: "id", Value: "1"}}
	context.Set("user_id", uint(2))
	handler := NewAppealHandler(db)
	handler.AdminResolveReview(context)

	if recorder.Code != http.StatusForbidden {
		t.Fatalf("原处理管理员应被禁止自审，得到 %d: %s", recorder.Code, recorder.Body.String())
	}
}

func TestAppealResultNeedsIrreversibleMajorityBeforeDeadline(t *testing.T) {
	if appealResultIrreversible(3, 2, 7) {
		t.Fatal("3:2 且仍有两名未投票陪审员时不能提前结案")
	}
	if !appealResultIrreversible(4, 1, 7) {
		t.Fatal("4:1 且剩余两票无法逆转时应允许提前结案")
	}
	if !appealResultIrreversible(3, 3, 6) {
		t.Fatal("所有有效陪审员投完形成 3:3 平票时应立即转人工复核")
	}
}

func TestReviewRequiredNotifiesIndependentReviewer(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:appeal_review_notification?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.Notification{}); err != nil {
		t.Fatal(err)
	}
	db.Create(&models.User{ID: 2, Role: models.RoleAdmin})
	db.Create(&models.User{ID: 3, Role: models.RoleAdmin})

	notifyIndependentReviewers(db, 9, 2)
	var reviewerNotification models.Notification
	if err := db.Where("user_id = ? AND type = ?", 3, models.NotificationTypeAppealReviewRequired).First(&reviewerNotification).Error; err != nil {
		t.Fatal("独立管理员应收到人工复核待办通知:", err)
	}
	if !strings.Contains(reviewerNotification.Content, "待人工复核") {
		t.Fatalf("通知文案未说明人工复核待办: %s", reviewerNotification.Content)
	}
	var originalNotification models.Notification
	if err := db.Where("user_id = ?", 2).First(&originalNotification).Error; err != nil {
		t.Fatal("原治理管理员应收到转交提示:", err)
	}
	if strings.Contains(originalNotification.Content, "请及时处理") {
		t.Fatalf("原治理管理员不应收到可直接处理的待办文案: %s", originalNotification.Content)
	}
}

func TestVoteRejectsAfterDeadline(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:appeal_vote_deadline?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.Post{}, &models.Appeal{}, &models.AppealVote{}); err != nil {
		t.Fatal(err)
	}

	expiredDeadline := time.Now().Add(-10 * time.Minute)
	db.Create(&models.Appeal{
		ID:             10,
		PostID:         1,
		AppellantID:    1,
		AdminID:        2,
		Status:         models.AppealStatusPending,
		RequiredVotes:  5,
		VotingDeadline: &expiredDeadline,
	})
	db.Create(&models.AppealVote{
		AppealID: 10,
		VoterID:  5,
	})

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/api/appeals/10/vote", strings.NewReader(`{"vote":"support","comment":"迟到票"}`))
	context.Request.Header.Set("Content-Type", "application/json")
	context.Params = gin.Params{{Key: "id", Value: "10"}}
	context.Set("user_id", uint(5))

	handler := NewAppealHandler(db)
	handler.Vote(context)

	if recorder.Code != http.StatusConflict {
		t.Fatalf("投票截止后应返回 409 Conflict，得到 %d: %s", recorder.Code, recorder.Body.String())
	}
	if !strings.Contains(recorder.Body.String(), "voting_closed") {
		t.Fatalf("响应中应包含 voting_closed 错误码，得到: %s", recorder.Body.String())
	}
}

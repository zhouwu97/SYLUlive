package handlers

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

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
}

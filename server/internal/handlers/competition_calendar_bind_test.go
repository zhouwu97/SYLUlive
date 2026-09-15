package handlers

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/models"
)

// 请求体畸形时不得改动状态，也不得返回成功。
//
// PinCalendarItem 此前忽略 ShouldBindJSON 的错误：body 畸形时 input.IsPinned
// 保持零值 false，用户以为在置顶，实际把已有置顶静默取消了，接口还返回 200。
func TestPinCalendarItemRejectsMalformedBodyWithoutChangingState(t *testing.T) {
	db := newCompetitionTestDB(t)
	user := models.User{StudentID: "20260077", PasswordHash: "x", Nickname: "置顶用户"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	item := models.UserCompetitionCalendarItem{
		CalendarID: 1,
		UserID:     user.ID,
		Title:      "已置顶赛事",
		IsPinned:   true,
	}
	if err := db.Create(&item).Error; err != nil {
		t.Fatalf("create calendar item: %v", err)
	}

	handler := NewCompetitionHandler(db)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"is_pinned": `))
	context.Request.Header.Set("Content-Type", "application/json")
	context.Params = gin.Params{{Key: "id", Value: fmt.Sprint(item.ID)}}
	context.Set("user_id", user.ID)

	handler.PinCalendarItem(context)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("畸形 body 应返回 400，实际 %d body=%s", recorder.Code, recorder.Body.String())
	}
	var reloaded models.UserCompetitionCalendarItem
	if err := db.First(&reloaded, item.ID).Error; err != nil {
		t.Fatalf("reload item: %v", err)
	}
	if !reloaded.IsPinned {
		t.Fatal("请求体畸形时不应把已有置顶静默取消")
	}
}

func TestPinCalendarItemAppliesValidBody(t *testing.T) {
	db := newCompetitionTestDB(t)
	user := models.User{StudentID: "20260078", PasswordHash: "x", Nickname: "置顶用户"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	item := models.UserCompetitionCalendarItem{
		CalendarID: 1,
		UserID:     user.ID,
		Title:      "未置顶赛事",
	}
	if err := db.Create(&item).Error; err != nil {
		t.Fatalf("create calendar item: %v", err)
	}

	handler := NewCompetitionHandler(db)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"is_pinned": true}`))
	context.Request.Header.Set("Content-Type", "application/json")
	context.Params = gin.Params{{Key: "id", Value: fmt.Sprint(item.ID)}}
	context.Set("user_id", user.ID)

	handler.PinCalendarItem(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("正常 body 应返回 200，实际 %d body=%s", recorder.Code, recorder.Body.String())
	}
	var reloaded models.UserCompetitionCalendarItem
	if err := db.First(&reloaded, item.ID).Error; err != nil {
		t.Fatalf("reload item: %v", err)
	}
	if !reloaded.IsPinned {
		t.Fatal("正常请求应把项目置顶")
	}
}

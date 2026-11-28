package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newLotteryHandlerTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.WaterTeamRecruitment{}, &models.WaterTeamApplication{},
		&models.User{},
		&models.LotteryEvent{},
		&models.LotteryParticipant{},
		&models.Announcement{},
		&models.File{},
		&models.FileUploadGrant{},
		&models.ImageVariant{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

func TestLotteryJoinPostgresWaitsForCancellation(t *testing.T) {
	db := integrationLockDB(t)
	require.NoError(t, db.AutoMigrate(&models.AcademicAccountConfig{}, &models.LotteryEvent{}, &models.LotteryParticipant{}))
	user := models.User{Nickname: "报名并发测试", PasswordHash: "synthetic", AccountStatus: "active"}
	require.NoError(t, db.Create(&user).Error)
	require.NoError(t, db.Create(&models.AcademicAccountConfig{UserID: user.ID, ProviderID: models.AcademicProviderUndergraduate, StudentID: "synthetic-lottery", State: "active", Revision: 1}).Error)
	event := models.LotteryEvent{Title: "取消中的活动", PrizeName: "合成奖品", DrawTime: time.Now().Add(time.Hour)}
	require.NoError(t, db.Create(&event).Error)
	cancellation := db.Begin()
	require.NoError(t, cancellation.Error)
	t.Cleanup(func() { _ = cancellation.Rollback().Error })
	require.NoError(t, cancellation.Model(&event).Update("status", models.LotteryStatusCancelled).Error)
	read := make(chan struct{}, 1)
	require.NoError(t, db.Callback().Query().After("gorm:query").Register("test:lottery-read", func(tx *gorm.DB) {
		if tx.Statement.Table == "lottery_events" {
			select {
			case read <- struct{}{}:
			default:
			}
		}
	}))
	t.Cleanup(func() { _ = db.Callback().Query().Remove("test:lottery-read") })
	result := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		r := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(r)
		c.Request = httptest.NewRequest(http.MethodPost, "/api/lottery/1/join", nil)
		c.Params = gin.Params{{Key: "id", Value: strconv.FormatUint(uint64(event.ID), 10)}}
		c.Set("user_id", user.ID)
		NewLotteryHandler(db).Join(c)
		result <- r
	}()
	// 正确的行锁会等待取消提交；旧的无锁读取会立即返回旧状态。
	select {
	case <-read:
	case <-time.After(200 * time.Millisecond):
	}
	require.NoError(t, cancellation.Commit().Error)
	select {
	case r := <-result:
		require.Equal(t, http.StatusBadRequest, r.Code, r.Body.String())
	case <-time.After(3 * time.Second):
		t.Fatal("报名未在取消提交后完成")
	}
	var count int64
	require.NoError(t, db.Model(&models.LotteryParticipant{}).Where("lottery_id = ?", event.ID).Count(&count).Error)
	require.Zero(t, count)
}

func TestLotteryConcurrentPublishingPostgres(t *testing.T) {
	db := integrationLockDB(t)
	require.NoError(t, db.AutoMigrate(&models.LotteryEvent{}, &models.LotteryParticipant{}))
	ready, release := make(chan struct{}, 2), make(chan struct{})
	require.NoError(t, db.Callback().Create().Before("gorm:create").Register("test:lottery-publish", func(tx *gorm.DB) {
		if tx.Statement.Table == "lottery_events" {
			ready <- struct{}{}
			select {
			case <-release:
			case <-time.After(3 * time.Second):
				tx.AddError(gorm.ErrInvalidTransaction)
			}
		}
	}))
	t.Cleanup(func() { _ = db.Callback().Create().Remove("test:lottery-publish") })
	results := make(chan *httptest.ResponseRecorder, 2)
	for _, title := range []string{"并发活动一", "并发活动二"} {
		go func(title string) {
			results <- performJSONRequest(t, NewSuperAdminHandler(db).CreateLotteryEvent, http.MethodPost, "/api/super/lottery", map[string]any{
				"title": title, "prize_name": "合成奖品", "draw_time": time.Now().Add(time.Hour).UTC().Format(time.RFC3339),
			})
		}(title)
	}
	select {
	case <-ready:
	case <-time.After(3 * time.Second):
		close(release)
		t.Fatal("发布未开始")
	}
	select {
	case <-ready:
	case <-time.After(200 * time.Millisecond):
	}
	close(release)
	for range 2 {
		select {
		case r := <-results:
			require.Equal(t, http.StatusCreated, r.Code, r.Body.String())
		case <-time.After(3 * time.Second):
			t.Fatal("并发发布未结束")
		}
	}
	var ongoing int64
	require.NoError(t, db.Model(&models.LotteryEvent{}).Where("status = ?", models.LotteryStatusOngoing).Count(&ongoing).Error)
	require.EqualValues(t, 1, ongoing)
}

func TestLotteryDrawRechecksRescheduledDeadlinePostgres(t *testing.T) {
	db := integrationLockDB(t)
	require.NoError(t, db.AutoMigrate(&models.LotteryEvent{}, &models.LotteryParticipant{}))
	event := models.LotteryEvent{Title: "改期活动", PrizeName: "合成奖品", DrawTime: time.Now().Add(-time.Hour)}
	require.NoError(t, db.Create(&event).Error)
	changed := false
	require.NoError(t, db.Callback().Query().After("gorm:query").Register("test:lottery-reschedule", func(tx *gorm.DB) {
		if tx.Statement.Table == "lottery_events" && !changed {
			changed = true
			require.NoError(t, db.Model(&event).Update("draw_time", time.Now().Add(time.Hour)).Error)
		}
	}))
	t.Cleanup(func() { _ = db.Callback().Query().Remove("test:lottery-reschedule") })
	r := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(r)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/admin/lottery/1/draw", nil)
	c.Params = gin.Params{{Key: "id", Value: strconv.FormatUint(uint64(event.ID), 10)}}
	NewLotteryHandler(db).Draw(c)
	require.Equal(t, http.StatusBadRequest, r.Code, r.Body.String())
	require.Contains(t, r.Body.String(), "lottery_not_ready")
	var saved models.LotteryEvent
	require.NoError(t, db.First(&saved, event.ID).Error)
	require.Equal(t, models.LotteryStatusOngoing, saved.Status)
	require.Nil(t, saved.DrawnAt)
}

func performJSONRequest(
	t *testing.T,
	handler gin.HandlerFunc,
	method string,
	path string,
	body map[string]any,
) *httptest.ResponseRecorder {
	t.Helper()
	payload, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(method, path, bytes.NewReader(payload))
	context.Request.Header.Set("Content-Type", "application/json")
	handler(context)
	return recorder
}

func TestCreateLotteryEventPublishesNewCurrentEventAndClosesOldOne(t *testing.T) {
	db := newLotteryHandlerTestDB(t)
	handler := NewSuperAdminHandler(db)

	oldEvent := models.LotteryEvent{
		Title:       "旧活动",
		Description: "旧说明",
		PrizeName:   "旧奖品",
		DrawTime:    time.Now().Add(time.Hour),
		Status:      0,
	}
	if err := db.Create(&oldEvent).Error; err != nil {
		t.Fatalf("create old event: %v", err)
	}

	drawTime := time.Now().Add(2 * time.Hour).UTC().Format(time.RFC3339)
	recorder := performJSONRequest(t, handler.CreateLotteryEvent, http.MethodPost, "/api/super/lottery", map[string]any{
		"title":       "图片事故补偿抽奖",
		"description": "感谢理解",
		"prize_name":  "奶茶券",
		"draw_time":   drawTime,
	})
	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", recorder.Code, recorder.Body.String())
	}

	var updatedOld models.LotteryEvent
	if err := db.First(&updatedOld, oldEvent.ID).Error; err != nil {
		t.Fatalf("load old event: %v", err)
	}
	if updatedOld.Status != models.LotteryStatusCancelled {
		t.Fatalf("expected old event closed, got status %d", updatedOld.Status)
	}

	var created models.LotteryEvent
	if err := db.Where("title = ?", "图片事故补偿抽奖").First(&created).Error; err != nil {
		t.Fatalf("load created event: %v", err)
	}
	if created.Status != 0 {
		t.Fatalf("expected new event ongoing, got status %d", created.Status)
	}
}

func TestCreateLotteryEventPrizeImage(t *testing.T) {
	cases := []struct {
		name       string
		prizeImage string
		wantCode   int
	}{
		{"本站上传图片并转为公开", "/uploads/2026/11/prize.png", http.StatusCreated},
		{"不传图片", "", http.StatusCreated},
		{"上传记录不存在", "/uploads/2026/11/missing.png", http.StatusBadRequest},
		{"外部链接", "https://example.com/a.png", http.StatusBadRequest},
		{"路径穿越", "/uploads/../config.yaml", http.StatusBadRequest},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			db := newLotteryHandlerTestDB(t)
			file := models.File{Hash: "h1", Path: "/uploads/2026/11/prize.png", Size: 1, MimeType: "image/png"}
			require.NoError(t, db.Create(&file).Error)

			recorder := performJSONRequest(t, NewSuperAdminHandler(db).CreateLotteryEvent, http.MethodPost, "/api/super/lottery", map[string]any{
				"title":       "期末冲刺",
				"prize_name":  "咖啡券",
				"prize_image": tc.prizeImage,
				"draw_time":   time.Now().Add(time.Hour).UTC().Format(time.RFC3339),
			})
			require.Equal(t, tc.wantCode, recorder.Code, recorder.Body.String())
			if tc.wantCode != http.StatusCreated {
				return
			}
			var created models.LotteryEvent
			require.NoError(t, db.First(&created).Error)
			require.Equal(t, tc.prizeImage, created.PrizeImage)
			require.NoError(t, db.First(&file, file.ID).Error)
			wantScope := models.FileAccessPrivate
			if tc.prizeImage != "" {
				wantScope = models.FileAccessPublic
			}
			require.Equal(t, wantScope, file.AccessScope)
		})
	}
}

func TestUpdateLotteryEventPrizeImage(t *testing.T) {
	const oldPath = "/uploads/2026/11/old.png"
	const newPath = "/uploads/2026/11/new.png"
	cases := []struct {
		name       string
		prizeImage any
		status     int
		zeroRows   bool
		wantCode   int
		wantPath   string
		wantOld    models.FileAccessScope
		wantNew    models.FileAccessScope
	}{
		{"替换", newPath, 0, false, http.StatusOK, newPath, models.FileAccessPrivate, models.FileAccessPublic},
		{"清空", "", 0, false, http.StatusOK, "", models.FileAccessPrivate, models.FileAccessPrivate},
		{"省略", nil, 0, false, http.StatusOK, oldPath, models.FileAccessPublic, models.FileAccessPrivate},
		{"图片不存在", "/uploads/2026/11/missing.png", 0, false, http.StatusBadRequest, oldPath, models.FileAccessPublic, models.FileAccessPrivate},
		{"活动已结束", newPath, models.LotteryStatusDrawn, false, http.StatusBadRequest, oldPath, models.FileAccessPublic, models.FileAccessPrivate},
		{"条件更新未影响任何行", newPath, 0, true, http.StatusBadRequest, oldPath, models.FileAccessPublic, models.FileAccessPrivate},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			db := newLotteryHandlerTestDB(t)
			handler := NewSuperAdminHandler(db)
			const operatorID uint = 42
			old := models.File{Hash: "old", Path: oldPath, MimeType: "image/png", UploaderID: operatorID, AccessScope: models.FileAccessPublic}
			next := models.File{Hash: "new", Path: newPath, MimeType: "image/png", UploaderID: operatorID}
			require.NoError(t, db.Create(&old).Error)
			require.NoError(t, db.Create(&next).Error)
			event := models.LotteryEvent{
				Title: "原活动", PrizeName: "奖品", PrizeImage: oldPath,
				DrawTime: time.Now().Add(time.Hour), Status: tc.status,
			}
			require.NoError(t, db.Create(&event).Error)
			if tc.zeroRows {
				// 在 SQLite 中模拟条件更新失败，覆盖事务内的零行分支。
				require.NoError(t, db.Exec(`CREATE TRIGGER lottery_update_no_rows
					BEFORE UPDATE ON lottery_events BEGIN SELECT RAISE(IGNORE); END`).Error)
			}
			payload := map[string]any{
				"title": "更新活动", "prize_name": "奖品",
				"draw_time": event.DrawTime.UTC().Format(time.RFC3339),
			}
			if tc.prizeImage != nil {
				payload["prize_image"] = tc.prizeImage
			}
			recorder := performJSONRequest(t, func(c *gin.Context) {
				c.Set("user_id", operatorID)
				c.Params = gin.Params{{Key: "id", Value: strconv.FormatUint(uint64(event.ID), 10)}}
				handler.UpdateLotteryEvent(c)
			}, http.MethodPut, "/api/super/lottery/1", payload)
			require.Equal(t, tc.wantCode, recorder.Code, recorder.Body.String())
			if tc.zeroRows || tc.status == models.LotteryStatusDrawn {
				require.Contains(t, recorder.Body.String(), "lottery_not_ongoing")
			}
			var saved models.LotteryEvent
			require.NoError(t, db.First(&saved, event.ID).Error)
			require.Equal(t, tc.wantPath, saved.PrizeImage)
			if tc.wantCode == http.StatusOK {
				require.Equal(t, "更新活动", saved.Title)
			} else {
				require.Equal(t, event.Title, saved.Title)
			}
			require.NoError(t, db.First(&old, old.ID).Error)
			require.NoError(t, db.First(&next, next.ID).Error)
			require.Equal(t, tc.wantOld, old.AccessScope)
			require.Equal(t, tc.wantNew, next.AccessScope)
		})
	}
}

func TestDeleteLotteryEventRemovesEventAndParticipants(t *testing.T) {
	db := newLotteryHandlerTestDB(t)
	handler := NewSuperAdminHandler(db)

	user := models.User{
		StudentID:    "delete-participant-001",
		PasswordHash: "test",
		Nickname:     "参与者",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}

	prizeImage := models.File{
		Hash: "deleted-prize", Path: "/uploads/2026/11/deleted.png",
		MimeType: "image/png", AccessScope: models.FileAccessPublic,
	}
	require.NoError(t, db.Create(&prizeImage).Error)
	event := models.LotteryEvent{
		Title:       "待删除抽奖",
		Description: "测试删除",
		PrizeName:   "奖品",
		PrizeImage:  prizeImage.Path,
		DrawTime:    time.Now().Add(time.Hour),
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

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodDelete, "/api/super/lottery/1", nil)
	context.Params = gin.Params{{Key: "id", Value: "1"}}
	handler.DeleteLotteryEvent(context)

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
	}

	var eventCount int64
	if err := db.Model(&models.LotteryEvent{}).Where("id = ?", event.ID).Count(&eventCount).Error; err != nil {
		t.Fatalf("count events: %v", err)
	}
	if eventCount != 0 {
		t.Fatalf("expected event deleted, count=%d", eventCount)
	}

	var participantCount int64
	if err := db.Model(&models.LotteryParticipant{}).Where("lottery_id = ?", event.ID).Count(&participantCount).Error; err != nil {
		t.Fatalf("count participants: %v", err)
	}
	if participantCount != 0 {
		t.Fatalf("expected participants deleted, count=%d", participantCount)
	}
	require.NoError(t, db.First(&prizeImage, prizeImage.ID).Error)
	require.Equal(t, models.FileAccessPrivate, prizeImage.AccessScope)
}

func TestGetLotteryParticipantsOrdersWinnerBeforePagination(t *testing.T) {
	cases := []struct {
		name   string
		winner bool
		want   []int
	}{
		{"最早报名者中奖", true, []int{0, 2}},
		{"没有中奖者", false, []int{2, 1}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			db := newLotteryHandlerTestDB(t)
			now := time.Now()
			users := []models.User{
				{StudentID: "winner-first", PasswordHash: "test", Nickname: "最早报名"},
				{StudentID: "winner-middle", PasswordHash: "test", Nickname: "中间报名"},
				{StudentID: "winner-last", PasswordHash: "test", Nickname: "最后报名"},
			}
			require.NoError(t, db.Create(&users).Error)
			event := models.LotteryEvent{
				Title: "活动", PrizeName: "奖品", DrawTime: now, Status: models.LotteryStatusNoWinner,
			}
			if tc.winner {
				event.Status, event.WinnerID = models.LotteryStatusDrawn, &users[0].ID
			}
			require.NoError(t, db.Create(&event).Error)
			for i, user := range users {
				require.NoError(t, db.Create(&models.LotteryParticipant{
					LotteryID: event.ID, UserID: user.ID, CreatedAt: now.Add(time.Duration(i) * time.Minute),
				}).Error)
			}
			recorder := performJSONRequest(t, NewSuperAdminHandler(db).GetLotteryParticipants,
				http.MethodGet, "/api/super/lottery/participants?page=1&page_size=2", nil)
			require.Equal(t, http.StatusOK, recorder.Code, recorder.Body.String())
			var response struct {
				Participants []LotteryParticipantResponse `json:"participants"`
				Total        int                          `json:"total"`
			}
			require.NoError(t, json.Unmarshal(recorder.Body.Bytes(), &response))
			require.Equal(t, len(users), response.Total)
			require.Len(t, response.Participants, len(tc.want))
			for i, index := range tc.want {
				require.Equal(t, users[index].ID, response.Participants[i].UserID)
			}
		})
	}
}

func TestJoinLotteryRejectsAfterDrawTime(t *testing.T) {
	db := newLotteryHandlerTestDB(t)
	handler := NewLotteryHandler(db)

	user := models.User{
		StudentID:    "joiner-001",
		PasswordHash: "test",
		Nickname:     "参与者",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	event := models.LotteryEvent{
		Title:       "已到点活动",
		Description: "测试",
		PrizeName:   "奖品",
		DrawTime:    time.Now().Add(-time.Second),
		Status:      0,
	}
	if err := db.Create(&event).Error; err != nil {
		t.Fatalf("create event: %v", err)
	}

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/api/lottery/1/join", nil)
	context.Params = gin.Params{{Key: "id", Value: "1"}}
	context.Set("user_id", user.ID)
	handler.Join(context)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", recorder.Code, recorder.Body.String())
	}
}

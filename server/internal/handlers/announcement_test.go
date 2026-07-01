package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newAnnouncementTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.Announcement{},
		&models.AnnouncementRead{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

func createTestUser(t *testing.T, db *gorm.DB, id uint, createdAt time.Time) models.User {
	t.Helper()
	user := models.User{
		ID:           id,
		StudentID:    fmt.Sprintf("student-%d", id),
		PasswordHash: "test",
		Nickname:     fmt.Sprintf("user-%d", id),
		CreatedAt:    createdAt,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	return user
}

func createTestAnnouncement(t *testing.T, db *gorm.DB, a models.Announcement) models.Announcement {
	t.Helper()
	if a.Status == "" {
		a.Status = "published"
	}
	if a.DisplayMode == "" {
		a.DisplayMode = "center"
	}
	if a.Priority == "" {
		a.Priority = "normal"
	}
	if err := db.Create(&a).Error; err != nil {
		t.Fatalf("create announcement: %v", err)
	}
	return a
}

func createTestAnnouncementRead(t *testing.T, db *gorm.DB, userID, announcementID uint) {
	t.Helper()
	r := models.AnnouncementRead{
		UserID:         userID,
		AnnouncementID: announcementID,
		ReadAt:         time.Now(),
	}
	if err := db.Where("user_id = ? AND announcement_id = ?", userID, announcementID).
		FirstOrCreate(&r).Error; err != nil {
		t.Fatalf("create announcement_read: %v", err)
	}
}

func setGinContextUserID(c *gin.Context, uid uint) {
	c.Set("user_id", uid)
}

// ─── GetUnread Tests ────────────────────────────────────────────

func TestGetUnread_FiltersByUserCreatedAt(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	// User registered 7 days ago
	user := createTestUser(t, db, 1, time.Now().Add(-7*24*time.Hour))
	// Announcement created 14 days ago (before user)
	old := createTestAnnouncement(t, db, models.Announcement{
		ID:        1,
		Title:     "old announcement",
		Content:   "old",
		CreatedBy: 1,
		CreatedAt: time.Now().Add(-14 * 24 * time.Hour),
	})

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/unread", nil)
	setGinContextUserID(c, user.ID)

	handler.GetUnread(c)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	var result []models.Announcement
	json.Unmarshal(w.Body.Bytes(), &result)
	if len(result) != 0 {
		t.Errorf("new user should not see old announcement (created before registration), got %d", len(result))
	}
	_ = old
}

func TestGetUnread_IncludeNewUsers_True(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	// User registered 1 day ago
	user := createTestUser(t, db, 2, time.Now().Add(-24*time.Hour))
	// Announcement created 14 days ago but include_new_users=true
	createTestAnnouncement(t, db, models.Announcement{
		ID:              2,
		Title:           "important old announcement",
		Content:         "important",
		CreatedBy:       1,
		IncludeNewUsers: true,
		CreatedAt:       time.Now().Add(-14 * 24 * time.Hour),
	})

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/unread", nil)
	setGinContextUserID(c, user.ID)

	handler.GetUnread(c)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	var result []models.Announcement
	json.Unmarshal(w.Body.Bytes(), &result)
	if len(result) != 1 {
		t.Errorf("include_new_users=true should make announcement visible to new user, got %d", len(result))
	}
}

func TestGetUnread_FiltersDraft(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	user := createTestUser(t, db, 3, time.Now().Add(-30*24*time.Hour))
	createTestAnnouncement(t, db, models.Announcement{
		ID:        3,
		Title:     "draft",
		Content:   "draft content",
		Status:    "draft",
		CreatedBy: 1,
		CreatedAt: time.Now().Add(-1 * time.Hour),
	})

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/unread", nil)
	setGinContextUserID(c, user.ID)

	handler.GetUnread(c)

	var result []models.Announcement
	json.Unmarshal(w.Body.Bytes(), &result)
	if len(result) != 0 {
		t.Errorf("draft announcement should not appear in unread, got %d", len(result))
	}
}

func TestGetUnread_FiltersArchived(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	user := createTestUser(t, db, 4, time.Now().Add(-30*24*time.Hour))
	createTestAnnouncement(t, db, models.Announcement{
		ID:        4,
		Title:     "archived",
		Content:   "archived content",
		Status:    "archived",
		CreatedBy: 1,
		CreatedAt: time.Now().Add(-1 * time.Hour),
	})

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/unread", nil)
	setGinContextUserID(c, user.ID)

	handler.GetUnread(c)

	var result []models.Announcement
	json.Unmarshal(w.Body.Bytes(), &result)
	if len(result) != 0 {
		t.Errorf("archived announcement should not appear in unread, got %d", len(result))
	}
}

func TestGetUnread_FiltersFuturePublishAt(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	user := createTestUser(t, db, 5, time.Now().Add(-30*24*time.Hour))
	future := time.Now().Add(24 * time.Hour)
	createTestAnnouncement(t, db, models.Announcement{
		ID:        5,
		Title:     "future",
		Content:   "future content",
		CreatedBy: 1,
		PublishAt: &future,
		CreatedAt: time.Now().Add(-1 * time.Hour),
	})

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/unread", nil)
	setGinContextUserID(c, user.ID)

	handler.GetUnread(c)

	var result []models.Announcement
	json.Unmarshal(w.Body.Bytes(), &result)
	if len(result) != 0 {
		t.Errorf("future-scheduled announcement should not appear in unread, got %d", len(result))
	}
}

func TestGetUnread_FiltersExpired(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	user := createTestUser(t, db, 6, time.Now().Add(-30*24*time.Hour))
	expired := time.Now().Add(-1 * time.Hour)
	createTestAnnouncement(t, db, models.Announcement{
		ID:        6,
		Title:     "expired",
		Content:   "expired content",
		CreatedBy: 1,
		ExpiresAt: &expired,
		CreatedAt: time.Now().Add(-7 * 24 * time.Hour),
	})

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/unread", nil)
	setGinContextUserID(c, user.ID)

	handler.GetUnread(c)

	var result []models.Announcement
	json.Unmarshal(w.Body.Bytes(), &result)
	if len(result) != 0 {
		t.Errorf("expired announcement should not appear in unread, got %d", len(result))
	}
}

func TestGetUnread_BoundarySameCreatedAt(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	now := time.Now().Truncate(time.Second)
	user := createTestUser(t, db, 7, now)
	createTestAnnouncement(t, db, models.Announcement{
		ID:        7,
		Title:     "same time",
		Content:   "same time content",
		CreatedBy: 1,
		CreatedAt: now,
	})

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/unread", nil)
	setGinContextUserID(c, user.ID)

	handler.GetUnread(c)

	var result []models.Announcement
	json.Unmarshal(w.Body.Bytes(), &result)
	if len(result) != 1 {
		t.Errorf("announcement with same created_at as user should be visible (>=), got %d", len(result))
	}
}

func TestGetUnread_BoundaryMillisecondDiff(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	// User registered slightly after announcement — still should see it (>=)
	userTime := time.Now().Add(1 * time.Millisecond)
	user := createTestUser(t, db, 8, userTime)
	createTestAnnouncement(t, db, models.Announcement{
		ID:        8,
		Title:     "slightly before",
		Content:   "content",
		CreatedBy: 1,
		CreatedAt: time.Now(),
	})

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/unread", nil)
	setGinContextUserID(c, user.ID)

	handler.GetUnread(c)

	var result []models.Announcement
	json.Unmarshal(w.Body.Bytes(), &result)
	// Announcement created_at is BEFORE user created_at, so it should NOT be visible
	// unless include_new_users is true (which it isn't)
	if len(result) != 0 {
		t.Errorf("announcement created before user registration should NOT be visible, got %d", len(result))
	}
}

func TestGetUnread_ExcludesAlreadyRead(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	user := createTestUser(t, db, 9, time.Now().Add(-30*24*time.Hour))
	ann := createTestAnnouncement(t, db, models.Announcement{
		ID:        9,
		Title:     "already read",
		Content:   "content",
		CreatedBy: 1,
		CreatedAt: time.Now().Add(-1 * time.Hour),
	})
	createTestAnnouncementRead(t, db, user.ID, ann.ID)

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/unread", nil)
	setGinContextUserID(c, user.ID)

	handler.GetUnread(c)

	var result []models.Announcement
	json.Unmarshal(w.Body.Bytes(), &result)
	if len(result) != 0 {
		t.Errorf("already-read announcement should not appear in unread, got %d", len(result))
	}
}

// ─── GetUnreadCount Tests ───────────────────────────────────────

func TestGetUnreadCount_MatchesList(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	user := createTestUser(t, db, 10, time.Now().Add(-30*24*time.Hour))
	// Create 3 visible announcements
	for i := 1; i <= 3; i++ {
		createTestAnnouncement(t, db, models.Announcement{
			ID:        uint(10 + i),
			Title:     fmt.Sprintf("announcement %d", i),
			Content:   "content",
			CreatedBy: 1,
			CreatedAt: time.Now().Add(-time.Duration(i) * time.Hour),
		})
	}

	gin.SetMode(gin.TestMode)

	// Check count
	wc := httptest.NewRecorder()
	cc, _ := gin.CreateTestContext(wc)
	cc.Request = httptest.NewRequest(http.MethodGet, "/unread-count", nil)
	setGinContextUserID(cc, user.ID)
	handler.GetUnreadCount(cc)

	var countResult map[string]interface{}
	json.Unmarshal(wc.Body.Bytes(), &countResult)
	count := int64(countResult["count"].(float64))
	if count != 3 {
		t.Errorf("unread-count expected 3, got %d", count)
	}

	// Check list
	wl := httptest.NewRecorder()
	cl, _ := gin.CreateTestContext(wl)
	cl.Request = httptest.NewRequest(http.MethodGet, "/unread", nil)
	setGinContextUserID(cl, user.ID)
	handler.GetUnread(cl)

	var listResult []models.Announcement
	json.Unmarshal(wl.Body.Bytes(), &listResult)
	if int64(len(listResult)) != count {
		t.Errorf("unread count (%d) does not match list length (%d)", count, len(listResult))
	}
}

func TestGetUnreadCount_HasUrgent(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	user := createTestUser(t, db, 11, time.Now().Add(-30*24*time.Hour))
	createTestAnnouncement(t, db, models.Announcement{
		ID:        14,
		Title:     "urgent announcement",
		Content:   "urgent content",
		Priority:  "urgent",
		CreatedBy: 1,
		CreatedAt: time.Now().Add(-1 * time.Hour),
	})

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/unread-count", nil)
	setGinContextUserID(c, user.ID)

	handler.GetUnreadCount(c)

	var result map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &result)
	if result["has_urgent"] != true {
		t.Errorf("has_urgent should be true when unread urgent announcement exists")
	}
}

// ─── MarkAllRead Tests ──────────────────────────────────────────

func TestMarkAllRead_Idempotent(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	user := createTestUser(t, db, 12, time.Now().Add(-30*24*time.Hour))
	ann := createTestAnnouncement(t, db, models.Announcement{
		ID:        15,
		Title:     "test",
		Content:   "test",
		CreatedBy: 1,
		CreatedAt: time.Now(),
	})

	body := `{"announcement_ids": [15]}`

	// First call
	gin.SetMode(gin.TestMode)
	w1 := httptest.NewRecorder()
	c1, _ := gin.CreateTestContext(w1)
	c1.Request = httptest.NewRequest(http.MethodPost, "/read-all", strings.NewReader(body))
	c1.Request.Header.Set("Content-Type", "application/json")
	setGinContextUserID(c1, user.ID)
	handler.MarkAllRead(c1)
	if w1.Code != http.StatusOK {
		t.Fatalf("first call: expected 200, got %d", w1.Code)
	}

	// Second call — should be idempotent
	w2 := httptest.NewRecorder()
	c2, _ := gin.CreateTestContext(w2)
	c2.Request = httptest.NewRequest(http.MethodPost, "/read-all", strings.NewReader(body))
	c2.Request.Header.Set("Content-Type", "application/json")
	setGinContextUserID(c2, user.ID)
	handler.MarkAllRead(c2)
	if w2.Code != http.StatusOK {
		t.Fatalf("second call: expected 200 (idempotent), got %d", w2.Code)
	}

	// Verify announcement is marked read
	gin.SetMode(gin.TestMode)
	w3 := httptest.NewRecorder()
	c3, _ := gin.CreateTestContext(w3)
	c3.Request = httptest.NewRequest(http.MethodGet, "/unread", nil)
	setGinContextUserID(c3, user.ID)
	handler.GetUnread(c3)
	var result []models.Announcement
	json.Unmarshal(w3.Body.Bytes(), &result)
	if len(result) != 0 {
		t.Errorf("announcement should be marked read, got %d unread", len(result))
	}
	_ = ann
}

func TestMarkAllRead_Dedup(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	user := createTestUser(t, db, 13, time.Now().Add(-30*24*time.Hour))
	createTestAnnouncement(t, db, models.Announcement{
		ID:        16,
		Title:     "test",
		Content:   "test",
		CreatedBy: 1,
		CreatedAt: time.Now(),
	})

	body := `{"announcement_ids": [16, 16, 16]}`

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPost, "/read-all", strings.NewReader(body))
	c.Request.Header.Set("Content-Type", "application/json")
	setGinContextUserID(c, user.ID)
	handler.MarkAllRead(c)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 with dedup, got %d", w.Code)
	}
}

func TestMarkAllRead_Max100(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	user := createTestUser(t, db, 14, time.Now().Add(-30*24*time.Hour))

	// Build 101 IDs
	ids := make([]string, 101)
	for i := 0; i < 101; i++ {
		ids[i] = fmt.Sprintf("%d", i+1)
	}
	body := fmt.Sprintf(`{"announcement_ids": [%s]}`, strings.Join(ids, ","))

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPost, "/read-all", strings.NewReader(body))
	c.Request.Header.Set("Content-Type", "application/json")
	setGinContextUserID(c, user.ID)
	handler.MarkAllRead(c)
	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for >100 IDs, got %d", w.Code)
	}
}

func TestMarkAllRead_SkipsInvisible(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	user := createTestUser(t, db, 15, time.Now().Add(-30*24*time.Hour))
	createTestAnnouncement(t, db, models.Announcement{
		ID:        17,
		Title:     "draft",
		Content:   "draft",
		Status:    "draft",
		CreatedBy: 1,
		CreatedAt: time.Now(),
	})

	body := `{"announcement_ids": [17]}`
	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPost, "/read-all", strings.NewReader(body))
	c.Request.Header.Set("Content-Type", "application/json")
	setGinContextUserID(c, user.ID)
	handler.MarkAllRead(c)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 (silently skip invisible), got %d", w.Code)
	}
}

// ─── GetList / GetAdminList Tests ───────────────────────────────

func TestGetList_ShowsExpiredAsHistory(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	expired := time.Now().Add(-1 * time.Hour)
	createTestAnnouncement(t, db, models.Announcement{
		ID:        18,
		Title:     "expired but visible",
		Content:   "expired history",
		CreatedBy: 1,
		ExpiresAt: &expired,
		CreatedAt: time.Now().Add(-7 * 24 * time.Hour),
	})

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/", nil)
	handler.GetList(c)

	var result []models.Announcement
	json.Unmarshal(w.Body.Bytes(), &result)
	if len(result) != 1 {
		t.Errorf("expired announcement should still appear in GetList (history), got %d", len(result))
	}
}

func TestGetList_HidesDraft(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	createTestAnnouncement(t, db, models.Announcement{
		ID:        19,
		Title:     "draft",
		Content:   "draft",
		Status:    "draft",
		CreatedBy: 1,
		CreatedAt: time.Now(),
	})

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/", nil)
	handler.GetList(c)

	var result []models.Announcement
	json.Unmarshal(w.Body.Bytes(), &result)
	if len(result) != 0 {
		t.Errorf("draft announcement should not appear in GetList, got %d", len(result))
	}
}

func TestAdminList_ShowsAll(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	expired := time.Now().Add(-1 * time.Hour)
	future := time.Now().Add(24 * time.Hour)

	createTestAnnouncement(t, db, models.Announcement{
		ID:        20, Title: "published", Content: "p", Status: "published", CreatedBy: 1,
	})
	createTestAnnouncement(t, db, models.Announcement{
		ID:        21, Title: "draft", Content: "d", Status: "draft", CreatedBy: 1,
	})
	createTestAnnouncement(t, db, models.Announcement{
		ID:        22, Title: "archived", Content: "a", Status: "archived", CreatedBy: 1,
	})
	createTestAnnouncement(t, db, models.Announcement{
		ID:        23, Title: "expired", Content: "e", CreatedBy: 1, ExpiresAt: &expired, CreatedAt: time.Now().Add(-7 * 24 * time.Hour),
	})
	createTestAnnouncement(t, db, models.Announcement{
		ID:        24, Title: "future", Content: "f", CreatedBy: 1, PublishAt: &future,
	})

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/admin/list", nil)
	handler.GetAdminList(c)

	var result []models.Announcement
	json.Unmarshal(w.Body.Bytes(), &result)
	if len(result) != 5 {
		t.Errorf("admin list should show all 5 announcements, got %d", len(result))
	}
}

// ─── Priority Ordering Test ─────────────────────────────────────

func TestGetUnread_PriorityOrder(t *testing.T) {
	db := newAnnouncementTestDB(t)
	handler := NewAnnouncementHandler(db)

	user := createTestUser(t, db, 16, time.Now().Add(-30*24*time.Hour))
	// Create announcements with different priorities (created in reverse priority order)
	createTestAnnouncement(t, db, models.Announcement{
		ID:        25, Title: "normal", Content: "n", Priority: "normal", CreatedBy: 1, CreatedAt: time.Now(),
	})
	createTestAnnouncement(t, db, models.Announcement{
		ID:        26, Title: "important", Content: "i", Priority: "important", CreatedBy: 1, CreatedAt: time.Now().Add(-1 * time.Hour),
	})
	createTestAnnouncement(t, db, models.Announcement{
		ID:        27, Title: "urgent", Content: "u", Priority: "urgent", CreatedBy: 1, CreatedAt: time.Now().Add(-2 * time.Hour),
	})

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/unread", nil)
	setGinContextUserID(c, user.ID)
	handler.GetUnread(c)

	var result []models.Announcement
	json.Unmarshal(w.Body.Bytes(), &result)
	if len(result) != 3 {
		t.Fatalf("expected 3 unread, got %d", len(result))
	}
	if result[0].Priority != "urgent" {
		t.Errorf("first should be urgent, got %s", result[0].Priority)
	}
	if result[1].Priority != "important" {
		t.Errorf("second should be important, got %s", result[1].Priority)
	}
	if result[2].Priority != "normal" {
		t.Errorf("third should be normal, got %s", result[2].Priority)
	}
}

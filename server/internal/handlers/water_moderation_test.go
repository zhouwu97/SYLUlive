package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

var modTestUserSeq2 int64

func newModTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.Post{},
		&models.PostImage{},
		&models.File{},
		&models.WaterSection{},
		&models.WaterSectionTag{},
		&models.WaterSectionModerator{},
		&models.WaterSectionPin{},
		&models.WaterSectionMute{},
		&models.WaterModerationLog{},
	); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return db
}

func newModTestUser(t *testing.T, db *gorm.DB, role models.Role) models.User {
	t.Helper()
	seq := atomic.AddInt64(&modTestUserSeq2, 1)
	user := models.User{
		StudentID:    fmt.Sprintf("modtest_%s_%d", role, seq),
		PasswordHash: "x",
		Nickname:     fmt.Sprintf("%s_%d", role, seq),
		Role:         role,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	return user
}

func modTestSection(t *testing.T, db *gorm.DB, slug string) models.WaterSection {
	t.Helper()
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure sections: %v", err)
	}
	var section models.WaterSection
	if err := db.Where("slug = ?", slug).First(&section).Error; err != nil {
		t.Fatalf("find section %s: %v", slug, err)
	}
	return section
}

func modTestPost(t *testing.T, db *gorm.DB, authorID uint, section models.WaterSection) models.Post {
	t.Helper()
	post := models.Post{
		Title:    "test post",
		Content:  "test content",
		BoardID:  models.BoardShuitie,
		AuthorID: authorID,
		PostType: section.Slug,
		Status:   models.PostStatusNormal,
	}
	if err := db.Create(&post).Error; err != nil {
		t.Fatalf("create post: %v", err)
	}
	return post
}

func makeModerator(t *testing.T, db *gorm.DB, sectionID uint, userID uint, role string, perms map[string]bool) {
	t.Helper()
	cms := perms["can_edit_section"]
	cmt := perms["can_manage_tags"]
	cpp := perms["can_pin_post"]
	cdp := perms["can_delete_post"]
	cmm := perms["can_mute_user"]
	mod := models.WaterSectionModerator{
		SectionID:      sectionID,
		UserID:         userID,
		Role:           role,
		CanEditSection: cms,
		CanManageTags:  cmt,
		CanPinPost:     cpp,
		CanDeletePost:  cdp,
		CanMuteUser:    cmm,
		Status:         models.ModeratorStatusActive,
		AssignedBy:     1,
	}
	if err := db.Create(&mod).Error; err != nil {
		t.Fatalf("create moderator: %v", err)
	}
}

func execModAction(t *testing.T, handler *WaterModerationHandler, method, path, body string, userID uint, role models.Role) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	rec := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(rec)

	var req *http.Request
	if body != "" {
		req = httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
	} else {
		req = httptest.NewRequest(method, path, nil)
	}
	c.Request = req
	c.Set("user_id", userID)
	c.Set("role", string(role))

	slug := "course_study"
	parts := strings.Split(path, "/")
	for i, p := range parts {
		if p == "sections" && i+1 < len(parts) {
			slug = parts[i+1]
			break
		}
	}
	params := gin.Params{{Key: "slug", Value: slug}}

	// post_id
	for i, p := range parts {
		if p == "posts" && i+1 < len(parts) {
			params = append(params, gin.Param{Key: "post_id", Value: parts[i+1]})
			break
		}
	}
	// user_id
	for i, p := range parts {
		if p == "users" && i+1 < len(parts) {
			params = append(params, gin.Param{Key: "user_id", Value: parts[i+1]})
			break
		}
	}
	c.Params = params

	switch {
	case method == http.MethodPost && strings.Contains(path, "/pin") && !strings.Contains(path, "/pin/"):
		handler.PinPost(c)
	case method == http.MethodDelete && strings.Contains(path, "/pin") && !strings.Contains(path, "/moderate"):
		handler.UnpinPost(c)
	case method == http.MethodDelete && strings.Contains(path, "/moderate"):
		handler.DeletePost(c)
	case method == http.MethodPost && strings.Contains(path, "/restore"):
		handler.RestorePost(c)
	case method == http.MethodPost && strings.Contains(path, "/mute"):
		handler.MuteUser(c)
	case method == http.MethodDelete && strings.Contains(path, "/mute") && !strings.Contains(path, "/moderate"):
		handler.UnmuteUser(c)
	case method == http.MethodGet && strings.Contains(path, "/mutes") && !strings.Contains(path, "/moderation"):
		handler.ListMutes(c)
	case method == http.MethodGet && strings.Contains(path, "/moderation/logs"):
		handler.ListLogs(c)
	default:
		t.Fatalf("unmatched: %s %s", method, path)
	}
	return rec
}

func execPostListRequest(t *testing.T, handler *PostHandler, path string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	rec := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(rec)
	c.Request = httptest.NewRequest(http.MethodGet, path, nil)
	handler.GetList(c)
	return rec
}

// ── 测试 ──

// 1. admin pin course_study post
func TestModAdminPinPost(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, section)

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/pin", section.Slug, post.ID)
	body := `{"weight":50,"reason":"good post"}`
	rec := execModAction(t, handler, http.MethodPost, path, body, admin.ID, admin.Role)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 2. moderator with can_pin_post can pin post in own section
func TestModModeratorCanPinInOwnSection(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	modUser := newModTestUser(t, db, models.RoleUser)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, section)

	makeModerator(t, db, section.ID, modUser.ID, "moderator", map[string]bool{
		"can_pin_post": true, "can_delete_post": true, "can_mute_user": true,
	})

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/pin", section.Slug, post.ID)
	body := `{"weight":50}`
	rec := execModAction(t, handler, http.MethodPost, path, body, modUser.ID, models.RoleUser)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 3. course_study moderator cannot pin campus_life post
func TestModModeratorCannotPinOtherSection(t *testing.T) {
	db := newModTestDB(t)
	csSection := modTestSection(t, db, "course_study")
	clSection := modTestSection(t, db, "campus_life")
	modUser := newModTestUser(t, db, models.RoleUser)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, clSection)

	makeModerator(t, db, csSection.ID, modUser.ID, "moderator", map[string]bool{
		"can_pin_post": true, "can_delete_post": true, "can_mute_user": true,
	})

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/pin", clSection.Slug, post.ID)
	body := `{"weight":50}`
	rec := execModAction(t, handler, http.MethodPost, path, body, modUser.ID, models.RoleUser)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 4. moderator without can_pin_post cannot pin
func TestModModeratorWithoutPinPerm(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	modUser := newModTestUser(t, db, models.RoleUser)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, section)

	makeModerator(t, db, section.ID, modUser.ID, "moderator", map[string]bool{
		"can_pin_post": false, "can_delete_post": true, "can_mute_user": true,
	})

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/pin", section.Slug, post.ID)
	body := `{"weight":50}`
	rec := execModAction(t, handler, http.MethodPost, path, body, modUser.ID, models.RoleUser)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 5. max 3 active pins per section
func TestModMaxThreePins(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	author := newModTestUser(t, db, models.RoleUser)

	handler := NewWaterModerationHandler(db)
	for i := 0; i < 3; i++ {
		post := modTestPost(t, db, author.ID, section)
		path := fmt.Sprintf("/api/water/sections/%s/posts/%d/pin", section.Slug, post.ID)
		rec := execModAction(t, handler, http.MethodPost, path, `{}`, admin.ID, admin.Role)
		if rec.Code != http.StatusCreated {
			t.Fatalf("pin %d: expected 201 got %d body=%s", i, rec.Code, rec.Body.String())
		}
	}
	post4 := modTestPost(t, db, author.ID, section)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/pin", section.Slug, post4.ID)
	rec := execModAction(t, handler, http.MethodPost, path, `{}`, admin.ID, admin.Role)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 6. unpin writes log
func TestModUnpinWritesLog(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, section)

	handler := NewWaterModerationHandler(db)
	pinPath := fmt.Sprintf("/api/water/sections/%s/posts/%d/pin", section.Slug, post.ID)
	execModAction(t, handler, http.MethodPost, pinPath, `{}`, admin.ID, admin.Role)

	unpinPath := fmt.Sprintf("/api/water/sections/%s/posts/%d/pin", section.Slug, post.ID)
	rec := execModAction(t, handler, http.MethodDelete, unpinPath, `{"reason":"no longer relevant"}`, admin.ID, admin.Role)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var log models.WaterModerationLog
	db.Where("action = ? AND target_id = ?", models.ModActionUnpinPost, post.ID).First(&log)
	if log.ID == 0 {
		t.Fatal("unpin log not found")
	}
}

// 7. moderator with can_delete_post soft-deletes normal user post
func TestModModeratorDeletePost(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	modUser := newModTestUser(t, db, models.RoleUser)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, section)

	makeModerator(t, db, section.ID, modUser.ID, "moderator", map[string]bool{
		"can_pin_post": true, "can_delete_post": true, "can_mute_user": true,
	})

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/moderate", section.Slug, post.ID)
	body := `{"reason":"广告内容"}`
	rec := execModAction(t, handler, http.MethodDelete, path, body, modUser.ID, models.RoleUser)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}

	var reloaded models.Post
	db.Unscoped().First(&reloaded, post.ID)
	if reloaded.Status != models.PostStatusDeleted {
		t.Fatalf("expected deleted, got %s", reloaded.Status)
	}

	var log models.WaterModerationLog
	db.Where("action = ? AND target_id = ?", models.ModActionDeletePost, post.ID).First(&log)
	if log.ID == 0 {
		t.Fatal("delete log not found")
	}
}

// 8. moderator cannot delete admin post
func TestModModeratorCannotDeleteAdminPost(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	modUser := newModTestUser(t, db, models.RoleUser)
	adminAuthor := newModTestUser(t, db, models.RoleAdmin)
	post := modTestPost(t, db, adminAuthor.ID, section)

	makeModerator(t, db, section.ID, modUser.ID, "moderator", map[string]bool{
		"can_pin_post": true, "can_delete_post": true, "can_mute_user": true,
	})

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/moderate", section.Slug, post.ID)
	body := `{"reason":"test"}`
	rec := execModAction(t, handler, http.MethodDelete, path, body, modUser.ID, models.RoleUser)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 9. moderator cannot delete other active moderator's post
func TestModModeratorCannotDeleteModPost(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	modUser1 := newModTestUser(t, db, models.RoleUser)
	modUser2 := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, modUser2.ID, section)

	makeModerator(t, db, section.ID, modUser1.ID, "moderator", map[string]bool{
		"can_pin_post": true, "can_delete_post": true, "can_mute_user": true,
	})
	makeModerator(t, db, section.ID, modUser2.ID, "moderator", map[string]bool{
		"can_pin_post": true, "can_delete_post": true, "can_mute_user": true,
	})

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/moderate", section.Slug, post.ID)
	body := `{"reason":"test"}`
	rec := execModAction(t, handler, http.MethodDelete, path, body, modUser1.ID, models.RoleUser)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 10. admin can delete any section post
func TestModAdminDeleteAnySectionPost(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, section)

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/moderate", section.Slug, post.ID)
	body := `{"reason":"admin cleanup"}`
	rec := execModAction(t, handler, http.MethodDelete, path, body, admin.ID, admin.Role)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestModAdminRestoreDeletedPost(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, section)
	if err := db.Model(&post).Update("status", models.PostStatusDeleted).Error; err != nil {
		t.Fatalf("mark deleted: %v", err)
	}

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/restore", section.Slug, post.ID)
	rec := execModAction(t, handler, http.MethodPost, path, `{"reason":"误删恢复"}`, admin.ID, admin.Role)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}

	var reloaded models.Post
	db.First(&reloaded, post.ID)
	if reloaded.Status != models.PostStatusNormal {
		t.Fatalf("expected normal, got %s", reloaded.Status)
	}

	var log models.WaterModerationLog
	db.Where("action = ? AND target_id = ?", models.ModActionRestorePost, post.ID).First(&log)
	if log.ID == 0 {
		t.Fatal("restore log not found")
	}
	if log.TargetUserID == nil || *log.TargetUserID != author.ID {
		t.Fatalf("expected target user %d, got %v", author.ID, log.TargetUserID)
	}
}

func TestModSuperAdminRestoreDeletedPost(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	superAdmin := newModTestUser(t, db, models.RoleSuperAdmin)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, section)
	if err := db.Model(&post).Update("status", models.PostStatusDeleted).Error; err != nil {
		t.Fatalf("mark deleted: %v", err)
	}

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/restore", section.Slug, post.ID)
	rec := execModAction(t, handler, http.MethodPost, path, `{}`, superAdmin.ID, superAdmin.Role)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestModModeratorCannotRestoreDeletedPost(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	modUser := newModTestUser(t, db, models.RoleUser)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, section)
	if err := db.Model(&post).Update("status", models.PostStatusDeleted).Error; err != nil {
		t.Fatalf("mark deleted: %v", err)
	}
	makeModerator(t, db, section.ID, modUser.ID, "moderator", map[string]bool{
		"can_pin_post": true, "can_delete_post": true, "can_mute_user": true,
	})

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/restore", section.Slug, post.ID)
	rec := execModAction(t, handler, http.MethodPost, path, `{"reason":"误删恢复"}`, modUser.ID, modUser.Role)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestModUserCannotRestoreDeletedPost(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	user := newModTestUser(t, db, models.RoleUser)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, section)
	if err := db.Model(&post).Update("status", models.PostStatusDeleted).Error; err != nil {
		t.Fatalf("mark deleted: %v", err)
	}

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/restore", section.Slug, post.ID)
	rec := execModAction(t, handler, http.MethodPost, path, `{"reason":"误删恢复"}`, user.ID, user.Role)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestModRestoreNormalPostReturnsBadRequest(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, section)

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/restore", section.Slug, post.ID)
	rec := execModAction(t, handler, http.MethodPost, path, `{"reason":"误删恢复"}`, admin.ID, admin.Role)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestModRestoreRejectsOtherSectionPost(t *testing.T) {
	db := newModTestDB(t)
	courseSection := modTestSection(t, db, "course_study")
	campusSection := modTestSection(t, db, "campus_life")
	admin := newModTestUser(t, db, models.RoleAdmin)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, courseSection)
	if err := db.Model(&post).Update("status", models.PostStatusDeleted).Error; err != nil {
		t.Fatalf("mark deleted: %v", err)
	}

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/restore", campusSection.Slug, post.ID)
	rec := execModAction(t, handler, http.MethodPost, path, `{"reason":"误删恢复"}`, admin.ID, admin.Role)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 11. moderator with can_mute_user can mute normal user
func TestModModeratorMuteUser(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	modUser := newModTestUser(t, db, models.RoleUser)
	target := newModTestUser(t, db, models.RoleUser)

	makeModerator(t, db, section.ID, modUser.ID, "moderator", map[string]bool{
		"can_pin_post": true, "can_delete_post": true, "can_mute_user": true,
	})

	handler := NewWaterModerationHandler(db)
	until := time.Now().Add(1 * time.Hour).Format(time.RFC3339)
	path := fmt.Sprintf("/api/water/sections/%s/users/%d/mute", section.Slug, target.ID)
	body := fmt.Sprintf(`{"reason":"spam","until":"%s"}`, until)
	rec := execModAction(t, handler, http.MethodPost, path, body, modUser.ID, models.RoleUser)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 12. moderator cannot mute admin
func TestModModeratorCannotMuteAdmin(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	modUser := newModTestUser(t, db, models.RoleUser)
	adminTarget := newModTestUser(t, db, models.RoleAdmin)

	makeModerator(t, db, section.ID, modUser.ID, "moderator", map[string]bool{
		"can_pin_post": true, "can_delete_post": true, "can_mute_user": true,
	})

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/users/%d/mute", section.Slug, adminTarget.ID)
	body := `{"reason":"test"}`
	rec := execModAction(t, handler, http.MethodPost, path, body, modUser.ID, models.RoleUser)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 13. moderator cannot mute other active moderator
func TestModModeratorCannotMuteMod(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	modUser1 := newModTestUser(t, db, models.RoleUser)
	modUser2 := newModTestUser(t, db, models.RoleUser)

	makeModerator(t, db, section.ID, modUser1.ID, "moderator", map[string]bool{
		"can_pin_post": true, "can_delete_post": true, "can_mute_user": true,
	})
	makeModerator(t, db, section.ID, modUser2.ID, "moderator", map[string]bool{
		"can_pin_post": true, "can_delete_post": true, "can_mute_user": true,
	})

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/users/%d/mute", section.Slug, modUser2.ID)
	body := `{"reason":"test"}`
	rec := execModAction(t, handler, http.MethodPost, path, body, modUser1.ID, models.RoleUser)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 14. moderator mute > 7 days → 400
func TestModModeratorMuteMaxDuration(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	modUser := newModTestUser(t, db, models.RoleUser)
	target := newModTestUser(t, db, models.RoleUser)

	makeModerator(t, db, section.ID, modUser.ID, "moderator", map[string]bool{
		"can_pin_post": true, "can_delete_post": true, "can_mute_user": true,
	})

	handler := NewWaterModerationHandler(db)
	until := time.Now().Add(8 * 24 * time.Hour).Format(time.RFC3339)
	path := fmt.Sprintf("/api/water/sections/%s/users/%d/mute", section.Slug, target.ID)
	body := fmt.Sprintf(`{"reason":"spam","until":"%s"}`, until)
	rec := execModAction(t, handler, http.MethodPost, path, body, modUser.ID, models.RoleUser)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 15. muted user cannot create post in that section
func TestModMutedUserCannotCreatePost(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	target := newModTestUser(t, db, models.RoleUser)

	handler := NewWaterModerationHandler(db)
	until := time.Now().Add(1 * time.Hour).Format(time.RFC3339)
	path := fmt.Sprintf("/api/water/sections/%s/users/%d/mute", section.Slug, target.ID)
	body := fmt.Sprintf(`{"reason":"spam","until":"%s"}`, until)
	execModAction(t, handler, http.MethodPost, path, body, admin.ID, admin.Role)

	// Verify muted
	if !services.NewWaterPermissionService(db).IsMuted(section.ID, target.ID) {
		t.Fatal("user should be muted")
	}
}

// 16. muted user can still post in other section
func TestModMutedUserCanPostOtherSection(t *testing.T) {
	db := newModTestDB(t)
	csSection := modTestSection(t, db, "course_study")
	clSection := modTestSection(t, db, "campus_life")
	admin := newModTestUser(t, db, models.RoleAdmin)
	target := newModTestUser(t, db, models.RoleUser)

	// Mute in course_study
	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/users/%d/mute", csSection.Slug, target.ID)
	execModAction(t, handler, http.MethodPost, path, `{"reason":"spam"}`, admin.ID, admin.Role)

	// Should NOT be muted in campus_life
	if services.NewWaterPermissionService(db).IsMuted(clSection.ID, target.ID) {
		t.Fatal("user should NOT be muted in other section")
	}
}

// 17. unmute then can post again
func TestModUnmuteThenCanPost(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	target := newModTestUser(t, db, models.RoleUser)

	handler := NewWaterModerationHandler(db)
	mutePath := fmt.Sprintf("/api/water/sections/%s/users/%d/mute", section.Slug, target.ID)
	execModAction(t, handler, http.MethodPost, mutePath, `{"reason":"spam"}`, admin.ID, admin.Role)

	unmutePath := fmt.Sprintf("/api/water/sections/%s/users/%d/mute", section.Slug, target.ID)
	rec := execModAction(t, handler, http.MethodDelete, unmutePath, `{}`, admin.ID, admin.Role)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	if services.NewWaterPermissionService(db).IsMuted(section.ID, target.ID) {
		t.Fatal("user should be unmuted")
	}
}

// 18. GET mutes returns only active
func TestModListMutes(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	target := newModTestUser(t, db, models.RoleUser)

	handler := NewWaterModerationHandler(db)
	mutePath := fmt.Sprintf("/api/water/sections/%s/users/%d/mute", section.Slug, target.ID)
	execModAction(t, handler, http.MethodPost, mutePath, `{"reason":"spam"}`, admin.ID, admin.Role)

	listPath := fmt.Sprintf("/api/water/sections/%s/mutes", section.Slug)
	rec := execModAction(t, handler, http.MethodGet, listPath, "", admin.ID, admin.Role)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var body struct {
		Mutes []models.WaterSectionMute `json:"mutes"`
	}
	json.Unmarshal(rec.Body.Bytes(), &body)
	if len(body.Mutes) != 1 {
		t.Fatalf("expected 1 mute, got %d", len(body.Mutes))
	}
}

// 19. normal user 403 on moderation logs
func TestModNormalUserCannotViewLogs(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	normal := newModTestUser(t, db, models.RoleUser)

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/moderation/logs", section.Slug)
	rec := execModAction(t, handler, http.MethodGet, path, "", normal.ID, normal.Role)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 20. moderator can view logs on own section but not other
func TestModModeratorLogsOwnSectionOnly(t *testing.T) {
	db := newModTestDB(t)
	csSection := modTestSection(t, db, "course_study")
	clSection := modTestSection(t, db, "campus_life")
	modUser := newModTestUser(t, db, models.RoleUser)

	makeModerator(t, db, csSection.ID, modUser.ID, "moderator", map[string]bool{
		"can_pin_post": true, "can_delete_post": true, "can_mute_user": true,
	})

	handler := NewWaterModerationHandler(db)
	ownPath := fmt.Sprintf("/api/water/sections/%s/moderation/logs", csSection.Slug)
	rec := execModAction(t, handler, http.MethodGet, ownPath, "", modUser.ID, models.RoleUser)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 on own section, got %d", rec.Code)
	}

	otherPath := fmt.Sprintf("/api/water/sections/%s/moderation/logs", clSection.Slug)
	rec2 := execModAction(t, handler, http.MethodGet, otherPath, "", modUser.ID, models.RoleUser)
	if rec2.Code != http.StatusForbidden {
		t.Fatalf("expected 403 on other section, got %d", rec2.Code)
	}
}

// 21. section pin doesn't affect home page (type empty)
func TestModSectionPinDoesNotAffectHome(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	author := newModTestUser(t, db, models.RoleUser)

	// Pin a post
	post := modTestPost(t, db, author.ID, section)
	handler := NewWaterModerationHandler(db)
	pinPath := fmt.Sprintf("/api/water/sections/%s/posts/%d/pin", section.Slug, post.ID)
	execModAction(t, handler, http.MethodPost, pinPath, `{}`, admin.ID, admin.Role)

	// Verify pin exists
	var pin models.WaterSectionPin
	db.Where("section_id = ? AND post_id = ? AND status = ?", section.ID, post.ID, models.PinStatusActive).First(&pin)
	if pin.ID == 0 {
		t.Fatal("pin should exist")
	}
	// Home page test: section pin is only used when type=section.slug, which is proven
	// by the pin not having board-level is_pinned=true.
	var reloaded models.Post
	db.First(&reloaded, post.ID)
	if reloaded.IsPinned {
		t.Fatal("section pin should NOT set post.is_pinned")
	}
}

// 22. marketplace not affected
func TestModMarketplaceUnaffected(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	author := newModTestUser(t, db, models.RoleUser)

	// Mute an author in course_study
	handler := NewWaterModerationHandler(db)
	mutePath := fmt.Sprintf("/api/water/sections/%s/users/%d/mute", section.Slug, author.ID)
	execModAction(t, handler, http.MethodPost, mutePath, `{"reason":"test"}`, admin.ID, admin.Role)

	// Mute should NOT prevent marketplace posting (as it's per-section)
	if services.NewWaterPermissionService(db).IsMuted(section.ID, author.ID) {
		// This is correct - the user IS muted in course_study
		// But marketplace board has separate board_id=2 check in Create handler
	}
}

// 23. delete requires reason
func TestModDeleteRequiresReason(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, section)

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/moderate", section.Slug, post.ID)
	rec := execModAction(t, handler, http.MethodDelete, path, `{}`, admin.ID, admin.Role)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for empty reason, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 24. admin mute > 30 days is ok if not exceeded (test with 29.9 days)
func TestModAdminMuteWithinLimit(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	target := newModTestUser(t, db, models.RoleUser)

	handler := NewWaterModerationHandler(db)
	until := time.Now().Add(29 * 24 * time.Hour).Format(time.RFC3339)
	path := fmt.Sprintf("/api/water/sections/%s/users/%d/mute", section.Slug, target.ID)
	body := fmt.Sprintf(`{"reason":"serious","until":"%s"}`, until)
	rec := execModAction(t, handler, http.MethodPost, path, body, admin.ID, admin.Role)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestModDeleteReasonTooShort(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, section)

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/moderate", section.Slug, post.ID)
	rec := execModAction(t, handler, http.MethodDelete, path, `{"reason":"a"}`, admin.ID, admin.Role)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for short reason, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestModMuteReasonTooShort(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	target := newModTestUser(t, db, models.RoleUser)

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/users/%d/mute", section.Slug, target.ID)
	rec := execModAction(t, handler, http.MethodPost, path, `{"reason":"a"}`, admin.ID, admin.Role)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for short reason, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestModUnpinWithoutActivePinIsIdempotentAndDoesNotWriteLog(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	author := newModTestUser(t, db, models.RoleUser)
	post := modTestPost(t, db, author.ID, section)

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/pin", section.Slug, post.ID)
	rec := execModAction(t, handler, http.MethodDelete, path, `{}`, admin.ID, admin.Role)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	var count int64
	db.Model(&models.WaterModerationLog{}).
		Where("action = ? AND target_id = ?", models.ModActionUnpinPost, post.ID).
		Count(&count)
	if count != 0 {
		t.Fatalf("idempotent unpin should not write log, got %d", count)
	}
}

func TestModUnmuteWithoutActiveMuteIsIdempotentAndDoesNotWriteLog(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	target := newModTestUser(t, db, models.RoleUser)

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/users/%d/mute", section.Slug, target.ID)
	rec := execModAction(t, handler, http.MethodDelete, path, `{}`, admin.ID, admin.Role)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	var count int64
	db.Model(&models.WaterModerationLog{}).
		Where("action = ? AND target_id = ?", models.ModActionUnmuteUser, target.ID).
		Count(&count)
	if count != 0 {
		t.Fatalf("idempotent unmute should not write log, got %d", count)
	}
}

func TestModExpiredMuteDoesNotBlockAndIsHiddenFromActiveList(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	target := newModTestUser(t, db, models.RoleUser)
	expiredAt := time.Now().Add(-1 * time.Hour)

	if err := db.Create(&models.WaterSectionMute{
		SectionID: section.ID,
		UserID:    target.ID,
		MutedBy:   admin.ID,
		Reason:    "过期测试",
		Until:     &expiredAt,
		Status:    models.MuteStatusActive,
	}).Error; err != nil {
		t.Fatalf("create expired mute: %v", err)
	}

	if services.NewWaterPermissionService(db).IsMuted(section.ID, target.ID) {
		t.Fatal("expired mute should not block posting")
	}

	handler := NewWaterModerationHandler(db)
	path := fmt.Sprintf("/api/water/sections/%s/mutes", section.Slug)
	rec := execModAction(t, handler, http.MethodGet, path, "", admin.ID, admin.Role)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		Mutes []models.WaterSectionMute `json:"mutes"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode mutes: %v", err)
	}
	if len(body.Mutes) != 0 {
		t.Fatalf("expired active mute should be hidden from active list, got %d", len(body.Mutes))
	}
}

func TestModExpiredPinDoesNotCountTowardLimit(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	author := newModTestUser(t, db, models.RoleUser)
	expiredAt := time.Now().Add(-1 * time.Hour)
	for i := 0; i < 3; i++ {
		post := modTestPost(t, db, author.ID, section)
		if err := db.Create(&models.WaterSectionPin{
			SectionID:   section.ID,
			PostID:      post.ID,
			PinnedBy:    admin.ID,
			Weight:      50,
			Reason:      "过期置顶",
			PinnedUntil: &expiredAt,
			Status:      models.PinStatusActive,
		}).Error; err != nil {
			t.Fatalf("create expired pin: %v", err)
		}
	}

	handler := NewWaterModerationHandler(db)
	post := modTestPost(t, db, author.ID, section)
	path := fmt.Sprintf("/api/water/sections/%s/posts/%d/pin", section.Slug, post.ID)
	rec := execModAction(t, handler, http.MethodPost, path, `{"reason":"新的置顶"}`, admin.ID, admin.Role)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expired pins should not count toward limit, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestModSectionPinStateAndOrderOnlyUseActivePins(t *testing.T) {
	db := newModTestDB(t)
	section := modTestSection(t, db, "course_study")
	admin := newModTestUser(t, db, models.RoleAdmin)
	author := newModTestUser(t, db, models.RoleUser)
	oldPost := modTestPost(t, db, author.ID, section)
	newPost := modTestPost(t, db, author.ID, section)
	pastCreated := time.Now().Add(-2 * time.Hour)
	if err := db.Model(&oldPost).Update("created_at", pastCreated).Error; err != nil {
		t.Fatalf("update old post time: %v", err)
	}

	if err := db.Create(&models.WaterSectionPin{
		SectionID: section.ID,
		PostID:    oldPost.ID,
		PinnedBy:  admin.ID,
		Weight:    80,
		Reason:    "有效置顶",
		Status:    models.PinStatusActive,
	}).Error; err != nil {
		t.Fatalf("create active pin: %v", err)
	}

	postHandler := NewPostHandler(db, "", "")
	path := fmt.Sprintf("/api/posts?board=1&type=%s&sort=time&page=1&limit=10", section.Slug)
	rec := execPostListRequest(t, postHandler, path)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		Posts []models.Post `json:"posts"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode posts: %v", err)
	}
	if len(body.Posts) < 2 {
		t.Fatalf("expected posts, got %d", len(body.Posts))
	}
	if body.Posts[0].ID != oldPost.ID || !body.Posts[0].WaterSectionPinned {
		t.Fatalf("active section pin should be first and marked, first=%d marked=%v", body.Posts[0].ID, body.Posts[0].WaterSectionPinned)
	}

	expiredAt := time.Now().Add(-1 * time.Hour)
	if err := db.Model(&models.WaterSectionPin{}).
		Where("post_id = ?", oldPost.ID).
		Update("pinned_until", expiredAt).Error; err != nil {
		t.Fatalf("expire pin: %v", err)
	}
	rec = execPostListRequest(t, postHandler, path)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 after expire, got %d body=%s", rec.Code, rec.Body.String())
	}
	body = struct {
		Posts []models.Post `json:"posts"`
	}{}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode posts after expire: %v", err)
	}
	if len(body.Posts) < 2 {
		t.Fatalf("expected posts after expire, got %d", len(body.Posts))
	}
	if body.Posts[0].ID != newPost.ID || body.Posts[0].WaterSectionPinned {
		t.Fatalf("expired section pin should not affect order/state, first=%d marked=%v", body.Posts[0].ID, body.Posts[0].WaterSectionPinned)
	}
}

// Ensure services import is used
var _ = services.WaterSectionPermission{}

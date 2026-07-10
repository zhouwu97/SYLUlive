package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

var testUserSeq int64

// ---- test helpers ----

func newModeratorTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.AutoMigrate(&models.WaterTeamRecruitment{}, &models.WaterTeamApplication{}, 
		&models.User{},
		&models.WaterSection{},
		&models.WaterSectionTag{},
		&models.WaterSectionModerator{},
	); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return db
}

func newModeratorTestUser(t *testing.T, db *gorm.DB, role models.Role) models.User {
	t.Helper()
	seq := atomic.AddInt64(&testUserSeq, 1)
	user := models.User{
		StudentID:    fmt.Sprintf("test_%s_%d", role, seq),
		PasswordHash: "x",
		Nickname:     fmt.Sprintf("%s_user_%d", role, seq),
		Role:         role,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	return user
}

func ensureTestSection(t *testing.T, db *gorm.DB) models.WaterSection {
	t.Helper()
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure sections: %v", err)
	}
	var section models.WaterSection
	if err := db.Where("slug = ?", "course_study").First(&section).Error; err != nil {
		t.Fatalf("find section: %v", err)
	}
	return section
}

// execModeratorRequestWithAuth invokes a moderator endpoint with mock auth context
func execModeratorRequestWithAuth(t *testing.T, h *WaterModeratorHandler, method, path string, body string, userID uint, role models.Role) *httptest.ResponseRecorder {
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

	// Set params from path
	slug := extractSlugFromPath(path)
	params := gin.Params{{Key: "slug", Value: slug}}
	if strings.Contains(path, "/moderators/") {
		parts := strings.Split(strings.TrimRight(path, "/"), "/")
		last := parts[len(parts)-1]
		if _, err := fmt.Sscanf(last, "%d", new(uint)); err == nil {
			params = append(params, gin.Param{Key: "moderator_id", Value: last})
		}
	}
	c.Params = params

	// Route based on method + path pattern
	switch {
	case method == http.MethodGet && !strings.Contains(path, "/moderators") && strings.Contains(path, "my-permission"):
		h.MyPermission(c)
	case method == http.MethodGet && strings.Contains(path, "/moderators") && !strings.Contains(path, "/moderators/"):
		h.GetModerators(c)
	case method == http.MethodPost && strings.Contains(path, "/moderators"):
		h.AssignModerator(c)
	case method == http.MethodPatch && strings.Contains(path, "/moderators/"):
		h.UpdateModerator(c)
	case method == http.MethodDelete && strings.Contains(path, "/moderators/"):
		h.RevokeModerator(c)
	default:
		t.Fatalf("unmatched route: %s %s", method, path)
	}
	return rec
}

func extractSlugFromPath(path string) string {
	parts := strings.Split(path, "/")
	for i, p := range parts {
		if p == "sections" && i+1 < len(parts) {
			return parts[i+1]
		}
	}
	return "course_study"
}

// ---- tests ----

// 1. admin can assign normal user as moderator for a section
func TestAdminCanAssignModerator(t *testing.T) {
	db := newModeratorTestDB(t)
	section := ensureTestSection(t, db)
	admin := newModeratorTestUser(t, db, models.RoleAdmin)
	target := newModeratorTestUser(t, db, models.RoleUser)

	handler := NewWaterModeratorHandler(db)
	body := fmt.Sprintf(`{"user_id":%d,"role":"moderator","reason":"test assign"}`, target.ID)
	path := fmt.Sprintf("/api/admin/water/sections/%s/moderators", section.Slug)
	rec := execModeratorRequestWithAuth(t, handler, http.MethodPost, path, body, admin.ID, admin.Role)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d body=%s", rec.Code, rec.Body.String())
	}

	var resp struct {
		Moderator moderatorResponse `json:"moderator"`
	}
	json.Unmarshal(rec.Body.Bytes(), &resp)
	if resp.Moderator.UserID != target.ID {
		t.Fatalf("wrong user_id: %d", resp.Moderator.UserID)
	}
	if resp.Moderator.Role != "moderator" {
		t.Fatalf("wrong role: %s", resp.Moderator.Role)
	}
}

// 2. super_admin can assign moderator
func TestSuperAdminCanAssignModerator(t *testing.T) {
	db := newModeratorTestDB(t)
	section := ensureTestSection(t, db)
	super := newModeratorTestUser(t, db, models.RoleSuperAdmin)
	target := newModeratorTestUser(t, db, models.RoleUser)

	handler := NewWaterModeratorHandler(db)
	body := fmt.Sprintf(`{"user_id":%d,"role":"moderator","reason":"test super"}`, target.ID)
	path := fmt.Sprintf("/api/admin/water/sections/%s/moderators", section.Slug)
	rec := execModeratorRequestWithAuth(t, handler, http.MethodPost, path, body, super.ID, super.Role)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 3. normal user cannot assign moderator → 403
func TestNormalUserCannotAssignModerator(t *testing.T) {
	db := newModeratorTestDB(t)
	section := ensureTestSection(t, db)
	normal := newModeratorTestUser(t, db, models.RoleUser)
	target := newModeratorTestUser(t, db, models.RoleUser)

	handler := NewWaterModeratorHandler(db)
	body := fmt.Sprintf(`{"user_id":%d,"role":"moderator","reason":"fail"}`, target.ID)
	path := fmt.Sprintf("/api/admin/water/sections/%s/moderators", section.Slug)
	rec := execModeratorRequestWithAuth(t, handler, http.MethodPost, path, body, normal.ID, normal.Role)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rec.Code)
	}
}

// 4. moderator cannot assign another moderator → 403
func TestModeratorCannotAssignModerator(t *testing.T) {
	db := newModeratorTestDB(t)
	section := ensureTestSection(t, db)
	admin := newModeratorTestUser(t, db, models.RoleAdmin)
	modUser := newModeratorTestUser(t, db, models.RoleUser)
	target := newModeratorTestUser(t, db, models.RoleUser)

	handler := NewWaterModeratorHandler(db)
	// 先由 admin 任命版主
	assignBody := fmt.Sprintf(`{"user_id":%d,"role":"moderator","reason":"first"}`, modUser.ID)
	assignPath := fmt.Sprintf("/api/admin/water/sections/%s/moderators", section.Slug)
	assignRec := execModeratorRequestWithAuth(t, handler, http.MethodPost, assignPath, assignBody, admin.ID, admin.Role)
	if assignRec.Code != http.StatusCreated {
		t.Fatalf("pre-assign failed: %d %s", assignRec.Code, assignRec.Body.String())
	}

	// 版主尝试任命其他人
	body := fmt.Sprintf(`{"user_id":%d,"role":"moderator","reason":"no"}`, target.ID)
	path := fmt.Sprintf("/api/admin/water/sections/%s/moderators", section.Slug)
	rec := execModeratorRequestWithAuth(t, handler, http.MethodPost, path, body, modUser.ID, models.RoleUser)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rec.Code)
	}
}

// 5. cannot assign admin/super_admin as moderator → 400
func TestCannotAssignAdminAsModerator(t *testing.T) {
	db := newModeratorTestDB(t)
	section := ensureTestSection(t, db)
	sAdmin := newModeratorTestUser(t, db, models.RoleSuperAdmin)
	adminTarget := newModeratorTestUser(t, db, models.RoleAdmin)

	handler := NewWaterModeratorHandler(db)
	body := fmt.Sprintf(`{"user_id":%d,"role":"moderator","reason":"bad"}`, adminTarget.ID)
	path := fmt.Sprintf("/api/admin/water/sections/%s/moderators", section.Slug)
	rec := execModeratorRequestWithAuth(t, handler, http.MethodPost, path, body, sAdmin.ID, sAdmin.Role)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 6. same user same section active → POST returns 409
func TestAssignDuplicateActiveModerator(t *testing.T) {
	db := newModeratorTestDB(t)
	section := ensureTestSection(t, db)
	admin := newModeratorTestUser(t, db, models.RoleAdmin)
	target := newModeratorTestUser(t, db, models.RoleUser)

	handler := NewWaterModeratorHandler(db)
	body := fmt.Sprintf(`{"user_id":%d,"role":"moderator","reason":"first"}`, target.ID)
	path := fmt.Sprintf("/api/admin/water/sections/%s/moderators", section.Slug)

	rec1 := execModeratorRequestWithAuth(t, handler, http.MethodPost, path, body, admin.ID, admin.Role)
	if rec1.Code != http.StatusCreated {
		t.Fatalf("first assign: %d %s", rec1.Code, rec1.Body.String())
	}
	rec2 := execModeratorRequestWithAuth(t, handler, http.MethodPost, path, body, admin.ID, admin.Role)
	if rec2.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d body=%s", rec2.Code, rec2.Body.String())
	}
}

// 7. admin can PATCH modify moderator permissions
func TestAdminCanUpdateModerator(t *testing.T) {
	db := newModeratorTestDB(t)
	section := ensureTestSection(t, db)
	admin := newModeratorTestUser(t, db, models.RoleAdmin)
	target := newModeratorTestUser(t, db, models.RoleUser)

	handler := NewWaterModeratorHandler(db)
	assignBody := fmt.Sprintf(`{"user_id":%d,"role":"moderator","reason":"test"}`, target.ID)
	assignPath := fmt.Sprintf("/api/admin/water/sections/%s/moderators", section.Slug)
	assignRec := execModeratorRequestWithAuth(t, handler, http.MethodPost, assignPath, assignBody, admin.ID, admin.Role)
	var resp struct {
		Moderator moderatorResponse `json:"moderator"`
	}
	json.Unmarshal(assignRec.Body.Bytes(), &resp)
	modID := resp.Moderator.ID

	// PATCH
	patchPath := fmt.Sprintf("/api/admin/water/sections/%s/moderators/%d", section.Slug, modID)
	patchBody := `{"can_edit_section":true,"can_manage_tags":true,"reason":"upgraded"}`
	patchRec := execModeratorRequestWithAuth(t, handler, http.MethodPatch, patchPath, patchBody, admin.ID, admin.Role)
	if patchRec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", patchRec.Code, patchRec.Body.String())
	}

	var resp2 struct {
		Moderator moderatorResponse `json:"moderator"`
	}
	json.Unmarshal(patchRec.Body.Bytes(), &resp2)
	if !resp2.Moderator.CanEditSection || !resp2.Moderator.CanManageTags {
		t.Fatalf("permissions not updated: e=%v m=%v", resp2.Moderator.CanEditSection, resp2.Moderator.CanManageTags)
	}
}

// 8. admin DELETE soft-revokes moderator
func TestAdminCanRevokeModerator(t *testing.T) {
	db := newModeratorTestDB(t)
	section := ensureTestSection(t, db)
	admin := newModeratorTestUser(t, db, models.RoleAdmin)
	target := newModeratorTestUser(t, db, models.RoleUser)

	handler := NewWaterModeratorHandler(db)
	assignBody := fmt.Sprintf(`{"user_id":%d,"role":"moderator","reason":"test"}`, target.ID)
	assignPath := fmt.Sprintf("/api/admin/water/sections/%s/moderators", section.Slug)
	assignRec := execModeratorRequestWithAuth(t, handler, http.MethodPost, assignPath, assignBody, admin.ID, admin.Role)
	var resp struct {
		Moderator moderatorResponse `json:"moderator"`
	}
	json.Unmarshal(assignRec.Body.Bytes(), &resp)
	modID := resp.Moderator.ID

	// DELETE
	delPath := fmt.Sprintf("/api/admin/water/sections/%s/moderators/%d", section.Slug, modID)
	delRec := execModeratorRequestWithAuth(t, handler, http.MethodDelete, delPath, `{"reason":"inactive"}`, admin.ID, admin.Role)
	if delRec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", delRec.Code, delRec.Body.String())
	}

	// verify status=revoked in DB
	var mod models.WaterSectionModerator
	db.First(&mod, modID)
	if mod.Status != models.ModeratorStatusRevoked {
		t.Fatalf("expected revoked, got %s", mod.Status)
	}
}

// 9. revoked moderator's my-permission returns all false
func TestRevokedModeratorNoPermission(t *testing.T) {
	db := newModeratorTestDB(t)
	section := ensureTestSection(t, db)
	admin := newModeratorTestUser(t, db, models.RoleAdmin)
	target := newModeratorTestUser(t, db, models.RoleUser)

	handler := NewWaterModeratorHandler(db)
	assignBody := fmt.Sprintf(`{"user_id":%d,"role":"moderator","reason":"test"}`, target.ID)
	assignPath := fmt.Sprintf("/api/admin/water/sections/%s/moderators", section.Slug)
	assignRec := execModeratorRequestWithAuth(t, handler, http.MethodPost, assignPath, assignBody, admin.ID, admin.Role)
	var resp struct {
		Moderator moderatorResponse `json:"moderator"`
	}
	json.Unmarshal(assignRec.Body.Bytes(), &resp)
	modID := resp.Moderator.ID

	// revoke
	delPath := fmt.Sprintf("/api/admin/water/sections/%s/moderators/%d", section.Slug, modID)
	delRec := execModeratorRequestWithAuth(t, handler, http.MethodDelete, delPath, `{"reason":"test"}`, admin.ID, admin.Role)
	if delRec.Code != http.StatusOK {
		t.Fatalf("revoke failed: %d", delRec.Code)
	}

	// my-permission
	permPath := fmt.Sprintf("/api/water/sections/%s/my-permission", section.Slug)
	permRec := execModeratorRequestWithAuth(t, handler, http.MethodGet, permPath, "", target.ID, models.RoleUser)
	if permRec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", permRec.Code)
	}
	var permResp struct {
		Permission services.WaterSectionPermission `json:"permission"`
	}
	json.Unmarshal(permRec.Body.Bytes(), &permResp)
	if permResp.Permission.CanPinPost {
		t.Fatalf("revoked moderator should not have permissions")
	}
}

// 10. revoked moderator can be re-activated via POST
func TestReactivateRevokedModerator(t *testing.T) {
	db := newModeratorTestDB(t)
	section := ensureTestSection(t, db)
	admin := newModeratorTestUser(t, db, models.RoleAdmin)
	target := newModeratorTestUser(t, db, models.RoleUser)

	handler := NewWaterModeratorHandler(db)
	assignBody := fmt.Sprintf(`{"user_id":%d,"role":"moderator","reason":"test"}`, target.ID)
	assignPath := fmt.Sprintf("/api/admin/water/sections/%s/moderators", section.Slug)

	assignRec := execModeratorRequestWithAuth(t, handler, http.MethodPost, assignPath, assignBody, admin.ID, admin.Role)
	var resp struct {
		Moderator moderatorResponse `json:"moderator"`
	}
	json.Unmarshal(assignRec.Body.Bytes(), &resp)
	modID := resp.Moderator.ID

	// revoke
	delPath := fmt.Sprintf("/api/admin/water/sections/%s/moderators/%d", section.Slug, modID)
	execModeratorRequestWithAuth(t, handler, http.MethodDelete, delPath, `{}`, admin.ID, admin.Role)

	// re-assign
	reRec := execModeratorRequestWithAuth(t, handler, http.MethodPost, assignPath, assignBody, admin.ID, admin.Role)
	if reRec.Code != http.StatusOK {
		t.Fatalf("expected 200 (reactivated), got %d body=%s", reRec.Code, reRec.Body.String())
	}
}

// 11. admin my-permission returns all true for any section
func TestAdminMyPermissionAllTrue(t *testing.T) {
	db := newModeratorTestDB(t)
	section := ensureTestSection(t, db)
	admin := newModeratorTestUser(t, db, models.RoleAdmin)

	handler := NewWaterModeratorHandler(db)
	permPath := fmt.Sprintf("/api/water/sections/%s/my-permission", section.Slug)
	rec := execModeratorRequestWithAuth(t, handler, http.MethodGet, permPath, "", admin.ID, admin.Role)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var resp struct {
		Permission services.WaterSectionPermission `json:"permission"`
	}
	json.Unmarshal(rec.Body.Bytes(), &resp)
	if !resp.Permission.IsGlobalAdmin || !resp.Permission.CanManageModerators {
		t.Fatalf("admin should have full perms: %+v", resp.Permission)
	}
}

// 12. normal user my-permission returns all false
func TestNormalUserMyPermissionAllFalse(t *testing.T) {
	db := newModeratorTestDB(t)
	section := ensureTestSection(t, db)
	normal := newModeratorTestUser(t, db, models.RoleUser)

	handler := NewWaterModeratorHandler(db)
	permPath := fmt.Sprintf("/api/water/sections/%s/my-permission", section.Slug)
	rec := execModeratorRequestWithAuth(t, handler, http.MethodGet, permPath, "", normal.ID, normal.Role)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var resp struct {
		Permission services.WaterSectionPermission `json:"permission"`
	}
	json.Unmarshal(rec.Body.Bytes(), &resp)
	if resp.Permission.IsModerator || resp.Permission.CanPinPost {
		t.Fatalf("normal user should not have perms: %+v", resp.Permission)
	}
}

// 13. moderator only has permission on own section, not other
func TestModeratorOnlyOwnSection(t *testing.T) {
	db := newModeratorTestDB(t)
	section := ensureTestSection(t, db)
	admin := newModeratorTestUser(t, db, models.RoleAdmin)
	modUser := newModeratorTestUser(t, db, models.RoleUser)

	handler := NewWaterModeratorHandler(db)
	assignBody := fmt.Sprintf(`{"user_id":%d,"role":"moderator","reason":"test"}`, modUser.ID)
	assignPath := fmt.Sprintf("/api/admin/water/sections/%s/moderators", section.Slug)
	execModeratorRequestWithAuth(t, handler, http.MethodPost, assignPath, assignBody, admin.ID, admin.Role)

	// my-permission on own section
	permPath := fmt.Sprintf("/api/water/sections/%s/my-permission", section.Slug)
	rec := execModeratorRequestWithAuth(t, handler, http.MethodGet, permPath, "", modUser.ID, models.RoleUser)
	var resp struct {
		Permission services.WaterSectionPermission `json:"permission"`
	}
	json.Unmarshal(rec.Body.Bytes(), &resp)
	if !resp.Permission.CanPinPost || !resp.Permission.IsModerator {
		t.Fatalf("moderator should have perms on own section: %+v", resp.Permission)
	}
	if resp.Permission.CanManageModerators {
		t.Fatalf("moderator should never have CanManageModerators")
	}

	// my-permission on other section (campus_life)
	permPath2 := "/api/water/sections/campus_life/my-permission"
	rec2 := execModeratorRequestWithAuth(t, handler, http.MethodGet, permPath2, "", modUser.ID, models.RoleUser)
	json.Unmarshal(rec2.Body.Bytes(), &resp)
	if resp.Permission.IsModerator || resp.Permission.CanPinPost {
		t.Fatalf("moderator should not have perms on other section: %+v", resp.Permission)
	}
}

// 14. GET moderators only returns active, not revoked
func TestGetModeratorsOnlyActive(t *testing.T) {
	db := newModeratorTestDB(t)
	section := ensureTestSection(t, db)
	admin := newModeratorTestUser(t, db, models.RoleAdmin)
	mod1 := newModeratorTestUser(t, db, models.RoleUser)
	mod2 := newModeratorTestUser(t, db, models.RoleUser)

	handler := NewWaterModeratorHandler(db)
	assignPath := fmt.Sprintf("/api/admin/water/sections/%s/moderators", section.Slug)

	// assign mod1
	body1 := fmt.Sprintf(`{"user_id":%d,"role":"moderator","reason":"a"}`, mod1.ID)
	aRec := execModeratorRequestWithAuth(t, handler, http.MethodPost, assignPath, body1, admin.ID, admin.Role)
	var aResp struct {
		Moderator moderatorResponse `json:"moderator"`
	}
	json.Unmarshal(aRec.Body.Bytes(), &aResp)

	// assign mod2
	body2 := fmt.Sprintf(`{"user_id":%d,"role":"moderator","reason":"b"}`, mod2.ID)
	bRec := execModeratorRequestWithAuth(t, handler, http.MethodPost, assignPath, body2, admin.ID, admin.Role)
	var bResp struct {
		Moderator moderatorResponse `json:"moderator"`
	}
	json.Unmarshal(bRec.Body.Bytes(), &bResp)

	// revoke mod1
	delPath := fmt.Sprintf("/api/admin/water/sections/%s/moderators/%d", section.Slug, aResp.Moderator.ID)
	execModeratorRequestWithAuth(t, handler, http.MethodDelete, delPath, `{}`, admin.ID, admin.Role)

	// list
	listRec := execModeratorRequestWithAuth(t, handler, http.MethodGet, assignPath, "", admin.ID, admin.Role)
	var listResp struct {
		Moderators []moderatorResponse `json:"moderators"`
	}
	json.Unmarshal(listRec.Body.Bytes(), &listResp)
	if len(listResp.Moderators) != 1 {
		t.Fatalf("expected 1 active, got %d", len(listResp.Moderators))
	}
	if listResp.Moderators[0].UserID != mod2.ID {
		t.Fatalf("expected mod2 as only active, got user_id=%d", listResp.Moderators[0].UserID)
	}
}

// 15. section not found → 404 on all endpoints
func TestModeratorSectionNotFound(t *testing.T) {
	db := newModeratorTestDB(t)
	_ = ensureTestSection(t, db)
	admin := newModeratorTestUser(t, db, models.RoleAdmin)

	handler := NewWaterModeratorHandler(db)
	path := "/api/admin/water/sections/noexist/moderators"
	body := fmt.Sprintf(`{"user_id":%d,"role":"moderator","reason":"x"}`, admin.ID)
	rec := execModeratorRequestWithAuth(t, handler, http.MethodPost, path, body, admin.ID, admin.Role)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", rec.Code)
	}
}

package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// newWaterSectionTestDB 构造 in-memory DB，迁移 water 与 post 相关表。
func newWaterSectionTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	t.Setenv("UPLOAD_DIR", t.TempDir())
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.WaterTeamRecruitment{}, &models.WaterTeamApplication{},
		&models.User{},
		&models.File{},
		&models.FileUploadGrant{},
		&models.ImageVariant{},
		&models.Post{},
		&models.PostImage{},
		&models.Like{},
		&models.WaterSection{},
		&models.WaterSectionFollow{},
		&models.WaterSectionTag{},
		&models.WaterSectionModerator{},
		&models.WaterSectionPin{},
		&models.WaterSectionMute{},
		&models.WaterSectionUserStat{},
		&models.WaterSectionExpLog{},
		&models.WaterSectionLevelTitle{},
		&models.WaterModerationLog{},
		&models.ExpLog{},
		&models.FeaturedApplication{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

func performWaterSectionAuthGET(t *testing.T, handler gin.HandlerFunc, path string, userID uint) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	rec := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(rec)
	ctx.Request = httptest.NewRequest(http.MethodGet, path, nil)
	ctx.Set("user_id", userID)
	if slugStart := strings.Index(path, "/sections/"); slugStart >= 0 {
		slug := path[slugStart+len("/sections/"):]
		if slash := strings.Index(slug, "/"); slash >= 0 {
			slug = slug[:slash]
		}
		if question := strings.Index(slug, "?"); question >= 0 {
			slug = slug[:question]
		}
		ctx.Params = gin.Params{{Key: "slug", Value: slug}}
	}
	handler(ctx)
	return rec
}

func newWaterTestUser(t *testing.T, db *gorm.DB, eduBound bool) models.User {
	t.Helper()
	var verifiedAt *time.Time
	if eduBound {
		now := time.Now()
		verifiedAt = &now
	}
	user := models.User{
		StudentID: "20260100", StudentVerifiedAt: verifiedAt, PasswordHash: "x", Nickname: "tester",
		EduAuthorized: eduBound, EduBound: eduBound,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	return user
}

func newWaterSectionRoleUser(t *testing.T, db *gorm.DB, studentID string, role models.Role) models.User {
	t.Helper()
	user := models.User{
		StudentID:    studentID,
		PasswordHash: "x",
		Nickname:     studentID,
		Role:         role,
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create role user: %v", err)
	}
	return user
}

func addWaterSectionModerator(t *testing.T, db *gorm.DB, sectionID uint, userID uint, canEdit bool) {
	t.Helper()
	addWaterSectionModeratorWithPerms(t, db, sectionID, userID, canEdit, false)
}

func addWaterSectionModeratorWithPerms(t *testing.T, db *gorm.DB, sectionID uint, userID uint, canEdit bool, canManageTags bool) {
	t.Helper()
	mod := models.WaterSectionModerator{
		SectionID:      sectionID,
		UserID:         userID,
		Role:           models.ModeratorRoleModerator,
		CanEditSection: canEdit,
		CanManageTags:  canManageTags,
		CanPinPost:     false,
		CanDeletePost:  false,
		CanMuteUser:    false,
		Status:         models.ModeratorStatusActive,
		AssignedBy:     userID,
		AssignReason:   "test",
	}
	if err := db.Create(&mod).Error; err != nil {
		t.Fatalf("create moderator: %v", err)
	}
}

func performWaterSectionGET(t *testing.T, handler gin.HandlerFunc, path string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	rec := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(rec)
	ctx.Request = httptest.NewRequest(http.MethodGet, path, nil)
	if slugStart := strings.Index(path, "/sections/"); slugStart >= 0 {
		slug := path[slugStart+len("/sections/"):]
		if slash := strings.Index(slug, "/"); slash >= 0 {
			slug = slug[:slash]
		}
		if question := strings.Index(slug, "?"); question >= 0 {
			slug = slug[:question]
		}
		ctx.Params = gin.Params{{Key: "slug", Value: slug}}
	}
	handler(ctx)
	return rec
}

func performWaterSectionJSON(t *testing.T, handler gin.HandlerFunc, method, path string, userID uint, body string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	rec := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(rec)
	ctx.Request = httptest.NewRequest(method, path, strings.NewReader(body))
	ctx.Request.Header.Set("Content-Type", "application/json")
	ctx.Set("user_id", userID)
	parts := strings.Split(strings.Trim(path, "/"), "/")
	params := gin.Params{}
	for i, part := range parts {
		if part == "sections" && i+1 < len(parts) {
			params = append(params, gin.Param{Key: "slug", Value: parts[i+1]})
		}
		if part == "tags" && i+1 < len(parts) {
			params = append(params, gin.Param{Key: "tag_id", Value: parts[i+1]})
		}
	}
	ctx.Params = params
	handler(ctx)
	return rec
}

func performWaterSectionPATCH(t *testing.T, handler gin.HandlerFunc, path string, userID uint, body string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	rec := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(rec)
	ctx.Request = httptest.NewRequest(http.MethodPatch, path, strings.NewReader(body))
	ctx.Request.Header.Set("Content-Type", "application/json")
	ctx.Set("user_id", userID)
	if slugStart := strings.Index(path, "/sections/"); slugStart >= 0 {
		slug := path[slugStart+len("/sections/"):]
		if slash := strings.Index(slug, "/"); slash >= 0 {
			slug = slug[:slash]
		}
		ctx.Params = gin.Params{{Key: "slug", Value: slug}}
	}
	handler(ctx)
	return rec
}

func performPostListGET(t *testing.T, handler gin.HandlerFunc, path string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	rec := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(rec)
	ctx.Request = httptest.NewRequest(http.MethodGet, path, nil)
	handler(ctx)
	return rec
}

func performPostCreate(t *testing.T, handler gin.HandlerFunc, userID uint, form url.Values) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	rec := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(rec)
	body := form.Encode()
	ctx.Request = httptest.NewRequest(http.MethodPost, "/api/posts", strings.NewReader(body))
	ctx.Request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	ctx.Set("user_id", userID)
	handler(ctx)
	return rec
}

// 1. EnsureWaterSections 可重复执行且不覆盖管理员已修改字段。
func TestEnsureWaterSectionsIdempotent(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("first ensure: %v", err)
	}
	// 故意修改课程学习版块标题
	if err := db.Model(&models.WaterSection{}).Where("slug = ?", "course_study").Update("title", "选课与课程经验").Error; err != nil {
		t.Fatalf("modify title: %v", err)
	}
	var tagCountBeforeEnsure int64
	db.Model(&models.WaterSectionTag{}).Count(&tagCountBeforeEnsure)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("second ensure: %v", err)
	}
	var sectionCount int64
	db.Model(&models.WaterSection{}).Count(&sectionCount)
	if sectionCount != 7 {
		t.Fatalf("expected 7 sections, got %d", sectionCount)
	}
	var tagCount int64
	db.Model(&models.WaterSectionTag{}).Count(&tagCount)
	if tagCount != tagCountBeforeEnsure {
		t.Fatalf("ensure should not duplicate tags: before=%d after=%d", tagCountBeforeEnsure, tagCount)
	}
	var cs models.WaterSection
	db.Where("slug = ?", "course_study").First(&cs)
	if cs.Title != "选课与课程经验" {
		t.Fatalf("seed should not overwrite admin title, got %q", cs.Title)
	}
}

// 2. GET /api/water/sections 返回 7 个 active 版块，按 sort_order 升序，带 tags。
func TestListSections(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	handler := NewWaterSectionHandler(db)
	rec := performWaterSectionGET(t, handler.List, "/api/water/sections")
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		Sections []map[string]interface{} `json:"sections"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body.Sections) != 7 {
		t.Fatalf("expected 7 sections, got %d", len(body.Sections))
	}
	for i, s := range body.Sections {
		tags, ok := s["tags"].([]interface{})
		if !ok || len(tags) == 0 {
			t.Fatalf("section %d missing tags: %v", i, s)
		}
	}
	// 断言 sort_order 升序
	firstOrder := body.Sections[0]["sort_order"].(float64)
	for i := 1; i < len(body.Sections); i++ {
		cur := body.Sections[i]["sort_order"].(float64)
		if cur <= firstOrder {
			t.Fatalf("sections not sorted by sort_order ASC: %v then %v", firstOrder, cur)
		}
		firstOrder = cur
	}
}

// 水区帖子数必须按 posts.post_type 聚合，且只统计正常状态的帖子。
func TestListSectionsReturnsPostCounts(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	user := newWaterTestUser(t, db, false)
	posts := []models.Post{
		{BoardID: models.BoardShuitie, AuthorID: user.ID, PostType: "course_study", Status: models.PostStatusNormal},
		{BoardID: models.BoardShuitie, AuthorID: user.ID, PostType: "course_study", Status: models.PostStatusNormal},
		{BoardID: models.BoardShuitie, AuthorID: user.ID, PostType: "course_study", Status: models.PostStatusDeleted},
		{BoardID: models.BoardShuitie, AuthorID: user.ID, PostType: "campus_life", Status: models.PostStatusNormal},
	}
	if err := db.Create(&posts).Error; err != nil {
		t.Fatalf("create posts: %v", err)
	}

	handler := NewWaterSectionHandler(db)
	rec := performWaterSectionGET(t, handler.List, "/api/water/sections")
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		Sections []waterSectionResponse `json:"sections"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}

	counts := make(map[string]int64, len(body.Sections))
	for _, section := range body.Sections {
		counts[section.Slug] = section.PostCount
	}
	if counts["course_study"] != 2 {
		t.Fatalf("course_study post_count=%d, want 2", counts["course_study"])
	}
	if counts["campus_life"] != 1 {
		t.Fatalf("campus_life post_count=%d, want 1", counts["campus_life"])
	}
}

// 3. GET /api/water/sections/course_study 返回版块及 exam 标签。
func TestGetSectionBySlug(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	handler := NewWaterSectionHandler(db)
	rec := performWaterSectionGET(t, handler.Get, "/api/water/sections/course_study")
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		Section map[string]interface{} `json:"section"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Section["slug"] != "course_study" {
		t.Fatalf("unexpected slug: %v", body.Section["slug"])
	}
	tags, _ := body.Section["tags"].([]interface{})
	foundExam := false
	for _, tAny := range tags {
		tag := tAny.(map[string]interface{})
		if tag["slug"] == "exam" {
			foundExam = true
		}
	}
	if !foundExam {
		t.Fatalf("expected exam tag, got: %v", tags)
	}
}

// 4. GET /api/water/sections/not-exist-slug 返回 404。
func TestGetSectionBySlugNotFound(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	handler := NewWaterSectionHandler(db)
	rec := performWaterSectionGET(t, handler.Get, "/api/water/sections/not-exist-slug")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestUpdateWaterSectionByAdmin(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	admin := newWaterSectionRoleUser(t, db, "admin_edit_section", models.RoleAdmin)
	handler := NewWaterSectionHandler(db)

	body := `{
		"title":"选课与课程经验",
		"subtitle":"选课、考试、老师、学习资料",
		"description":"这里用于交流课程学习相关内容",
		"color_hex":"#2DBE72",
		"publish_action_text":"提一个问题",
		"empty_title":"还没有课程学习内容",
		"empty_description":"可以分享选课、考试、老师评价或学习资料。",
		"starter_questions":["这门课难不难？","老师给分怎么样？"],
		"notice_text":"",
		"default_sort":"all",
		"reason":"优化版块展示文案"
	}`
	rec := performWaterSectionPATCH(t, handler.Update, "/api/water/sections/course_study", admin.ID, body)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Section waterSectionResponse `json:"section"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.Section.Title != "选课与课程经验" || resp.Section.DefaultSort != "all" {
		t.Fatalf("section not updated: %+v", resp.Section)
	}
	if len(resp.Section.StarterQuestions) != 2 || resp.Section.StarterQuestions[0] != "这门课难不难？" {
		t.Fatalf("starter_questions not updated: %+v", resp.Section.StarterQuestions)
	}
}

func TestUpdateWaterSectionBySuperAdminAnySection(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	superAdmin := newWaterSectionRoleUser(t, db, "super_edit_section", models.RoleSuperAdmin)
	handler := NewWaterSectionHandler(db)

	rec := performWaterSectionPATCH(t, handler.Update, "/api/water/sections/campus_life", superAdmin.ID, `{"title":"校园生活新版"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	var section models.WaterSection
	if err := db.Where("slug = ?", "campus_life").First(&section).Error; err != nil {
		t.Fatalf("find section: %v", err)
	}
	if section.Title != "校园生活新版" {
		t.Fatalf("expected title updated, got %q", section.Title)
	}
}

func TestUpdateWaterSectionByEditableModerator(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	var section models.WaterSection
	db.Where("slug = ?", "course_study").First(&section)
	modUser := newWaterSectionRoleUser(t, db, "mod_can_edit_section", models.RoleUser)
	addWaterSectionModerator(t, db, section.ID, modUser.ID, true)
	handler := NewWaterSectionHandler(db)

	rec := performWaterSectionPATCH(t, handler.Update, "/api/water/sections/course_study", modUser.ID, `{"subtitle":"新版课程副标题"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	db.First(&section, section.ID)
	if section.Subtitle != "新版课程副标题" {
		t.Fatalf("expected subtitle updated, got %q", section.Subtitle)
	}
}

func TestUpdateWaterSectionForbiddenWithoutEditPermission(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	var section models.WaterSection
	db.Where("slug = ?", "course_study").First(&section)
	modUser := newWaterSectionRoleUser(t, db, "mod_no_edit_section", models.RoleUser)
	addWaterSectionModerator(t, db, section.ID, modUser.ID, false)
	handler := NewWaterSectionHandler(db)

	rec := performWaterSectionPATCH(t, handler.Update, "/api/water/sections/course_study", modUser.ID, `{"title":"不应成功"}`)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestUpdateWaterSectionModeratorCannotEditOtherSection(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	var course models.WaterSection
	db.Where("slug = ?", "course_study").First(&course)
	modUser := newWaterSectionRoleUser(t, db, "mod_other_section", models.RoleUser)
	addWaterSectionModerator(t, db, course.ID, modUser.ID, true)
	handler := NewWaterSectionHandler(db)

	rec := performWaterSectionPATCH(t, handler.Update, "/api/water/sections/campus_life", modUser.ID, `{"title":"不应成功"}`)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestUpdateWaterSectionForbiddenForRegularUser(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	user := newWaterSectionRoleUser(t, db, "plain_edit_section", models.RoleUser)
	handler := NewWaterSectionHandler(db)

	rec := performWaterSectionPATCH(t, handler.Update, "/api/water/sections/course_study", user.ID, `{"title":"不应成功"}`)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestUpdateWaterSectionValidation(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{name: "empty title", body: `{"title":""}`},
		{name: "invalid color", body: `{"color_hex":"2DBE72"}`},
		{name: "too many starter questions", body: `{"starter_questions":["1","2","3","4","5","6","7","8","9","10","11"]}`},
		{name: "invalid default sort", body: `{"default_sort":"popular"}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			db := newWaterSectionTestDB(t)
			if err := models.EnsureWaterSections(db); err != nil {
				t.Fatalf("ensure: %v", err)
			}
			admin := newWaterSectionRoleUser(t, db, "admin_"+strings.ReplaceAll(tc.name, " ", "_"), models.RoleAdmin)
			handler := NewWaterSectionHandler(db)
			rec := performWaterSectionPATCH(t, handler.Update, "/api/water/sections/course_study", admin.ID, tc.body)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("expected 400, got %d body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestUpdateWaterSectionWritesModerationLog(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	admin := newWaterSectionRoleUser(t, db, "admin_log_section", models.RoleAdmin)
	handler := NewWaterSectionHandler(db)

	rec := performWaterSectionPATCH(t, handler.Update, "/api/water/sections/course_study", admin.ID, `{"title":"日志测试标题","reason":"测试日志"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	var section models.WaterSection
	db.Where("slug = ?", "course_study").First(&section)
	var log models.WaterModerationLog
	if err := db.Where("section_id = ? AND action = ?", section.ID, models.ModActionEditSection).First(&log).Error; err != nil {
		t.Fatalf("find log: %v", err)
	}
	if log.TargetType != "section" || log.TargetID != section.ID || log.Reason != "测试日志" {
		t.Fatalf("unexpected log: %+v", log)
	}
	if !strings.Contains(log.Snapshot, `"before"`) || !strings.Contains(log.Snapshot, `"after"`) {
		t.Fatalf("snapshot should include before/after, got %s", log.Snapshot)
	}
}

func TestUpdateWaterSectionIgnoresStructuralFields(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	admin := newWaterSectionRoleUser(t, db, "admin_struct_section", models.RoleAdmin)
	var before models.WaterSection
	db.Where("slug = ?", "course_study").First(&before)
	handler := NewWaterSectionHandler(db)

	body := `{
		"title":"结构字段测试",
		"slug":"changed_slug",
		"status":"disabled",
		"sort_order":999,
		"sensitive_level":"strict"
	}`
	rec := performWaterSectionPATCH(t, handler.Update, "/api/water/sections/course_study", admin.ID, body)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	var after models.WaterSection
	if err := db.First(&after, before.ID).Error; err != nil {
		t.Fatalf("find section: %v", err)
	}
	if after.Slug != before.Slug || after.Status != before.Status || after.SortOrder != before.SortOrder || after.SensitiveLevel != before.SensitiveLevel {
		t.Fatalf("structural fields changed: before=%+v after=%+v", before, after)
	}
	if after.Title != "结构字段测试" {
		t.Fatalf("allowed field should update, got %q", after.Title)
	}
}

func TestCreateWaterSectionTagPermissions(t *testing.T) {
	cases := []struct {
		name       string
		userRole   models.Role
		modSection string
		canManage  bool
		path       string
		wantStatus int
	}{
		{name: "admin", userRole: models.RoleAdmin, path: "/api/water/sections/course_study/tags", wantStatus: http.StatusCreated},
		{name: "super admin", userRole: models.RoleSuperAdmin, path: "/api/water/sections/campus_life/tags", wantStatus: http.StatusCreated},
		{name: "section moderator", userRole: models.RoleUser, modSection: "course_study", canManage: true, path: "/api/water/sections/course_study/tags", wantStatus: http.StatusCreated},
		{name: "moderator without permission", userRole: models.RoleUser, modSection: "course_study", canManage: false, path: "/api/water/sections/course_study/tags", wantStatus: http.StatusForbidden},
		{name: "other section moderator", userRole: models.RoleUser, modSection: "course_study", canManage: true, path: "/api/water/sections/campus_life/tags", wantStatus: http.StatusForbidden},
		{name: "regular user", userRole: models.RoleUser, path: "/api/water/sections/course_study/tags", wantStatus: http.StatusForbidden},
	}

	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			db := newWaterSectionTestDB(t)
			if err := models.EnsureWaterSections(db); err != nil {
				t.Fatalf("ensure: %v", err)
			}
			user := newWaterSectionRoleUser(t, db, fmt.Sprintf("tag_perm_%d", i), tc.userRole)
			if tc.modSection != "" {
				var section models.WaterSection
				db.Where("slug = ?", tc.modSection).First(&section)
				addWaterSectionModeratorWithPerms(t, db, section.ID, user.ID, false, tc.canManage)
			}
			handler := NewWaterSectionHandler(db)
			body := fmt.Sprintf(`{"slug":"new_tag_%d","name":"新标签%d","description":"测试","sort_order":10,"reason":"新增标签"}`, i, i)
			rec := performWaterSectionJSON(t, handler.CreateTag, http.MethodPost, tc.path, user.ID, body)
			if rec.Code != tc.wantStatus {
				t.Fatalf("expected %d, got %d body=%s", tc.wantStatus, rec.Code, rec.Body.String())
			}
		})
	}
}

func TestCreateWaterSectionTagValidationAndDuplicates(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{name: "invalid slug", body: `{"slug":"Bad Slug","name":"合法名称"}`},
		{name: "empty name", body: `{"slug":"valid_slug","name":""}`},
		{name: "duplicate slug", body: `{"slug":"exam","name":"新考试"}`},
		{name: "duplicate name", body: `{"slug":"new_exam","name":"考试"}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			db := newWaterSectionTestDB(t)
			if err := models.EnsureWaterSections(db); err != nil {
				t.Fatalf("ensure: %v", err)
			}
			admin := newWaterSectionRoleUser(t, db, "tag_validation_"+strings.ReplaceAll(tc.name, " ", "_"), models.RoleAdmin)
			handler := NewWaterSectionHandler(db)
			rec := performWaterSectionJSON(t, handler.CreateTag, http.MethodPost, "/api/water/sections/course_study/tags", admin.ID, tc.body)
			if rec.Code != http.StatusBadRequest && rec.Code != http.StatusConflict {
				t.Fatalf("expected 400/409, got %d body=%s", rec.Code, rec.Body.String())
			}
		})
	}

	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	admin := newWaterSectionRoleUser(t, db, "tag_duplicate_cross_section", models.RoleAdmin)
	handler := NewWaterSectionHandler(db)
	rec := performWaterSectionJSON(t, handler.CreateTag, http.MethodPost, "/api/water/sections/campus_life/tags", admin.ID, `{"slug":"exam","name":"考试"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("same slug/name in different section should be allowed, got %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestCreateWaterSectionTagWritesLog(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	admin := newWaterSectionRoleUser(t, db, "tag_create_log_admin", models.RoleAdmin)
	handler := NewWaterSectionHandler(db)
	rec := performWaterSectionJSON(t, handler.CreateTag, http.MethodPost, "/api/water/sections/course_study/tags",
		admin.ID, `{"slug":"create_log","name":"创建日志","reason":"新增创建日志标签"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d body=%s", rec.Code, rec.Body.String())
	}
	var tag models.WaterSectionTag
	if err := db.Where("slug = ?", "create_log").First(&tag).Error; err != nil {
		t.Fatalf("find tag: %v", err)
	}
	var log models.WaterModerationLog
	if err := db.Where("target_id = ? AND action = ?", tag.ID, models.ModActionCreateTag).First(&log).Error; err != nil {
		t.Fatalf("find log: %v", err)
	}
	if log.TargetType != "tag" || log.Reason != "新增创建日志标签" || !strings.Contains(log.Snapshot, `"after"`) {
		t.Fatalf("unexpected log: %+v", log)
	}
}

func TestUpdateWaterSectionTagFieldsAndKeepsSlug(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	admin := newWaterSectionRoleUser(t, db, "tag_update_admin", models.RoleAdmin)
	var section models.WaterSection
	var tag models.WaterSectionTag
	db.Where("slug = ?", "course_study").First(&section)
	db.Where("section_id = ? AND slug = ?", section.ID, "exam").First(&tag)
	handler := NewWaterSectionHandler(db)

	path := fmt.Sprintf("/api/water/sections/course_study/tags/%d", tag.ID)
	rec := performWaterSectionJSON(t, handler.UpdateTag, http.MethodPatch, path, admin.ID,
		`{"slug":"changed_slug","name":"考试安排","description":"考试安排、复习经验、往年题型","sort_order":30,"is_default":true,"reason":"优化标签名称"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	var updated models.WaterSectionTag
	db.First(&updated, tag.ID)
	if updated.Slug != tag.Slug {
		t.Fatalf("slug should not change, got %q", updated.Slug)
	}
	if updated.Name != "考试安排" || updated.Description == "" || updated.SortOrder != 30 || !updated.IsDefault {
		t.Fatalf("tag fields not updated: %+v", updated)
	}
}

func TestUpdateWaterSectionTagWritesLog(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	admin := newWaterSectionRoleUser(t, db, "tag_update_log_admin", models.RoleAdmin)
	var section models.WaterSection
	var tag models.WaterSectionTag
	db.Where("slug = ?", "course_study").First(&section)
	db.Where("section_id = ? AND slug = ?", section.ID, "exam").First(&tag)
	handler := NewWaterSectionHandler(db)

	path := fmt.Sprintf("/api/water/sections/course_study/tags/%d", tag.ID)
	rec := performWaterSectionJSON(t, handler.UpdateTag, http.MethodPatch, path, admin.ID, `{"name":"考试安排","reason":"记录修改"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	var log models.WaterModerationLog
	if err := db.Where("section_id = ? AND target_id = ? AND action = ?", section.ID, tag.ID, models.ModActionUpdateTag).First(&log).Error; err != nil {
		t.Fatalf("find log: %v", err)
	}
	if log.TargetType != "tag" || log.Reason != "记录修改" || !strings.Contains(log.Snapshot, `"before"`) || !strings.Contains(log.Snapshot, `"after"`) {
		t.Fatalf("unexpected log: %+v", log)
	}
}

func TestUpdateWaterSectionTagStatusLogs(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	admin := newWaterSectionRoleUser(t, db, "tag_status_admin", models.RoleAdmin)
	var section models.WaterSection
	var tag models.WaterSectionTag
	db.Where("slug = ?", "course_study").First(&section)
	db.Where("section_id = ? AND slug = ?", section.ID, "exam").First(&tag)
	handler := NewWaterSectionHandler(db)
	path := fmt.Sprintf("/api/water/sections/course_study/tags/%d/status", tag.ID)

	disable := performWaterSectionJSON(t, handler.UpdateTagStatus, http.MethodPatch, path, admin.ID, `{"is_enabled":false,"reason":"暂停使用"}`)
	if disable.Code != http.StatusOK {
		t.Fatalf("disable expected 200, got %d body=%s", disable.Code, disable.Body.String())
	}
	enable := performWaterSectionJSON(t, handler.UpdateTagStatus, http.MethodPatch, path, admin.ID, `{"is_enabled":true,"reason":"恢复使用"}`)
	if enable.Code != http.StatusOK {
		t.Fatalf("enable expected 200, got %d body=%s", enable.Code, enable.Body.String())
	}
	for _, action := range []string{models.ModActionDisableTag, models.ModActionEnableTag} {
		var count int64
		db.Model(&models.WaterModerationLog{}).Where("section_id = ? AND target_id = ? AND action = ?", section.ID, tag.ID, action).Count(&count)
		if count != 1 {
			t.Fatalf("expected one %s log, got %d", action, count)
		}
	}
}

func TestDisabledWaterSectionTagCannotBeUsedForNewPostAndOldPostKeepsTag(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	user := newWaterTestUser(t, db, false)
	var section models.WaterSection
	var tag models.WaterSectionTag
	db.Where("slug = ?", "course_study").First(&section)
	db.Where("section_id = ? AND slug = ?", section.ID, "exam").First(&tag)
	oldPost := models.Post{
		Title:      "old tagged",
		Content:    "old tagged content",
		BoardID:    models.BoardShuitie,
		AuthorID:   user.ID,
		PostType:   section.Slug,
		Status:     models.PostStatusNormal,
		WaterTagID: &tag.ID,
	}
	if err := db.Create(&oldPost).Error; err != nil {
		t.Fatalf("create old post: %v", err)
	}
	if err := db.Model(&tag).Update("is_enabled", false).Error; err != nil {
		t.Fatalf("disable tag: %v", err)
	}

	form := url.Values{}
	form.Set("content", "new tagged content")
	form.Set("board_id", "1")
	form.Set("post_type", section.Slug)
	form.Set("water_tag_id", fmt.Sprintf("%d", tag.ID))
	rec := performPostCreate(t, NewPostHandler(db, "", "").Create, user.ID, form)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("disabled tag should reject new post, got %d body=%s", rec.Code, rec.Body.String())
	}
	var loaded models.Post
	if err := db.First(&loaded, oldPost.ID).Error; err != nil {
		t.Fatalf("load old post: %v", err)
	}
	if loaded.WaterTagID == nil || *loaded.WaterTagID != tag.ID {
		t.Fatalf("old post water_tag_id should stay, got %+v", loaded.WaterTagID)
	}
}

func TestGetWaterSectionManageTagsRequiresPermissionAndIncludesArchived(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	handler := NewWaterSectionHandler(db)
	admin := newWaterSectionRoleUser(t, db, "tag_manage_admin", models.RoleAdmin)
	plain := newWaterSectionRoleUser(t, db, "tag_manage_plain", models.RoleUser)
	var section models.WaterSection
	var tag models.WaterSectionTag
	db.Where("slug = ?", "course_study").First(&section)
	db.Where("section_id = ? AND slug = ?", section.ID, "exam").First(&tag)
	if err := db.Model(&tag).Update("is_enabled", false).Error; err != nil {
		t.Fatalf("archive tag: %v", err)
	}

	regular := performWaterSectionAuthGET(t, handler.Get, "/api/water/sections/course_study", admin.ID)
	if regular.Code != http.StatusOK {
		t.Fatalf("regular get expected 200, got %d body=%s", regular.Code, regular.Body.String())
	}
	var regularBody struct {
		Section struct {
			Tags []waterSectionTagResponse `json:"tags"`
		} `json:"section"`
	}
	if err := json.Unmarshal(regular.Body.Bytes(), &regularBody); err != nil {
		t.Fatalf("decode regular body: %v", err)
	}
	for _, got := range regularBody.Section.Tags {
		if got.ID == tag.ID {
			t.Fatalf("regular get should hide archived tag, got %+v", got)
		}
	}

	forbidden := performWaterSectionAuthGET(t, handler.Get, "/api/water/sections/course_study?include_disabled_tags=true", plain.ID)
	if forbidden.Code != http.StatusForbidden {
		t.Fatalf("plain user expected 403, got %d body=%s", forbidden.Code, forbidden.Body.String())
	}

	managed := performWaterSectionAuthGET(t, handler.Get, "/api/water/sections/course_study?include_disabled_tags=true", admin.ID)
	if managed.Code != http.StatusOK {
		t.Fatalf("managed get expected 200, got %d body=%s", managed.Code, managed.Body.String())
	}
	var managedBody struct {
		Section struct {
			Tags []waterSectionTagResponse `json:"tags"`
		} `json:"section"`
	}
	if err := json.Unmarshal(managed.Body.Bytes(), &managedBody); err != nil {
		t.Fatalf("decode managed body: %v", err)
	}
	foundArchived := false
	for _, got := range managedBody.Section.Tags {
		if got.ID == tag.ID {
			foundArchived = true
			if got.IsEnabled {
				t.Fatalf("managed get should preserve archived status, got %+v", got)
			}
		}
	}
	if !foundArchived {
		t.Fatalf("managed get should include archived tag id=%d, tags=%+v", tag.ID, managedBody.Section.Tags)
	}
}

func TestWaterSectionTagManagementNotFoundCases(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	admin := newWaterSectionRoleUser(t, db, "tag_not_found_admin", models.RoleAdmin)
	handler := NewWaterSectionHandler(db)

	missingSection := performWaterSectionJSON(t, handler.CreateTag, http.MethodPost, "/api/water/sections/not_exist/tags", admin.ID, `{"slug":"x","name":"X"}`)
	if missingSection.Code != http.StatusNotFound {
		t.Fatalf("expected missing section 404, got %d body=%s", missingSection.Code, missingSection.Body.String())
	}

	var course models.WaterSection
	var campus models.WaterSection
	var campusTag models.WaterSectionTag
	db.Where("slug = ?", "course_study").First(&course)
	db.Where("slug = ?", "campus_life").First(&campus)
	db.Where("section_id = ? AND slug = ?", campus.ID, "canteen").First(&campusTag)
	path := fmt.Sprintf("/api/water/sections/course_study/tags/%d", campusTag.ID)
	wrongSection := performWaterSectionJSON(t, handler.UpdateTag, http.MethodPatch, path, admin.ID, `{"name":"错误版块"}`)
	if wrongSection.Code != http.StatusNotFound {
		t.Fatalf("expected wrong section tag 404, got %d body=%s", wrongSection.Code, wrongSection.Body.String())
	}
	_ = course
}

// 5. GET /api/posts?board=1&type=course_study&tag_id=xxx 只返回该 tag 下帖子。
func TestGetListWithTagIdFilter(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	user := newWaterTestUser(t, db, false)
	// 找到 course_study 的 exam tag
	var examTag models.WaterSectionTag
	var csSection models.WaterSection
	db.Where("slug = ?", "course_study").First(&csSection)
	db.Where("section_id = ? AND slug = ?", csSection.ID, "exam").First(&examTag)
	tagID := examTag.ID

	tagged := models.Post{
		Title:      "tagged",
		Content:    "with tag",
		BoardID:    models.BoardShuitie,
		AuthorID:   user.ID,
		PostType:   "course_study",
		Status:     models.PostStatusNormal,
		WaterTagID: &tagID,
	}
	untagged := models.Post{
		Title:    "untagged",
		Content:  "no tag",
		BoardID:  models.BoardShuitie,
		AuthorID: user.ID,
		PostType: "course_study",
		Status:   models.PostStatusNormal,
	}
	if err := db.Create(&tagged).Error; err != nil {
		t.Fatalf("create tagged post: %v", err)
	}
	if err := db.Create(&untagged).Error; err != nil {
		t.Fatalf("create untagged post: %v", err)
	}

	handler := NewPostHandler(db, "", "")
	rec := performPostListGET(t, handler.GetList,
		fmt.Sprintf("/api/posts?board=1&type=course_study&tag_id=%d&sort=time&page=1&limit=10", tagID))
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		Posts []models.Post `json:"posts"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body.Posts) != 1 || body.Posts[0].ID != tagged.ID {
		t.Fatalf("expected only tagged post, got: %+v", body.Posts)
	}
}

func TestGetListCampusLifeIncludesLegacyEmptyPostType(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	user := newWaterTestUser(t, db, false)
	campusPost := models.Post{
		Title:    "campus",
		Content:  "campus content",
		BoardID:  models.BoardShuitie,
		AuthorID: user.ID,
		PostType: "campus_life",
		Status:   models.PostStatusNormal,
	}
	legacyPost := models.Post{
		Title:    "legacy",
		Content:  "legacy content",
		BoardID:  models.BoardShuitie,
		AuthorID: user.ID,
		Status:   models.PostStatusNormal,
	}
	coursePost := models.Post{
		Title:    "course",
		Content:  "course content",
		BoardID:  models.BoardShuitie,
		AuthorID: user.ID,
		PostType: "course_study",
		Status:   models.PostStatusNormal,
	}
	for _, post := range []*models.Post{&campusPost, &legacyPost, &coursePost} {
		if err := db.Create(post).Error; err != nil {
			t.Fatalf("create post: %v", err)
		}
	}

	handler := NewPostHandler(db, "", "")
	rec := performPostListGET(t, handler.GetList,
		"/api/posts?board=1&type=campus_life&sort=time&page=1&limit=10")
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		Posts []models.Post `json:"posts"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	gotIDs := map[uint]bool{}
	for _, post := range body.Posts {
		gotIDs[post.ID] = true
	}
	if len(body.Posts) != 2 || !gotIDs[campusPost.ID] || !gotIDs[legacyPost.ID] {
		t.Fatalf("expected campus and legacy posts, got: %s", rec.Body.String())
	}

	courseRec := performPostListGET(t, handler.GetList,
		"/api/posts?board=1&type=course_study&sort=time&page=1&limit=10")
	if courseRec.Code != http.StatusOK {
		t.Fatalf("course status=%d body=%s", courseRec.Code, courseRec.Body.String())
	}
	var courseBody struct {
		Posts []models.Post `json:"posts"`
	}
	if err := json.Unmarshal(courseRec.Body.Bytes(), &courseBody); err != nil {
		t.Fatalf("decode course: %v", err)
	}
	if len(courseBody.Posts) != 1 || courseBody.Posts[0].ID != coursePost.ID {
		t.Fatalf("expected only course post, got: %s", courseRec.Body.String())
	}
}

func TestGetListCampusLifeSnapshotIncludesLegacyEmptyPostType(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	user := newWaterTestUser(t, db, false)
	campusPost := models.Post{
		Title:    "campus snapshot",
		Content:  "campus content",
		BoardID:  models.BoardShuitie,
		AuthorID: user.ID,
		PostType: "campus_life",
		Status:   models.PostStatusNormal,
	}
	legacyPost := models.Post{
		Title:    "legacy snapshot",
		Content:  "legacy content",
		BoardID:  models.BoardShuitie,
		AuthorID: user.ID,
		Status:   models.PostStatusNormal,
	}
	coursePost := models.Post{
		Title:    "course snapshot",
		Content:  "course content",
		BoardID:  models.BoardShuitie,
		AuthorID: user.ID,
		PostType: "course_study",
		Status:   models.PostStatusNormal,
	}
	for _, post := range []*models.Post{&campusPost, &legacyPost, &coursePost} {
		if err := db.Create(post).Error; err != nil {
			t.Fatalf("create post: %v", err)
		}
	}

	rec := performPostListGET(t, NewPostHandler(db, "", "").GetList,
		"/api/posts?board=1&type=campus_life&sort=hot&scene=refresh&page=1&limit=10")
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		Total     int           `json:"total"`
		SessionID string        `json:"session_id"`
		Posts     []models.Post `json:"posts"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	gotIDs := map[uint]bool{}
	for _, post := range body.Posts {
		gotIDs[post.ID] = true
	}
	if body.Total != 2 ||
		body.SessionID == "" ||
		len(body.Posts) != 2 ||
		!gotIDs[campusPost.ID] ||
		!gotIDs[legacyPost.ID] {
		t.Fatalf("expected snapshot posts to include campus and legacy, got: %s", rec.Body.String())
	}
	ActiveSnapshots.Delete(body.SessionID)
}

// 6. 发水帖 board=1 post_type=course_study water_tag_id=<course_study 的 tag> 成功。
func TestCreateWaterPostWithValidTag(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	user := newWaterTestUser(t, db, false)
	var examTag models.WaterSectionTag
	var csSection models.WaterSection
	db.Where("slug = ?", "course_study").First(&csSection)
	db.Where("section_id = ? AND slug = ?", csSection.ID, "exam").First(&examTag)

	form := url.Values{}
	form.Set("content", "test content")
	form.Set("board_id", "1")
	form.Set("post_type", "course_study")
	form.Set("water_tag_id", fmt.Sprintf("%d", examTag.ID))

	handler := NewPostHandler(db, "", "")
	rec := performPostCreate(t, handler.Create, user.ID, form)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d body=%s", rec.Code, rec.Body.String())
	}
	var post models.Post
	if err := json.Unmarshal(rec.Body.Bytes(), &post); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if post.WaterTagID == nil || *post.WaterTagID != examTag.ID {
		t.Fatalf("expected water_tag_id=%d, got %v", examTag.ID, post.WaterTagID)
	}
}

// 7. 发水帖 tag_id 不属于 post_type 对应 section，返回 400。
func TestCreateWaterPostWithWrongSectionTag(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	user := newWaterTestUser(t, db, false)
	var canteenTag models.WaterSectionTag
	var clSection models.WaterSection
	db.Where("slug = ?", "campus_life").First(&clSection)
	db.Where("section_id = ? AND slug = ?", clSection.ID, "canteen").First(&canteenTag)

	form := url.Values{}
	form.Set("content", "test content")
	form.Set("board_id", "1")
	form.Set("post_type", "course_study")
	form.Set("water_tag_id", fmt.Sprintf("%d", canteenTag.ID))

	handler := NewPostHandler(db, "", "")
	rec := performPostCreate(t, handler.Create, user.ID, form)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d body=%s", rec.Code, rec.Body.String())
	}
}

// 8. 发集市帖 board=2 post_type=marketplace_sell 不受 water_tag_id 影响。
func TestCreateMarketPostIgnoresWaterTag(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	user := newWaterTestUser(t, db, true) // edu_bound=true 才能发集市帖
	var examTag models.WaterSectionTag
	var csSection models.WaterSection
	db.Where("slug = ?", "course_study").First(&csSection)
	db.Where("section_id = ? AND slug = ?", csSection.ID, "exam").First(&examTag)

	form := url.Values{}
	form.Set("content", "market content")
	form.Set("board_id", "2")
	form.Set("post_type", "marketplace_sell")
	form.Set("water_tag_id", fmt.Sprintf("%d", examTag.ID))
	image := createWaterSectionTestImage(t, db, user.ID)
	form.Set("file_ids", strconv.FormatUint(uint64(image.ID), 10))

	handler := NewPostHandler(db, "", "")
	rec := performPostCreate(t, handler.Create, user.ID, form)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d body=%s", rec.Code, rec.Body.String())
	}
	var post models.Post
	if err := json.Unmarshal(rec.Body.Bytes(), &post); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if post.WaterTagID != nil {
		t.Fatalf("market post must not store water_tag_id, got %v", post.WaterTagID)
	}
}

func createWaterSectionTestImage(t *testing.T, db *gorm.DB, uploaderID uint) models.File {
	t.Helper()
	const filename = "market-water-section-test.png"
	if err := os.WriteFile(filepath.Join(os.Getenv("UPLOAD_DIR"), filename), []byte("test image"), 0o600); err != nil {
		t.Fatalf("write market image: %v", err)
	}
	file := models.File{
		Hash:        "market-water-section-test",
		Path:        "/uploads/" + filename,
		Size:        int64(len("test image")),
		MimeType:    "image/png",
		UploaderID:  uploaderID,
		Status:      "active",
		AccessScope: models.FileAccessPublic,
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatalf("create market image: %v", err)
	}
	return file
}

// 9. 旧客户端不传 water_tag_id 也能成功发布水帖。
func TestCreateWaterPostWithoutWaterTag(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	user := newWaterTestUser(t, db, false)

	form := url.Values{}
	form.Set("content", "legacy content")
	form.Set("board_id", "1")
	form.Set("post_type", "course_study")

	handler := NewPostHandler(db, "", "")
	rec := performPostCreate(t, handler.Create, user.ID, form)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d body=%s", rec.Code, rec.Body.String())
	}
	var post models.Post
	if err := json.Unmarshal(rec.Body.Bytes(), &post); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if post.WaterTagID != nil {
		t.Fatalf("expected water_tag_id nil, got %v", post.WaterTagID)
	}
	if post.PostType != "course_study" {
		t.Fatalf("expected post_type=course_study, got %s", post.PostType)
	}
}

func TestUpdateLevelTitlesResetToDefault(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	admin := newWaterSectionRoleUser(t, db, "admin_level_titles", models.RoleAdmin)
	handler := NewWaterSectionHandler(db)

	create := performWaterSectionPATCH(
		t,
		handler.UpdateLevelTitles,
		"/api/water/sections/course_study/level-titles",
		admin.ID,
		`{"titles":[{"level":2,"title":"课程熟手"},{"level":3,"title":"资料达人"}]}`,
	)
	if create.Code != http.StatusOK {
		t.Fatalf("expected create 200, got %d body=%s", create.Code, create.Body.String())
	}

	reset := performWaterSectionPATCH(
		t,
		handler.UpdateLevelTitles,
		"/api/water/sections/course_study/level-titles",
		admin.ID,
		`{"titles":[{"level":2,"title":""},{"level":3,"reset":true}]}`,
	)
	if reset.Code != http.StatusOK {
		t.Fatalf("expected reset 200, got %d body=%s", reset.Code, reset.Body.String())
	}

	var section models.WaterSection
	if err := db.Where("slug = ?", "course_study").First(&section).Error; err != nil {
		t.Fatalf("find section: %v", err)
	}
	var customCount int64
	if err := db.Model(&models.WaterSectionLevelTitle{}).
		Where("section_id = ? AND level IN ?", section.ID, []int{2, 3}).
		Count(&customCount).Error; err != nil {
		t.Fatalf("count custom titles: %v", err)
	}
	if customCount != 0 {
		t.Fatalf("expected reset to delete custom titles, got %d", customCount)
	}

	get := performWaterSectionGET(t, handler.GetLevelTitles, "/api/water/sections/course_study/level-titles")
	if get.Code != http.StatusOK {
		t.Fatalf("expected get 200, got %d body=%s", get.Code, get.Body.String())
	}
	var body struct {
		Titles []struct {
			Level  int    `json:"level"`
			Title  string `json:"title"`
			Custom bool   `json:"custom"`
		} `json:"titles"`
	}
	if err := json.Unmarshal(get.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode titles: %v", err)
	}
	titlesByLevel := map[int]struct {
		Title  string
		Custom bool
	}{}
	for _, item := range body.Titles {
		titlesByLevel[item.Level] = struct {
			Title  string
			Custom bool
		}{Title: item.Title, Custom: item.Custom}
	}
	for _, level := range []int{2, 3} {
		item, ok := titlesByLevel[level]
		if !ok {
			t.Fatalf("missing level %d", level)
		}
		if item.Custom {
			t.Fatalf("level %d should fall back to default, got custom title %q", level, item.Title)
		}
		if item.Title == "" {
			t.Fatalf("level %d default title should not be empty", level)
		}
	}
}

func TestGetMyLevelReturnsProgressAndTodayAwards(t *testing.T) {
	db := newWaterSectionTestDB(t)
	if err := models.EnsureWaterSections(db); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	user := newWaterTestUser(t, db, false)
	var section models.WaterSection
	if err := db.Where("slug = ?", "campus_life").First(&section).Error; err != nil {
		t.Fatalf("find section: %v", err)
	}
	if err := db.Create(&models.WaterSectionUserStat{
		UserID:     user.ID,
		SectionID:  section.ID,
		Exp:        65,
		PostCount:  2,
		ReplyCount: 3,
	}).Error; err != nil {
		t.Fatalf("create stat: %v", err)
	}
	today := time.Now()
	today = time.Date(today.Year(), today.Month(), today.Day(), 0, 0, 0, 0, time.Local)
	if err := db.Create(&models.WaterSectionExpLog{
		UserID:    user.ID,
		SectionID: section.ID,
		Action:    models.WaterSectionExpActionPostDaily,
		Date:      today,
		ExpEarned: services.GlobalExpPostDaily,
		RefType:   "post",
		RefID:     1,
	}).Error; err != nil {
		t.Fatalf("create exp log: %v", err)
	}

	handler := NewWaterSectionHandler(db)
	rec := performWaterSectionAuthGET(t, handler.GetMyLevel, "/api/water/sections/campus_life/my-level", user.ID)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		Level             int    `json:"level"`
		Title             string `json:"title"`
		Exp               int    `json:"exp"`
		NextLevelExp      int    `json:"next_level_exp"`
		ProgressExp       int    `json:"progress_exp"`
		RequiredExp       int    `json:"required_exp"`
		TodayPostAwarded  bool   `json:"today_post_awarded"`
		TodayReplyAwarded bool   `json:"today_reply_awarded"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Level != 3 || body.Title != services.DefaultWaterSectionLevelTitle(3) {
		t.Fatalf("unexpected level title: level=%d title=%s", body.Level, body.Title)
	}
	if body.Exp != 65 || body.NextLevelExp != 120 || body.ProgressExp != 5 || body.RequiredExp != 60 {
		t.Fatalf("unexpected progress: %+v", body)
	}
	if !body.TodayPostAwarded || body.TodayReplyAwarded {
		t.Fatalf("unexpected daily award status: %+v", body)
	}
}

// 兼容：抑制未使用 import（若移除该 import，post_pin_test 已使用 bytes）
var _ = bytes.NewBuffer

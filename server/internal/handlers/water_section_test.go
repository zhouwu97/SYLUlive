package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// newWaterSectionTestDB 构造 in-memory DB，迁移 water 与 post 相关表。
func newWaterSectionTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(
		&models.User{},
		&models.File{},
		&models.Post{},
		&models.PostImage{},
		&models.Like{},
		&models.WaterSection{},
		&models.WaterSectionTag{},
		&models.WaterSectionModerator{},
		&models.WaterSectionPin{},
		&models.WaterSectionMute{},
		&models.WaterModerationLog{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	return db
}

func newWaterTestUser(t *testing.T, db *gorm.DB, eduBound bool) models.User {
	t.Helper()
	user := models.User{StudentID: "20260100", PasswordHash: "x", Nickname: "tester", EduBound: eduBound}
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
	mod := models.WaterSectionModerator{
		SectionID:      sectionID,
		UserID:         userID,
		Role:           models.ModeratorRoleModerator,
		CanEditSection: canEdit,
		CanManageTags:  false,
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
		ctx.Params = gin.Params{{Key: "slug", Value: slug}}
	}
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
	// 7 sections × 5 tags each = 35
	if tagCount != 35 {
		t.Fatalf("expected 35 tags, got %d", tagCount)
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
		"icon_key":"menu_book",
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

// 兼容：抑制未使用 import（若移除该 import，post_pin_test 已使用 bytes）
var _ = bytes.NewBuffer

package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestStandaloneTeamRecruitmentLifecycle(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "team.db")), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get database handle: %v", err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(
		&models.User{},
		&models.ExpLog{},
		&models.Notification{},
		&models.WaterSection{},
		&models.WaterSectionTag{},
		&models.WaterSectionMute{},
		&models.Post{},
		&models.PostImage{},
		&models.File{},
		&models.ImageVariant{},
		&models.WaterTeamRecruitment{},
		&models.WaterTeamApplication{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}

	owner := models.User{StudentID: "team-owner", PasswordHash: "x", Nickname: "队长", EduBound: true}
	applicant := models.User{StudentID: "team-applicant", PasswordHash: "x", Nickname: "申请人", EduBound: true}
	applicant2 := models.User{StudentID: "team-applicant-2", PasswordHash: "x", Nickname: "申请人二", EduBound: true}
	if err := db.Create(&owner).Error; err != nil {
		t.Fatalf("create owner: %v", err)
	}
	if err := db.Create(&applicant).Error; err != nil {
		t.Fatalf("create applicant: %v", err)
	}
	if err := db.Create(&applicant2).Error; err != nil {
		t.Fatalf("create second applicant: %v", err)
	}
	section := models.WaterSection{Slug: "competition", Title: "比赛竞赛", Status: "active"}
	if err := db.Create(&section).Error; err != nil {
		t.Fatalf("create section: %v", err)
	}
	tag := models.WaterSectionTag{
		SectionID:   section.ID,
		Slug:        "team",
		Name:        "组队",
		ContentMode: models.WaterTagModeTeamRecruitment,
		IsEnabled:   false,
	}
	if err := db.Create(&tag).Error; err != nil {
		t.Fatalf("create team tag: %v", err)
	}
	imageFile := models.File{
		Hash: "team-contract-image", Path: "/uploads/team.png", Size: 10, MimeType: "image/png", UploaderID: owner.ID,
	}
	if err := db.Create(&imageFile).Error; err != nil {
		t.Fatalf("create image file: %v", err)
	}

	handler := NewWaterTeamHandler(db)
	tooManyImages := make([]uint, 10)
	for i := range tooManyImages {
		tooManyImages[i] = imageFile.ID
	}
	invalidImageCreate := performTeamJSONRequest(t, handler.CreateTeamRecruitment, http.MethodPost, "/api/team/recruitments", owner.ID, nil, map[string]interface{}{
		"category":       "competition",
		"title":          "图片校验测试组队",
		"description":    "用于验证图片数量错误返回客户端错误",
		"needed_count":   1,
		"roles":          []string{"建模"},
		"image_file_ids": tooManyImages,
	})
	if invalidImageCreate.Code != http.StatusBadRequest {
		t.Fatalf("too many images status=%d body=%s", invalidImageCreate.Code, invalidImageCreate.Body.String())
	}
	duplicateImageCreate := performTeamJSONRequest(t, handler.CreateTeamRecruitment, http.MethodPost, "/api/team/recruitments", owner.ID, nil, map[string]interface{}{
		"category":       "competition",
		"title":          "重复图片测试组队",
		"description":    "用于验证重复图片引用会被服务端拒绝",
		"needed_count":   1,
		"roles":          []string{"建模"},
		"image_file_ids": []uint{imageFile.ID, imageFile.ID},
	})
	if duplicateImageCreate.Code != http.StatusBadRequest {
		t.Fatalf("duplicate images status=%d body=%s", duplicateImageCreate.Code, duplicateImageCreate.Body.String())
	}
	create := performTeamJSONRequest(t, handler.CreateTeamRecruitment, http.MethodPost, "/api/team/recruitments", owner.ID, nil, map[string]interface{}{
		"category":       "competition",
		"title":          "数学建模竞赛组队",
		"description":    "寻找两名队友完成数学建模竞赛项目",
		"needed_count":   1,
		"roles":          []string{"建模", "编程"},
		"image_file_ids": []uint{imageFile.ID},
	})
	if create.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", create.Code, create.Body.String())
	}
	var created struct {
		Recruitment TeamRecruitmentDetail `json:"recruitment"`
	}
	decodeTeamResponse(t, create, &created)
	if created.Recruitment.ID == 0 || created.Recruitment.PostID == 0 {
		t.Fatalf("created recruitment missing IDs: %#v", created.Recruitment)
	}

	list := performTeamJSONRequest(t, handler.ListTeamRecruitments, http.MethodGet, "/api/team/recruitments", 0, nil, nil)
	if list.Code != http.StatusOK {
		t.Fatalf("list status=%d body=%s", list.Code, list.Body.String())
	}
	var listed struct {
		Items []TeamRecruitmentListItem `json:"items"`
		Total int64                     `json:"total"`
	}
	decodeTeamResponse(t, list, &listed)
	if listed.Total != 1 || len(listed.Items) != 1 || listed.Items[0].ID != created.Recruitment.ID {
		t.Fatalf("unexpected list response: %#v", listed)
	}

	params := gin.Params{{Key: "id", Value: fmt.Sprint(created.Recruitment.ID)}}
	detail := performTeamJSONRequest(t, handler.GetTeamRecruitment, http.MethodGet, "/api/team/recruitments/1", applicant.ID, params, nil)
	if detail.Code != http.StatusOK {
		t.Fatalf("detail status=%d body=%s", detail.Code, detail.Body.String())
	}
	var detailBody TeamRecruitmentDetail
	decodeTeamResponse(t, detail, &detailBody)
	if !detailBody.CanApply || detailBody.IsOwner {
		t.Fatalf("applicant permissions are wrong: %#v", detailBody)
	}
	if len(detailBody.Images) != 1 || detailBody.Images[0].FileID != imageFile.ID {
		t.Fatalf("detail image file ID is missing: %#v", detailBody.Images)
	}

	apply := performTeamJSONRequest(t, handler.Apply, http.MethodPost, "/api/team/recruitments/1/apply", applicant.ID, params, map[string]interface{}{
		"message":      "我擅长建模和数据分析",
		"availability": "周末可参加",
	})
	if apply.Code != http.StatusCreated {
		t.Fatalf("apply status=%d body=%s", apply.Code, apply.Body.String())
	}
	var application models.WaterTeamApplication
	decodeTeamResponse(t, apply, &application)

	appParams := gin.Params{{Key: "id", Value: fmt.Sprint(application.ID)}}
	accept := performTeamJSONRequest(t, handler.Accept, http.MethodPost, "/api/team/applications/1/accept", owner.ID, appParams, map[string]interface{}{
		"reply": "欢迎加入",
	})
	if accept.Code != http.StatusOK {
		t.Fatalf("accept status=%d body=%s", accept.Code, accept.Body.String())
	}

	var saved models.WaterTeamRecruitment
	if err := db.First(&saved, created.Recruitment.ID).Error; err != nil {
		t.Fatalf("load recruitment: %v", err)
	}
	if saved.AcceptedCount != 1 || saved.Status != models.RecruitmentStatusFull {
		t.Fatalf("accepted_count=%d status=%s", saved.AcceptedCount, saved.Status)
	}

	futureDeadline := time.Now().Add(7 * 24 * time.Hour).UTC().Format(time.RFC3339)
	update := performTeamJSONRequest(t, handler.UpdateTeamRecruitment, http.MethodPatch, "/api/team/recruitments/1", owner.ID, params, map[string]interface{}{
		"needed_count": 2,
		"deadline":     futureDeadline,
	})
	if update.Code != http.StatusOK {
		t.Fatalf("update status=%d body=%s", update.Code, update.Body.String())
	}
	if err := db.First(&saved, created.Recruitment.ID).Error; err != nil {
		t.Fatalf("reload updated recruitment: %v", err)
	}
	if saved.Status != models.RecruitmentStatusRecruiting || saved.NeededCount != 2 || saved.Deadline == nil {
		t.Fatalf("updated recruitment state is wrong: %#v", saved)
	}

	secondApply := performTeamJSONRequest(t, handler.Apply, http.MethodPost, "/api/team/recruitments/1/apply", applicant2.ID, params, map[string]interface{}{
		"message":      "我擅长编程和结果展示",
		"availability": "工作日晚间",
	})
	if secondApply.Code != http.StatusCreated {
		t.Fatalf("second apply status=%d body=%s", secondApply.Code, secondApply.Body.String())
	}
	var secondApplication models.WaterTeamApplication
	decodeTeamResponse(t, secondApply, &secondApplication)

	var applicationNotifications int64
	if err := db.Model(&models.Notification{}).
		Where("user_id = ? AND type = ?", owner.ID, "team_application").
		Count(&applicationNotifications).Error; err != nil {
		t.Fatalf("count application notifications: %v", err)
	}
	if applicationNotifications != 2 {
		t.Fatalf("application notifications=%d, want 2", applicationNotifications)
	}
	pendingDetail := performTeamJSONRequest(t, handler.GetTeamRecruitment, http.MethodGet, "/api/team/recruitments/1", owner.ID, params, nil)
	var pendingDetailBody TeamRecruitmentDetail
	decodeTeamResponse(t, pendingDetail, &pendingDetailBody)
	if pendingDetailBody.ApplicationCount != 2 || pendingDetailBody.PendingApplicationCount != 1 {
		t.Fatalf("application counts: total=%d pending=%d", pendingDetailBody.ApplicationCount, pendingDetailBody.PendingApplicationCount)
	}

	secondAppParams := gin.Params{{Key: "id", Value: fmt.Sprint(secondApplication.ID)}}
	secondAccept := performTeamJSONRequest(t, handler.Accept, http.MethodPost, "/api/team/applications/2/accept", owner.ID, secondAppParams, map[string]interface{}{
		"reply": "欢迎加入",
	})
	if secondAccept.Code != http.StatusOK {
		t.Fatalf("second accept status=%d body=%s", secondAccept.Code, secondAccept.Body.String())
	}

	leave := performTeamJSONRequest(t, handler.Leave, http.MethodPost, "/api/team/applications/1/leave", applicant.ID, appParams, nil)
	if leave.Code != http.StatusOK {
		t.Fatalf("leave status=%d body=%s", leave.Code, leave.Body.String())
	}
	if err := db.First(&saved, created.Recruitment.ID).Error; err != nil {
		t.Fatalf("reload recruitment after leave: %v", err)
	}
	if saved.AcceptedCount != 1 || saved.Status != models.RecruitmentStatusRecruiting {
		t.Fatalf("state after leave: accepted_count=%d status=%s", saved.AcceptedCount, saved.Status)
	}

	remove := performTeamJSONRequest(t, handler.Remove, http.MethodPost, "/api/team/applications/2/remove", owner.ID, secondAppParams, nil)
	if remove.Code != http.StatusOK {
		t.Fatalf("remove status=%d body=%s", remove.Code, remove.Body.String())
	}
	if err := db.First(&saved, created.Recruitment.ID).Error; err != nil {
		t.Fatalf("reload recruitment after remove: %v", err)
	}
	if saved.AcceptedCount != 0 || saved.Status != models.RecruitmentStatusRecruiting {
		t.Fatalf("state after remove: accepted_count=%d status=%s", saved.AcceptedCount, saved.Status)
	}

	reapply := performTeamJSONRequest(t, handler.Apply, http.MethodPost, "/api/team/recruitments/1/apply", applicant.ID, params, map[string]interface{}{
		"message":      "时间已经协调好，希望重新加入",
		"availability": "周末全天",
	})
	if reapply.Code != http.StatusCreated {
		t.Fatalf("reapply status=%d body=%s", reapply.Code, reapply.Body.String())
	}
	reaccept := performTeamJSONRequest(t, handler.Accept, http.MethodPost, "/api/team/applications/1/accept", owner.ID, appParams, map[string]interface{}{
		"reply": "再次欢迎",
	})
	if reaccept.Code != http.StatusOK {
		t.Fatalf("reaccept status=%d body=%s", reaccept.Code, reaccept.Body.String())
	}
	var resultNotifications int64
	if err := db.Model(&models.Notification{}).
		Where("user_id = ? AND type = ?", applicant.ID, "team_application_result").
		Count(&resultNotifications).Error; err != nil {
		t.Fatalf("count result notifications: %v", err)
	}
	if resultNotifications != 2 {
		t.Fatalf("result notifications=%d, want 2", resultNotifications)
	}

	clearDeadline := performTeamJSONRequest(t, handler.UpdateTeamRecruitment, http.MethodPatch, "/api/team/recruitments/1", owner.ID, params, map[string]interface{}{
		"deadline": "",
	})
	if clearDeadline.Code != http.StatusOK {
		t.Fatalf("clear deadline status=%d body=%s", clearDeadline.Code, clearDeadline.Body.String())
	}
	var cleared models.WaterTeamRecruitment
	if err := db.First(&cleared, created.Recruitment.ID).Error; err != nil {
		t.Fatalf("reload recruitment after clearing deadline: %v", err)
	}
	if cleared.Deadline != nil {
		t.Fatalf("deadline was not cleared: %v", cleared.Deadline)
	}
}

func TestTeamApplicationLengthValidation(t *testing.T) {
	db, handler, owner, applicant, recruitment := setupTeamContractFixture(t)
	_ = db
	params := gin.Params{{Key: "id", Value: fmt.Sprint(recruitment.ID)}}
	response := performTeamJSONRequest(t, handler.Apply, http.MethodPost, "/api/team/recruitments/1/apply", applicant.ID, params, map[string]interface{}{
		"message":      "这是一条有效的申请留言",
		"availability": string(make([]rune, 201)),
	})
	if response.Code != http.StatusBadRequest {
		t.Fatalf("availability validation status=%d body=%s owner=%d", response.Code, response.Body.String(), owner.ID)
	}
}

func TestDeleteTeamRecruitmentAuthorizationAndVisibility(t *testing.T) {
	db, handler, owner, applicant, recruitment := setupTeamContractFixture(t)
	if err := db.Model(&recruitment).Update("status", models.RecruitmentStatusClosed).Error; err != nil {
		t.Fatalf("close recruitment: %v", err)
	}
	application := models.WaterTeamApplication{
		RecruitmentID: recruitment.ID,
		PostID:        recruitment.PostID,
		ApplicantID:   applicant.ID,
		OwnerID:       owner.ID,
		Message:       "这是一条用于验证删除的申请",
		Status:        models.ApplicationStatusPending,
	}
	if err := db.Create(&application).Error; err != nil {
		t.Fatalf("create application: %v", err)
	}
	params := gin.Params{{Key: "id", Value: fmt.Sprint(recruitment.ID)}}

	forbidden := performTeamJSONRequest(t, handler.DeleteTeamRecruitment, http.MethodDelete, "/api/team/recruitments/1", applicant.ID, params, nil)
	if forbidden.Code != http.StatusForbidden {
		t.Fatalf("non-owner delete status=%d body=%s", forbidden.Code, forbidden.Body.String())
	}

	deleted := performTeamJSONRequest(t, handler.DeleteTeamRecruitment, http.MethodDelete, "/api/team/recruitments/1", owner.ID, params, nil)
	if deleted.Code != http.StatusOK {
		t.Fatalf("owner delete status=%d body=%s", deleted.Code, deleted.Body.String())
	}

	var post models.Post
	if err := db.First(&post, recruitment.PostID).Error; err != nil {
		t.Fatalf("load deleted post: %v", err)
	}
	if post.Status != models.PostStatusDeleted {
		t.Fatalf("post status=%s, want deleted", post.Status)
	}
	if err := db.First(&recruitment, recruitment.ID).Error; err != nil {
		t.Fatalf("load retained recruitment: %v", err)
	}
	if recruitment.Status != models.RecruitmentStatusClosed {
		t.Fatalf("recruitment status=%s, want closed", recruitment.Status)
	}
	var retainedApplications int64
	if err := db.Model(&models.WaterTeamApplication{}).Where("recruitment_id = ?", recruitment.ID).Count(&retainedApplications).Error; err != nil {
		t.Fatalf("count retained applications: %v", err)
	}
	if retainedApplications != 1 {
		t.Fatalf("retained applications=%d, want 1", retainedApplications)
	}

	detail := performTeamJSONRequest(t, handler.GetTeamRecruitment, http.MethodGet, "/api/team/recruitments/1", owner.ID, params, nil)
	if detail.Code != http.StatusNotFound {
		t.Fatalf("deleted detail status=%d body=%s", detail.Code, detail.Body.String())
	}
	list := performTeamJSONRequest(t, handler.ListTeamRecruitments, http.MethodGet, "/api/team/recruitments", 0, nil, nil)
	var listBody struct {
		Total int64 `json:"total"`
	}
	decodeTeamResponse(t, list, &listBody)
	if listBody.Total != 0 {
		t.Fatalf("deleted recruitment remains in public list: total=%d", listBody.Total)
	}
	mine := performTeamJSONRequest(t, handler.GetMyTeamRecruitments, http.MethodGet, "/api/team/recruitments/mine", owner.ID, nil, nil)
	var mineBody struct {
		Total int64 `json:"total"`
	}
	decodeTeamResponse(t, mine, &mineBody)
	if mineBody.Total != 0 {
		t.Fatalf("deleted recruitment remains in owner list: total=%d", mineBody.Total)
	}
	myApplications := performTeamJSONRequest(t, handler.GetMyApplications, http.MethodGet, "/api/team/my_applications", applicant.ID, nil, nil)
	var applicationBody []models.WaterTeamApplication
	decodeTeamResponse(t, myApplications, &applicationBody)
	if len(applicationBody) != 0 {
		t.Fatalf("deleted recruitment remains in applicant list: count=%d", len(applicationBody))
	}
}

func TestTeamRecruitmentEffectiveStatusFilters(t *testing.T) {
	db, handler, owner, _, base := setupTeamContractFixture(t)
	createRecruitment := func(title, status string, accepted, needed int, deadline *time.Time) models.WaterTeamRecruitment {
		post := models.Post{Title: title, Content: "这是一段足够长的组队说明", BoardID: models.BoardShuitie, AuthorID: owner.ID, Status: models.PostStatusNormal}
		if err := db.Create(&post).Error; err != nil {
			t.Fatalf("create post: %v", err)
		}
		recruitment := models.WaterTeamRecruitment{PostID: post.ID, SectionID: base.SectionID, TagID: base.TagID, Category: models.TeamCategoryCompetition, NeededCount: needed, AcceptedCount: accepted, RolesJSON: "[]", Deadline: deadline, Status: status}
		if err := db.Create(&recruitment).Error; err != nil {
			t.Fatalf("create recruitment: %v", err)
		}
		return recruitment
	}
	past := time.Now().Add(-time.Hour)
	expired := createRecruitment("已截止招募", models.RecruitmentStatusRecruiting, 0, 2, &past)
	closedFull := createRecruitment("已关闭满员招募", models.RecruitmentStatusClosed, 2, 2, nil)
	activeFull := createRecruitment("有效满员招募", models.RecruitmentStatusFull, 2, 2, nil)

	assertFilterIDs := func(status string, want []uint) {
		t.Helper()
		response := performTeamJSONRequest(t, handler.ListTeamRecruitments, http.MethodGet, "/api/team/recruitments?status="+status, 0, nil, nil)
		if response.Code != http.StatusOK {
			t.Fatalf("filter %s status=%d body=%s", status, response.Code, response.Body.String())
		}
		var body struct {
			Items []TeamRecruitmentListItem `json:"items"`
		}
		decodeTeamResponse(t, response, &body)
		got := make([]uint, 0, len(body.Items))
		for _, item := range body.Items {
			got = append(got, item.ID)
		}
		if fmt.Sprint(got) != fmt.Sprint(want) {
			t.Fatalf("filter %s IDs=%v, want %v (closed full=%d)", status, got, want, closedFull.ID)
		}
	}
	assertFilterIDs(models.RecruitmentStatusExpired, []uint{expired.ID})
	assertFilterIDs(models.RecruitmentStatusFull, []uint{activeFull.ID})
}

func setupTeamContractFixture(t *testing.T) (*gorm.DB, *WaterTeamHandler, models.User, models.User, models.WaterTeamRecruitment) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "fixture.db")), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get database handle: %v", err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(&models.User{}, &models.Notification{}, &models.WaterSection{}, &models.WaterSectionTag{}, &models.WaterSectionMute{}, &models.Post{}, &models.PostImage{}, &models.WaterTeamRecruitment{}, &models.WaterTeamApplication{}); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	owner := models.User{StudentID: "fixture-owner", PasswordHash: "x", Nickname: "队长", EduBound: true}
	applicant := models.User{StudentID: "fixture-applicant", PasswordHash: "x", Nickname: "申请人", EduBound: true}
	db.Create(&owner)
	db.Create(&applicant)
	section := models.WaterSection{Slug: "competition", Title: "比赛竞赛", Status: "active"}
	db.Create(&section)
	tag := models.WaterSectionTag{SectionID: section.ID, Slug: "team", Name: "组队", ContentMode: models.WaterTagModeTeamRecruitment}
	db.Create(&tag)
	post := models.Post{Title: "测试组队", Content: "这是一段足够长的组队说明", BoardID: models.BoardShuitie, AuthorID: owner.ID, WaterTagID: &tag.ID, Status: models.PostStatusNormal}
	db.Create(&post)
	recruitment := models.WaterTeamRecruitment{PostID: post.ID, SectionID: section.ID, TagID: tag.ID, Category: models.TeamCategoryCompetition, NeededCount: 2, RolesJSON: "[]", Status: models.RecruitmentStatusRecruiting}
	db.Create(&recruitment)
	return db, NewWaterTeamHandler(db), owner, applicant, recruitment
}

func performTeamJSONRequest(
	t *testing.T,
	handler gin.HandlerFunc,
	method string,
	path string,
	userID uint,
	params gin.Params,
	payload map[string]interface{},
) *httptest.ResponseRecorder {
	t.Helper()
	body := bytes.NewReader(nil)
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			t.Fatalf("encode request: %v", err)
		}
		body = bytes.NewReader(encoded)
	}
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(method, path, body)
	context.Request.Header.Set("Content-Type", "application/json")
	context.Params = params
	if userID != 0 {
		context.Set("user_id", userID)
	}
	handler(context)
	return recorder
}

func decodeTeamResponse(t *testing.T, recorder *httptest.ResponseRecorder, target interface{}) {
	t.Helper()
	if err := json.Unmarshal(recorder.Body.Bytes(), target); err != nil {
		t.Fatalf("decode response: %v body=%s", err, recorder.Body.String())
	}
}

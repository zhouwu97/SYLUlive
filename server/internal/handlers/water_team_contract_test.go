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
		&models.WaterTeamRecruitment{},
		&models.WaterTeamApplication{},
	); err != nil {
		t.Fatalf("migrate database: %v", err)
	}

	owner := models.User{StudentID: "team-owner", PasswordHash: "x", Nickname: "队长", EduBound: true}
	applicant := models.User{StudentID: "team-applicant", PasswordHash: "x", Nickname: "申请人", EduBound: true}
	if err := db.Create(&owner).Error; err != nil {
		t.Fatalf("create owner: %v", err)
	}
	if err := db.Create(&applicant).Error; err != nil {
		t.Fatalf("create applicant: %v", err)
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
		Hash: "team-contract-image", Path: "/uploads/team.png", Size: 10, MimeType: "image/png",
	}
	if err := db.Create(&imageFile).Error; err != nil {
		t.Fatalf("create image file: %v", err)
	}

	handler := NewWaterTeamHandler(db)
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

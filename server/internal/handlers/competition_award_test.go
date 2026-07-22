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

	"shenliyuan/internal/models"
)

func competitionAwardRequest(t *testing.T, handler gin.HandlerFunc, method, path, body string, userID uint, id uint) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(method, path, strings.NewReader(body))
	context.Request.Header.Set("Content-Type", "application/json")
	if userID != 0 {
		context.Set("user_id", userID)
	}
	if id != 0 {
		context.Params = gin.Params{{Key: "id", Value: fmt.Sprint(id)}}
	}
	handler(context)
	return recorder
}

func validCompetitionAwardBody(year int) string {
	return fmt.Sprintf(`{
		"competition_title":"程序设计竞赛","track_name":"软件应用",
		"competition_year":%d,"award_name":"省级二等奖","award_level":"省级",
		"competition_stage":"provincial","role":"developer",
		"skill_tags":["Python","算法"],"contribution_summary":"负责核心模块",
		"evidence_file_ids":[],"visibility":"private"
	}`, year)
}

func decodeCompetitionAward(t *testing.T, recorder *httptest.ResponseRecorder) competitionAwardResponse {
	t.Helper()
	var response competitionAwardResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func TestCompetitionAwardCreateListUpdateDelete(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	year := time.Now().Year()
	created := competitionAwardRequest(t, handler.CreateCompetitionAward, http.MethodPost, "/api/user/competition-awards", validCompetitionAwardBody(year), 11, 0)
	if created.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", created.Code, created.Body.String())
	}
	award := decodeCompetitionAward(t, created)
	if award.VerificationStatus != "self_reported" || award.Visibility != "private" {
		t.Fatalf("created award=%+v", award)
	}

	listed := competitionAwardRequest(t, handler.ListCompetitionAwards, http.MethodGet, "/api/user/competition-awards", "", 11, 0)
	var list struct {
		Items []competitionAwardResponse `json:"items"`
		Total int                        `json:"total"`
	}
	if err := json.Unmarshal(listed.Body.Bytes(), &list); err != nil {
		t.Fatal(err)
	}
	if listed.Code != http.StatusOK || list.Total != 1 || list.Items[0].ID != award.ID {
		t.Fatalf("list status=%d response=%+v", listed.Code, list)
	}

	updatedBody := strings.Replace(validCompetitionAwardBody(year), "省级二等奖", "省级一等奖", 1)
	updated := competitionAwardRequest(t, handler.UpdateCompetitionAward, http.MethodPut, "/api/user/competition-awards/1", updatedBody, 11, award.ID)
	if updated.Code != http.StatusOK || decodeCompetitionAward(t, updated).AwardName != "省级一等奖" {
		t.Fatalf("update status=%d body=%s", updated.Code, updated.Body.String())
	}

	deleted := competitionAwardRequest(t, handler.DeleteCompetitionAward, http.MethodDelete, "/api/user/competition-awards/1", "", 11, award.ID)
	if deleted.Code != http.StatusOK {
		t.Fatalf("delete status=%d body=%s", deleted.Code, deleted.Body.String())
	}
	listed = competitionAwardRequest(t, handler.ListCompetitionAwards, http.MethodGet, "/api/user/competition-awards", "", 11, 0)
	if err := json.Unmarshal(listed.Body.Bytes(), &list); err != nil {
		t.Fatal(err)
	}
	if list.Total != 0 {
		t.Fatalf("soft-deleted award remains visible: %+v", list)
	}
	var deletedCount int64
	if err := db.Unscoped().Model(&models.UserCompetitionAward{}).Where("id = ? AND deleted_at IS NOT NULL", award.ID).Count(&deletedCount).Error; err != nil || deletedCount != 1 {
		t.Fatalf("soft delete count=%d err=%v", deletedCount, err)
	}
}

func TestCompetitionAwardIsIsolatedByUser(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	created := competitionAwardRequest(t, handler.CreateCompetitionAward, http.MethodPost, "/api/user/competition-awards", validCompetitionAwardBody(time.Now().Year()), 21, 0)
	award := decodeCompetitionAward(t, created)
	for _, call := range []struct {
		handler gin.HandlerFunc
		method  string
		body    string
	}{
		{handler.UpdateCompetitionAward, http.MethodPut, validCompetitionAwardBody(time.Now().Year())},
		{handler.DeleteCompetitionAward, http.MethodDelete, ""},
	} {
		response := competitionAwardRequest(t, call.handler, call.method, "/api/user/competition-awards/1", call.body, 22, award.ID)
		if response.Code != http.StatusNotFound {
			t.Fatalf("method=%s status=%d body=%s", call.method, response.Code, response.Body.String())
		}
	}
	listed := competitionAwardRequest(t, handler.ListCompetitionAwards, http.MethodGet, "/api/user/competition-awards", "", 22, 0)
	if !strings.Contains(listed.Body.String(), `"total":0`) {
		t.Fatalf("another user can list award: %s", listed.Body.String())
	}
}

func TestCompetitionAwardRejectsVerificationFieldsAndInvalidLimits(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db).CreateCompetitionAward
	year := time.Now().Year()
	tests := map[string]string{
		"verification status": strings.Replace(validCompetitionAwardBody(year), `"visibility":"private"`, `"visibility":"private","verification_status":"verified"`, 1),
		"verified by":         strings.Replace(validCompetitionAwardBody(year), `"visibility":"private"`, `"visibility":"private","verified_by":1`, 1),
		"future year":         strings.Replace(validCompetitionAwardBody(year), fmt.Sprintf(`"competition_year":%d`, year), fmt.Sprintf(`"competition_year":%d`, year+2), 1),
		"unknown role":        strings.Replace(validCompetitionAwardBody(year), `"role":"developer"`, `"role":"captain"`, 1),
		"unknown stage":       strings.Replace(validCompetitionAwardBody(year), `"competition_stage":"provincial"`, `"competition_stage":"final"`, 1),
		"unknown visibility":  strings.Replace(validCompetitionAwardBody(year), `"visibility":"private"`, `"visibility":"public"`, 1),
		"too many skills":     strings.Replace(validCompetitionAwardBody(year), `"skill_tags":["Python","算法"]`, `"skill_tags":["1","2","3","4","5","6","7","8","9","10","11","12","13"]`, 1),
	}
	for name, body := range tests {
		t.Run(name, func(t *testing.T) {
			response := competitionAwardRequest(t, handler, http.MethodPost, "/api/user/competition-awards", body, 31, 0)
			if response.Code != http.StatusBadRequest {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
}

func TestCompetitionAwardUsesEventTitleSnapshot(t *testing.T) {
	db := newCompetitionTestDB(t)
	event := models.CompetitionEvent{Title: "目录权威赛事", Status: "published"}
	if err := db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	body := strings.Replace(validCompetitionAwardBody(time.Now().Year()), `"competition_title":"程序设计竞赛"`, fmt.Sprintf(`"competition_event_id":%d,"competition_title":"伪造标题"`, event.ID), 1)
	handler := NewCompetitionHandler(db)
	created := competitionAwardRequest(t, handler.CreateCompetitionAward, http.MethodPost, "/api/user/competition-awards", body, 41, 0)
	award := decodeCompetitionAward(t, created)
	if created.Code != http.StatusCreated || award.CompetitionTitle != "目录权威赛事" {
		t.Fatalf("status=%d award=%+v", created.Code, award)
	}
	if err := db.Delete(&event).Error; err != nil {
		t.Fatal(err)
	}
	listed := competitionAwardRequest(t, handler.ListCompetitionAwards, http.MethodGet, "/api/user/competition-awards", "", 41, 0)
	if !strings.Contains(listed.Body.String(), "目录权威赛事") {
		t.Fatalf("event deletion removed snapshot: %s", listed.Body.String())
	}
}

func TestCompetitionAwardValidatesEvidenceOwnershipAndCounts(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db).CreateCompetitionAward
	owned := models.File{Hash: strings.Repeat("a", 64), Path: "/uploads/a.jpg", Size: 10, MimeType: "image/jpeg", UploaderID: 51}
	foreign := models.File{Hash: strings.Repeat("b", 64), Path: "/uploads/b.jpg", Size: 10, MimeType: "image/jpeg", UploaderID: 52}
	if err := db.Create(&owned).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&foreign).Error; err != nil {
		t.Fatal(err)
	}
	base := validCompetitionAwardBody(time.Now().Year())
	ownedBody := strings.Replace(base, `"evidence_file_ids":[]`, fmt.Sprintf(`"evidence_file_ids":[%d]`, owned.ID), 1)
	if response := competitionAwardRequest(t, handler, http.MethodPost, "/api/user/competition-awards", ownedBody, 51, 0); response.Code != http.StatusCreated {
		t.Fatalf("owned file status=%d body=%s", response.Code, response.Body.String())
	}
	if err := db.First(&owned, owned.ID).Error; err != nil || owned.Status != "active" || owned.ClaimedAt == nil {
		t.Fatalf("evidence file was not activated: file=%+v err=%v", owned, err)
	}
	foreignBody := strings.Replace(base, `"evidence_file_ids":[]`, fmt.Sprintf(`"evidence_file_ids":[%d]`, foreign.ID), 1)
	if response := competitionAwardRequest(t, handler, http.MethodPost, "/api/user/competition-awards", foreignBody, 51, 0); response.Code != http.StatusBadRequest {
		t.Fatalf("foreign file status=%d body=%s", response.Code, response.Body.String())
	}
	tooMany := strings.Replace(base, `"evidence_file_ids":[]`, `"evidence_file_ids":[1,2,3,4,5,6,7]`, 1)
	if response := competitionAwardRequest(t, handler, http.MethodPost, "/api/user/competition-awards", tooMany, 51, 0); response.Code != http.StatusBadRequest {
		t.Fatalf("too many files status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestCompetitionAwardRequiresAuthentication(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	for _, test := range []struct {
		handler gin.HandlerFunc
		method  string
		body    string
	}{
		{handler.ListCompetitionAwards, http.MethodGet, ""},
		{handler.CreateCompetitionAward, http.MethodPost, validCompetitionAwardBody(time.Now().Year())},
		{handler.UpdateCompetitionAward, http.MethodPut, validCompetitionAwardBody(time.Now().Year())},
		{handler.DeleteCompetitionAward, http.MethodDelete, ""},
	} {
		response := competitionAwardRequest(t, test.handler, test.method, "/api/user/competition-awards/1", test.body, 0, 1)
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("method=%s status=%d body=%s", test.method, response.Code, response.Body.String())
		}
	}
}

func TestCompetitionAwardUpdateResetsVerification(t *testing.T) {
	db := newCompetitionTestDB(t)
	award := models.UserCompetitionAward{
		UserID: 61, CompetitionTitle: "已核验赛事", CompetitionYear: time.Now().Year(),
		AwardName: "一等奖", CompetitionStage: "national", Role: "developer",
		SkillTags: jsonArray([]string{}), EvidenceFileIDs: uintJSONArray([]uint{}),
		VerificationStatus: "verified", VerificationNote: "材料一致", Visibility: "private",
	}
	verifier := uint(99)
	verifiedAt := time.Now()
	award.VerifiedBy, award.VerifiedAt = &verifier, &verifiedAt
	if err := db.Create(&award).Error; err != nil {
		t.Fatal(err)
	}
	handler := NewCompetitionHandler(db)
	response := competitionAwardRequest(t, handler.UpdateCompetitionAward, http.MethodPut, "/api/user/competition-awards/1", validCompetitionAwardBody(time.Now().Year()), 61, award.ID)
	updated := decodeCompetitionAward(t, response)
	if response.Code != http.StatusOK || updated.VerificationStatus != "self_reported" || updated.VerifiedBy != nil || updated.VerifiedAt != nil || updated.VerificationNote != "" {
		t.Fatalf("updated verification=%+v", updated)
	}
}

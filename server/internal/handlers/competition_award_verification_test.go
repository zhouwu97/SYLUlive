package handlers

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/models"
)

func competitionAwardVerificationRequest(t *testing.T, handler gin.HandlerFunc, method, path, body string, userID, awardID uint, role string) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(method, path, strings.NewReader(body))
	context.Request.Header.Set("Content-Type", "application/json")
	if userID != 0 {
		context.Set("user_id", userID)
	}
	if role != "" {
		context.Set("role", role)
	}
	if awardID != 0 {
		context.Params = gin.Params{{Key: "id", Value: fmt.Sprint(awardID)}}
	}
	handler(context)
	return recorder
}

func createAwardWithEvidence(t *testing.T, userID uint) (*CompetitionHandler, models.UserCompetitionAward, models.File) {
	t.Helper()
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	file := models.File{Hash: strings.Repeat("c", 64), Path: "/uploads/cc/evidence.png", Size: 8, MimeType: "image/png", UploaderID: userID}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	body := strings.Replace(validCompetitionAwardBody(time.Now().Year()), `"evidence_file_ids":[]`, fmt.Sprintf(`"evidence_file_ids":[%d]`, file.ID), 1)
	created := competitionAwardRequest(t, handler.CreateCompetitionAward, http.MethodPost, "/api/user/competition-awards", body, userID, 0)
	if created.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", created.Code, created.Body.String())
	}
	award := models.UserCompetitionAward{}
	if err := db.First(&award).Error; err != nil {
		t.Fatal(err)
	}
	return handler, award, file
}

func TestCompetitionAwardVerificationUserWorkflowAndAudit(t *testing.T) {
	handler, award, _ := createAwardWithEvidence(t, 71)
	other := competitionAwardVerificationRequest(t, handler.SubmitCompetitionAwardVerification, http.MethodPost, "/", "", 72, award.ID, "user")
	if other.Code != http.StatusNotFound {
		t.Fatalf("other submit status=%d body=%s", other.Code, other.Body.String())
	}
	submitted := competitionAwardVerificationRequest(t, handler.SubmitCompetitionAwardVerification, http.MethodPost, "/", "", 71, award.ID, "user")
	if submitted.Code != http.StatusOK || !strings.Contains(submitted.Body.String(), `"verification_status":"pending"`) {
		t.Fatalf("submit status=%d body=%s", submitted.Code, submitted.Body.String())
	}
	repeated := competitionAwardVerificationRequest(t, handler.SubmitCompetitionAwardVerification, http.MethodPost, "/", "", 71, award.ID, "user")
	if repeated.Code != http.StatusConflict {
		t.Fatalf("repeat submit status=%d", repeated.Code)
	}
	cancelled := competitionAwardVerificationRequest(t, handler.CancelCompetitionAwardVerification, http.MethodPost, "/", "", 71, award.ID, "user")
	if cancelled.Code != http.StatusOK || !strings.Contains(cancelled.Body.String(), `"verification_status":"self_reported"`) {
		t.Fatalf("cancel status=%d body=%s", cancelled.Code, cancelled.Body.String())
	}
	var count int64
	if err := handler.db.Model(&models.CompetitionAwardVerificationLog{}).Where("award_id = ?", award.ID).Count(&count).Error; err != nil || count != 2 {
		t.Fatalf("audit count=%d err=%v", count, err)
	}
}

func TestCompetitionAwardVerificationRequiresEvidence(t *testing.T) {
	db := newCompetitionTestDB(t)
	award := models.UserCompetitionAward{
		UserID: 73, CompetitionTitle: "无材料赛事", CompetitionYear: time.Now().Year(), AwardName: "参赛",
		CompetitionStage: "school", Role: "member", SkillTags: jsonArray(nil), EvidenceFileIDs: uintJSONArray(nil),
		VerificationStatus: "self_reported", Visibility: "private",
	}
	if err := db.Create(&award).Error; err != nil {
		t.Fatal(err)
	}
	response := competitionAwardVerificationRequest(t, NewCompetitionHandler(db).SubmitCompetitionAwardVerification, http.MethodPost, "/", "", 73, award.ID, "user")
	if response.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestCompetitionAwardVerificationReviewPermissionsAndState(t *testing.T) {
	handler, award, _ := createAwardWithEvidence(t, 74)
	if response := competitionAwardVerificationRequest(t, handler.SubmitCompetitionAwardVerification, http.MethodPost, "/", "", 74, award.ID, "user"); response.Code != http.StatusOK {
		t.Fatal(response.Body.String())
	}
	for _, role := range []string{"user", "admin"} {
		response := competitionAwardVerificationRequest(t, handler.ApproveCompetitionAwardVerification, http.MethodPost, "/", `{"note":"一致"}`, 90, award.ID, role)
		if response.Code != http.StatusForbidden {
			t.Fatalf("role=%s status=%d", role, response.Code)
		}
	}
	missingReason := competitionAwardVerificationRequest(t, handler.RejectCompetitionAwardVerification, http.MethodPost, "/", `{"reason":""}`, 91, award.ID, "super_admin")
	if missingReason.Code != http.StatusBadRequest {
		t.Fatalf("missing reason status=%d", missingReason.Code)
	}
	approved := competitionAwardVerificationRequest(t, handler.ApproveCompetitionAwardVerification, http.MethodPost, "/", `{"note":"材料与填写信息一致"}`, 91, award.ID, "super_admin")
	if approved.Code != http.StatusOK {
		t.Fatalf("approve status=%d body=%s", approved.Code, approved.Body.String())
	}
	var stored models.UserCompetitionAward
	if err := handler.db.First(&stored, award.ID).Error; err != nil || stored.VerificationStatus != "verified" || stored.VerifiedBy == nil || *stored.VerifiedBy != 91 || stored.VerifiedAt == nil {
		t.Fatalf("stored=%+v err=%v", stored, err)
	}
	repeated := competitionAwardVerificationRequest(t, handler.RejectCompetitionAwardVerification, http.MethodPost, "/", `{"reason":"重复处理"}`, 91, award.ID, "super_admin")
	if repeated.Code != http.StatusConflict {
		t.Fatalf("repeat review status=%d body=%s", repeated.Code, repeated.Body.String())
	}
}

func TestCompetitionAwardRejectedCanEditAndResubmit(t *testing.T) {
	handler, award, _ := createAwardWithEvidence(t, 75)
	competitionAwardVerificationRequest(t, handler.SubmitCompetitionAwardVerification, http.MethodPost, "/", "", 75, award.ID, "user")
	rejected := competitionAwardVerificationRequest(t, handler.RejectCompetitionAwardVerification, http.MethodPost, "/", `{"reason":"奖项等级无法确认"}`, 92, award.ID, "super_admin")
	if rejected.Code != http.StatusOK || !strings.Contains(rejected.Body.String(), "奖项等级无法确认") {
		t.Fatalf("reject status=%d body=%s", rejected.Code, rejected.Body.String())
	}
	changed := strings.Replace(validCompetitionAwardBody(time.Now().Year()), `"award_name":"省级二等奖"`, `"award_name":"省级三等奖"`, 1)
	changed = strings.Replace(changed, `"evidence_file_ids":[]`, fmt.Sprintf(`"evidence_file_ids":[%d]`, uint(1)), 1)
	updated := competitionAwardRequest(t, handler.UpdateCompetitionAward, http.MethodPut, "/", changed, 75, award.ID)
	if updated.Code != http.StatusOK || !strings.Contains(updated.Body.String(), `"verification_status":"rejected"`) {
		t.Fatalf("update status=%d body=%s", updated.Code, updated.Body.String())
	}
	resubmitted := competitionAwardVerificationRequest(t, handler.SubmitCompetitionAwardVerification, http.MethodPost, "/", "", 75, award.ID, "user")
	if resubmitted.Code != http.StatusOK || !strings.Contains(resubmitted.Body.String(), `"verification_status":"pending"`) {
		t.Fatalf("resubmit status=%d body=%s", resubmitted.Code, resubmitted.Body.String())
	}
}

func TestCompetitionAwardEvidenceIsPrivateAndAdminAccessIsAudited(t *testing.T) {
	handler, award, file := createAwardWithEvidence(t, 76)
	uploadDir := t.TempDir()
	filePath := filepath.Join(uploadDir, "cc", "evidence.png")
	if err := os.MkdirAll(filepath.Dir(filePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filePath, []byte("evidence"), 0o600); err != nil {
		t.Fatal(err)
	}
	uploadHandler := NewUploadHandler(uploadDir, 1024, handler.db)
	var mappingCount int64
	if err := handler.db.Model(&models.CompetitionAwardEvidence{}).Where("award_id = ? AND file_id = ?", award.ID, file.ID).Count(&mappingCount).Error; err != nil || mappingCount != 1 {
		t.Fatalf("evidence mapping count=%d err=%v", mappingCount, err)
	}
	public := httptest.NewRecorder()
	publicContext, _ := gin.CreateTestContext(public)
	publicContext.Params = gin.Params{{Key: "filepath", Value: "/cc/evidence.png"}}
	uploadHandler.ServePublic(publicContext)
	if public.Code != http.StatusNotFound {
		t.Fatalf("public status=%d", public.Code)
	}
	owner := evidenceRequest(t, handler.DownloadOwnCompetitionAwardEvidence, award.ID, file.ID, 76, "user")
	if owner.Code != http.StatusOK || owner.Body.String() != "evidence" {
		t.Fatalf("owner status=%d body=%q", owner.Code, owner.Body.String())
	}
	foreign := evidenceRequest(t, handler.DownloadOwnCompetitionAwardEvidence, award.ID, file.ID, 77, "user")
	if foreign.Code != http.StatusNotFound {
		t.Fatalf("foreign status=%d", foreign.Code)
	}
	normalAdmin := evidenceRequest(t, handler.DownloadAdminCompetitionAwardEvidence, award.ID, file.ID, 93, "admin")
	if normalAdmin.Code != http.StatusForbidden {
		t.Fatalf("admin status=%d", normalAdmin.Code)
	}
	superAdmin := evidenceRequest(t, handler.DownloadAdminCompetitionAwardEvidence, award.ID, file.ID, 94, "super_admin")
	if superAdmin.Code != http.StatusOK {
		t.Fatalf("super admin status=%d body=%s", superAdmin.Code, superAdmin.Body.String())
	}
	var accessCount int64
	if err := handler.db.Model(&models.CompetitionAwardEvidenceAccessLog{}).Where("award_id = ? AND viewer_id = ?", award.ID, 94).Count(&accessCount).Error; err != nil || accessCount != 1 {
		t.Fatalf("access count=%d err=%v", accessCount, err)
	}
	if err := handler.db.Delete(&award).Error; err != nil {
		t.Fatal(err)
	}
	deleted := evidenceRequest(t, handler.DownloadOwnCompetitionAwardEvidence, award.ID, file.ID, 76, "user")
	if deleted.Code != http.StatusNotFound {
		t.Fatalf("deleted evidence status=%d", deleted.Code)
	}
}

func evidenceRequest(t *testing.T, handler gin.HandlerFunc, awardID, fileID, userID uint, role string) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/", nil)
	context.Set("user_id", userID)
	context.Set("role", role)
	context.Params = gin.Params{{Key: "id", Value: fmt.Sprint(awardID)}, {Key: "file_id", Value: fmt.Sprint(fileID)}}
	handler(context)
	return recorder
}

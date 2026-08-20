package handlers

import (
	"net/http"
	"strings"
	"testing"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func TestHandleReportRequiresGovernanceReason(t *testing.T) {
	db := newCanteenTestDB(t)
	if err := db.AutoMigrate(&models.Report{}); err != nil {
		t.Fatal(err)
	}
	admin := createCanteenTestUser(t, db, 1, "管理员")
	reporter := createCanteenTestUser(t, db, 2, "举报人")
	report := models.Report{
		ReporterID: reporter.ID,
		TargetType: "canteen_rating",
		TargetID:   99,
		ReasonCode: "abuse",
		Reason:     "举报测试",
		Status:     models.ReportStatusPending,
	}
	if err := db.Create(&report).Error; err != nil {
		t.Fatal(err)
	}

	response := performCanteenRequest(t, NewReportHandler(db).Handle, http.MethodPut,
		"/api/admin/reports/"+itoaForTest(report.ID)+"/handle",
		mapParams("id", itoaForTest(report.ID)), admin.ID,
		`{"status":"handled","result":"确认违规"}`)
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "governance_reason_required") {
		t.Fatalf("missing reason status=%d body=%s", response.Code, response.Body.String())
	}
	var stored models.Report
	if err := db.First(&stored, report.ID).Error; err != nil {
		t.Fatal(err)
	}
	if stored.Status != models.ReportStatusPending {
		t.Fatalf("report status=%s want pending", stored.Status)
	}
}

func TestHandleReportRequiresAdminConfirmedReasonCode(t *testing.T) {
	db := newCanteenTestDB(t)
	if err := db.AutoMigrate(&models.Report{}); err != nil {
		t.Fatal(err)
	}
	admin := createCanteenTestUser(t, db, 1, "管理员")
	reporter := createCanteenTestUser(t, db, 2, "举报人")
	report := models.Report{
		ReporterID: reporter.ID, TargetType: "canteen_review", TargetID: 99,
		ReasonCode: "fabricated", Reason: "举报测试", Status: models.ReportStatusPending,
	}
	if err := db.Create(&report).Error; err != nil {
		t.Fatal(err)
	}

	response := performCanteenRequest(t, NewReportHandler(db).Handle, http.MethodPut,
		"/api/admin/reports/"+itoaForTest(report.ID)+"/handle",
		mapParams("id", itoaForTest(report.ID)), admin.ID,
		`{"status":"handled","result":"确认违规","delete_reason":"内容失实"}`)
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "confirmed_reason_code_required") {
		t.Fatalf("missing confirmed code status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestCanteenGovernanceUsesAdminConfirmedReasonInsteadOfReporterReason(t *testing.T) {
	db := newCanteenTestDB(t)
	if err := db.AutoMigrate(&models.Report{}, &models.CanteenReviewEvent{}, &models.CanteenDishReviewEvent{}, &models.CanteenSanction{}, &models.AdminActionLog{}, &models.AdminLog{}); err != nil {
		t.Fatal(err)
	}
	admin := createCanteenTestUser(t, db, 1, "管理员")
	reporter := createCanteenTestUser(t, db, 2, "举报人")
	owner := createCanteenTestUser(t, db, 3, "发布者")
	canteen := models.Canteen{ID: 10, Name: "一食堂", Verified: true, CreatedBy: admin.ID}
	if err := db.Create(&canteen).Error; err != nil {
		t.Fatal(err)
	}
	review := models.CanteenReviewEvent{ID: 20, CanteenID: canteen.ID, UserID: owner.ID, OverallScore: 4, Status: models.ReviewEventStatusActive, ScoreVersion: 2}
	if err := db.Create(&review).Error; err != nil {
		t.Fatal(err)
	}
	report := models.Report{ReporterID: reporter.ID, TargetType: "canteen_review", TargetID: review.ID, ReasonCode: "abuse", Reason: "举报测试", Status: models.ReportStatusPending}
	if err := db.Create(&report).Error; err != nil {
		t.Fatal(err)
	}

	response := performCanteenRequest(t, NewReportHandler(db).Handle, http.MethodPut,
		"/api/admin/reports/"+itoaForTest(report.ID)+"/handle",
		mapParams("id", itoaForTest(report.ID)), admin.ID,
		`{"status":"handled","result":"确认违规","delete_reason":"内容失实","confirmed_reason_code":"fabricated"}`)
	if response.Code != http.StatusOK {
		t.Fatalf("handle status=%d body=%s", response.Code, response.Body.String())
	}
	var sanction models.CanteenSanction
	if err := db.Where("report_id = ?", report.ID).First(&sanction).Error; err != nil {
		t.Fatal(err)
	}
	if sanction.ReasonCode != "fabricated" || sanction.Points != services.CanteenPenaltyNormal {
		t.Fatalf("sanction=%+v, admin confirmed code was not used", sanction)
	}

	review2 := models.CanteenReviewEvent{CanteenID: canteen.ID, UserID: owner.ID, OverallScore: 2, Status: models.ReviewEventStatusActive, ScoreVersion: 2}
	if err := db.Create(&review2).Error; err != nil {
		t.Fatal(err)
	}
	report2 := models.Report{ReporterID: reporter.ID, TargetType: "canteen_review", TargetID: review2.ID, ReasonCode: "fabricated", Reason: "举报测试", Status: models.ReportStatusPending}
	if err := db.Create(&report2).Error; err != nil {
		t.Fatal(err)
	}
	response = performCanteenRequest(t, NewReportHandler(db).Handle, http.MethodPut,
		"/api/admin/reports/"+itoaForTest(report2.ID)+"/handle",
		mapParams("id", itoaForTest(report2.ID)), admin.ID,
		`{"status":"handled","result":"确认违规","delete_reason":"恶意攻击","confirmed_reason_code":"abuse"}`)
	if response.Code != http.StatusOK {
		t.Fatalf("reverse handle status=%d body=%s", response.Code, response.Body.String())
	}
	sanction = models.CanteenSanction{}
	if err := db.Where("report_id = ?", report2.ID).First(&sanction).Error; err != nil {
		t.Fatal(err)
	}
	if sanction.ReasonCode != "abuse" || sanction.Points != services.CanteenPenaltyMalice {
		t.Fatalf("reverse sanction=%+v, admin confirmed code was not used", sanction)
	}
}

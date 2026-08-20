package handlers

import (
	"net/http"
	"strings"
	"testing"

	"shenliyuan/internal/models"
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

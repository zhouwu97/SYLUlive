package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestCatalogManagedEventRejectsLegacyAdminWrites(t *testing.T) {
	db := newCompetitionTestDB(t)
	migrateCompetitionCatalogAdminTestDB(t, db)
	packageID := uint(7)
	event := models.CompetitionEvent{
		Title: "目录赛事", CompetitionID: "NAT-001", CatalogPackageID: &packageID,
		DatasetVersion: "2026-v1", Status: "draft",
	}
	if err := db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	handler := NewCompetitionHandler(db)

	tests := []struct {
		name   string
		method string
		body   string
		call   func(*gin.Context)
	}{
		{name: "编辑", method: http.MethodPut, body: `{}`, call: handler.AdminUpdateEvent},
		{name: "发布", method: http.MethodPost, call: handler.AdminPublishEvent},
		{name: "归档", method: http.MethodPost, call: handler.AdminArchiveEvent},
		{name: "恢复", method: http.MethodPost, call: handler.AdminRestoreEvent},
		{name: "删除", method: http.MethodDelete, call: handler.AdminDeleteEvent},
		{name: "核验", method: http.MethodPost, call: handler.AdminVerifyEvent},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			context, _ := gin.CreateTestContext(recorder)
			context.Request = httptest.NewRequest(test.method, "/", strings.NewReader(test.body))
			context.Params = gin.Params{{Key: "id", Value: jsonNumber(event.ID)}}
			context.Set("user_id", uint(99))
			test.call(context)
			if recorder.Code != http.StatusConflict {
				t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
			}
			var response map[string]any
			if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
				t.Fatal(err)
			}
			if response["error_code"] != "catalog_managed_event_read_only" {
				t.Fatalf("response=%v", response)
			}
		})
	}
}

func jsonNumber(value uint) string {
	return strconv.FormatUint(uint64(value), 10)
}

func TestAdminBatchActionSkipsCatalogManagedEvents(t *testing.T) {
	db := newCompetitionTestDB(t)
	migrateCompetitionCatalogAdminTestDB(t, db)
	packageID := uint(9)
	catalogEvent := models.CompetitionEvent{
		Title: "目录赛事", CompetitionID: "NAT-009", CatalogPackageID: &packageID,
		DatasetVersion: "2026-v1", Status: "draft",
	}
	manualEvent := models.CompetitionEvent{
		Title: "手工赛事", CompetitionID: "MANUAL-009", DatasetVersion: "legacy", Status: "draft",
	}
	if err := db.Create(&catalogEvent).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&manualEvent).Error; err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]any{
		"action":    "publish",
		"selection": map[string]any{"mode": "ids", "ids": []uint{catalogEvent.ID, manualEvent.ID}},
	})
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodPost, "/", bytes.NewReader(body))
	context.Set("user_id", uint(99))
	NewCompetitionHandler(db).AdminBatchAction(context)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		SuccessCount int                  `json:"success_count"`
		SkippedCount int                  `json:"skipped_count"`
		Skipped      []batchSkippedDetail `json:"skipped"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.SuccessCount != 1 || response.SkippedCount != 1 ||
		len(response.Skipped) != 1 || response.Skipped[0].ID != catalogEvent.ID {
		t.Fatalf("response=%+v", response)
	}
	if err := db.First(&catalogEvent, catalogEvent.ID).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.First(&manualEvent, manualEvent.ID).Error; err != nil {
		t.Fatal(err)
	}
	if catalogEvent.Status != "draft" || manualEvent.Status != "published" {
		t.Fatalf("catalog=%s manual=%s", catalogEvent.Status, manualEvent.Status)
	}
}

func TestCatalogReferencedCategoryRejectsIdentityChanges(t *testing.T) {
	db := newCompetitionTestDB(t)
	migrateCompetitionCatalogAdminTestDB(t, db)
	category := models.CompetitionCategory{Name: "计算机", Slug: "computer", IsActive: true}
	if err := db.Create(&category).Error; err != nil {
		t.Fatal(err)
	}
	packageID := uint(12)
	event := models.CompetitionEvent{
		Title: "目录赛事", CompetitionID: "NAT-012", CatalogPackageID: &packageID,
		PrimaryCategoryID: category.ID, Status: "published",
	}
	if err := db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	handler := NewCompetitionHandler(db)

	for _, test := range []struct {
		name   string
		method string
		body   string
		call   func(*gin.Context)
	}{
		{name: "修改 slug", method: http.MethodPut, body: `{"name":"计算机","slug":"computer-new","is_active":true}`, call: handler.AdminUpdateCategory},
		{name: "停用", method: http.MethodPut, body: `{"name":"计算机","slug":"computer","is_active":false}`, call: handler.AdminUpdateCategory},
		{name: "删除", method: http.MethodDelete, call: handler.AdminDeleteCategory},
	} {
		t.Run(test.name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			context, _ := gin.CreateTestContext(recorder)
			context.Request = httptest.NewRequest(test.method, "/", strings.NewReader(test.body))
			context.Params = gin.Params{{Key: "id", Value: jsonNumber(category.ID)}}
			test.call(context)
			if recorder.Code != http.StatusConflict ||
				!strings.Contains(recorder.Body.String(), "catalog_category_identity_read_only") {
				t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
			}
		})
	}
}

func TestAdminListEventsDefaultsToActiveCatalogScope(t *testing.T) {
	db := newCompetitionTestDB(t)
	migrateCompetitionCatalogAdminTestDB(t, db)
	catalog := models.CompetitionCatalogPackage{
		SchemaVersion: "v1", DatasetVersion: "2026-active", Revision: 1,
		PackageHash: strings.Repeat("a", 64), LifecycleStatus: "active",
		PublishStatus: "published", ProductionLoadAllowed: true, ItemCount: 2,
		ValidationStatus: "passed", ValidationResult: []byte(`{}`), Payload: []byte(`{}`),
		ImportedBy: 1, IsActive: true,
	}
	if err := db.Create(&catalog).Error; err != nil {
		t.Fatal(err)
	}
	activeEvents := []models.CompetitionEvent{
		{Title: "目录一", CompetitionID: "NAT-101", CatalogPackageID: &catalog.ID, Status: "published"},
		{Title: "目录二", CompetitionID: "NAT-102", CatalogPackageID: &catalog.ID, Status: "published"},
	}
	if err := db.Create(&activeEvents).Error; err != nil {
		t.Fatal(err)
	}
	manual := models.CompetitionEvent{Title: "手工", CompetitionID: "MANUAL-101", Status: "draft"}
	duplicate := models.CompetitionEvent{Title: "旧副本", CompetitionID: "LEGACY-101", Status: "archived"}
	if err := db.Create(&manual).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&duplicate).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.CompetitionLegacyDuplicateResolution{
		IdentityHash: strings.Repeat("b", 64), CanonicalEventID: activeEvents[0].ID,
		DuplicateEventID: duplicate.ID, Reason: "重复上传", DuplicatePreviousStatus: "draft",
		ResolvedBy: 1,
	}).Error; err != nil {
		t.Fatal(err)
	}

	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/admin/competitions/events", nil)
	NewCompetitionHandler(db).AdminListEvents(context)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		Items []struct {
			ID               uint   `json:"id"`
			ManagementSource string `json:"management_source"`
			Mutable          bool   `json:"mutable"`
		} `json:"items"`
		Total   int64  `json:"total"`
		Scope   string `json:"scope"`
		Summary struct {
			ActiveCatalog     int64 `json:"active_catalog"`
			Manual            int64 `json:"manual"`
			Superseded        int64 `json:"superseded"`
			ResolvedDuplicate int64 `json:"resolved_duplicates"`
			AllDatabaseRows   int64 `json:"all_database_rows"`
		} `json:"summary"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.Scope != "active" || response.Total != 2 || len(response.Items) != 2 {
		t.Fatalf("scope=%s total=%d items=%+v", response.Scope, response.Total, response.Items)
	}
	for _, item := range response.Items {
		if item.ManagementSource != "catalog" || item.Mutable {
			t.Fatalf("item=%+v", item)
		}
	}
	if response.Summary.ActiveCatalog != 2 || response.Summary.Manual != 1 ||
		response.Summary.Superseded != 1 || response.Summary.ResolvedDuplicate != 1 ||
		response.Summary.AllDatabaseRows != 4 {
		t.Fatalf("summary=%+v", response.Summary)
	}
	for _, expected := range []struct {
		scope string
		total int
	}{
		{scope: "manual", total: 1},
		{scope: "superseded", total: 1},
	} {
		recorder := httptest.NewRecorder()
		context, _ := gin.CreateTestContext(recorder)
		context.Request = httptest.NewRequest(
			http.MethodGet,
			"/admin/competitions/events?scope="+expected.scope,
			nil,
		)
		NewCompetitionHandler(db).AdminListEvents(context)
		if recorder.Code != http.StatusOK {
			t.Fatalf("scope=%s status=%d body=%s", expected.scope, recorder.Code, recorder.Body.String())
		}
		var scoped struct {
			Total int `json:"total"`
		}
		if err := json.Unmarshal(recorder.Body.Bytes(), &scoped); err != nil {
			t.Fatal(err)
		}
		if scoped.Total != expected.total {
			t.Fatalf("scope=%s total=%d want=%d", expected.scope, scoped.Total, expected.total)
		}
	}
}

func TestAdminListLegacyResolutionsUsesAuditAfterDuplicateRowsAreDeleted(t *testing.T) {
	db := newCompetitionTestDB(t)
	migrateCompetitionCatalogAdminTestDB(t, db)
	canonical := models.CompetitionEvent{
		Title: "当前赛事", CompetitionID: "NAT-201", Status: "published",
	}
	if err := db.Create(&canonical).Error; err != nil {
		t.Fatal(err)
	}
	resolutions := []models.CompetitionLegacyDuplicateResolution{
		{IdentityHash: strings.Repeat("c", 64), CanonicalEventID: canonical.ID, DuplicateEventID: 9001, Reason: "旧批次一", DuplicatePreviousStatus: "draft", ResolvedBy: 1},
		{IdentityHash: strings.Repeat("c", 64), CanonicalEventID: canonical.ID, DuplicateEventID: 9002, Reason: "旧批次二", DuplicatePreviousStatus: "draft", ResolvedBy: 1},
	}
	if err := db.Create(&resolutions).Error; err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(http.MethodGet, "/admin/competition-catalog/legacy-resolutions", nil)
	NewCompetitionHandler(db).AdminListCompetitionLegacyResolutions(context)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		Items []struct {
			CanonicalTitle string `json:"canonical_title"`
		} `json:"items"`
		Total          int64 `json:"total"`
		IdentityGroups int64 `json:"identity_groups"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.Total != 2 || response.IdentityGroups != 1 || len(response.Items) != 2 ||
		response.Items[0].CanonicalTitle != canonical.Title {
		t.Fatalf("response=%+v", response)
	}
}

func migrateCompetitionCatalogAdminTestDB(t *testing.T, db *gorm.DB) {
	t.Helper()
	if err := db.AutoMigrate(
		&models.CompetitionCatalogPackage{},
		&models.CompetitionCatalogLegacyMapping{},
		&models.CompetitionLegacyDuplicateResolution{},
		&models.CompetitionCatalogActivationSnapshot{},
	); err != nil {
		t.Fatal(err)
	}
}

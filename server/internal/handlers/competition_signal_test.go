package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func signalRequest(
	t *testing.T,
	handler gin.HandlerFunc,
	body string,
	userID uint,
) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	context.Request = httptest.NewRequest(
		http.MethodPost,
		"/api/user/competitions/candidate-signals",
		bytes.NewReader([]byte(body)),
	)
	context.Request.Header.Set("Content-Type", "application/json")
	if userID != 0 {
		context.Set("user_id", userID)
	}
	handler(context)
	return recorder
}

func seedSignalEvents(t *testing.T, db *gorm.DB, events ...models.CompetitionEvent) {
	t.Helper()
	if err := db.Create(&events).Error; err != nil {
		t.Fatalf("create signal events: %v", err)
	}
}

func TestCompetitionCandidateSignalsAreStoredPerUser(t *testing.T) {
	db := newCompetitionTestDB(t)
	seedSignalEvents(t, db,
		models.CompetitionEvent{ID: 7, CompetitionID: "NAT-007"},
		models.CompetitionEvent{ID: 8, CompetitionID: "NAT-008"},
	)
	handler := NewCompetitionHandler(db).SubmitCompetitionCandidateSignals
	body := `{
		"session_key":"sess-1",
		"algorithm_version":"major-match-v1",
		"signals":[
			{"event_id":7,"competition_id":"NAT-007","kind":"candidate_impression","position":0,"match_tier":"strong","match_basis":"major_cluster"},
			{"event_id":8,"competition_id":"NAT-008","kind":"candidate_click","position":3,"match_tier":"suitable","match_basis":"college"}
		]
	}`
	recorder := signalRequest(t, handler, body, 41)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		Accepted int `json:"accepted"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.Accepted != 2 {
		t.Fatalf("accepted=%d", response.Accepted)
	}

	var rows []models.CompetitionCandidateSignals
	if err := db.Where("user_id = ?", 41).Order("id ASC").Find(&rows).Error; err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("rows=%d", len(rows))
	}
	if rows[0].SessionKey != "sess-1" || rows[0].AlgorithmVersion != "major-match-v1" ||
		rows[0].MatchTier != "strong" || rows[1].Position != 3 {
		t.Fatalf("写入内容不符：%+v", rows)
	}
	// 埋点必须按用户隔离，否则会把 A 的浏览行为算到 B 头上。
	var other int64
	if err := db.Model(&models.CompetitionCandidateSignals{}).
		Where("user_id = ?", 42).Count(&other).Error; err != nil {
		t.Fatal(err)
	}
	if other != 0 {
		t.Fatalf("埋点串到了其他用户：%d", other)
	}
}

func TestCompetitionCandidateSignalsRejectInvalidInput(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db).SubmitCompetitionCandidateSignals
	tests := map[string]string{
		"unknown kind":          `{"session_key":"s","signals":[{"event_id":1,"kind":"teleport","position":0}]}`,
		"missing event":         `{"session_key":"s","signals":[{"event_id":0,"kind":"candidate_click","position":0}]}`,
		"position out of range": `{"session_key":"s","signals":[{"event_id":1,"kind":"candidate_click","position":9999}]}`,
		"empty signals":         `{"session_key":"s","signals":[]}`,
		"unknown field":         `{"session_key":"s","forged":true,"signals":[{"event_id":1,"kind":"candidate_click","position":0}]}`,
	}
	for name, body := range tests {
		t.Run(name, func(t *testing.T) {
			recorder := signalRequest(t, handler, body, 51)
			if recorder.Code != http.StatusBadRequest {
				t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
			}
		})
	}
	var count int64
	if err := db.Model(&models.CompetitionCandidateSignals{}).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("非法请求写入了 %d 条埋点", count)
	}
}

func TestCompetitionCandidateSignalsDeduplicateImpressionsInOneBatch(t *testing.T) {
	db := newCompetitionTestDB(t)
	seedSignalEvents(t, db, models.CompetitionEvent{ID: 9, CompetitionID: "NAT-009"})
	handler := NewCompetitionHandler(db).SubmitCompetitionCandidateSignals
	// 同一会话里同一条赛事因滚动反复进入视口：只应记一次曝光。
	body := `{
		"session_key":"sess-dup",
		"signals":[
			{"event_id":9,"competition_id":"NAT-009","kind":"candidate_impression","position":0},
			{"event_id":9,"competition_id":"NAT-009","kind":"candidate_impression","position":1},
			{"event_id":9,"competition_id":"NAT-009","kind":"candidate_click","position":1}
		]
	}`
	recorder := signalRequest(t, handler, body, 61)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var count int64
	if err := db.Model(&models.CompetitionCandidateSignals{}).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	// 1 条曝光（去重后）+ 1 条点击。
	if count != 2 {
		t.Fatalf("rows=%d want=2", count)
	}
}

func TestCompetitionCandidateSignalsDeduplicateImpressionsAcrossRequests(t *testing.T) {
	db := newCompetitionTestDB(t)
	seedSignalEvents(t, db, models.CompetitionEvent{ID: 10, CompetitionID: "NAT-010"})
	handler := NewCompetitionHandler(db).SubmitCompetitionCandidateSignals
	body := `{"session_key":"sess-cross-request","signals":[{"event_id":10,"competition_id":"NAT-010","kind":"candidate_impression","position":0}]}`
	first := signalRequest(t, handler, body, 71)
	second := signalRequest(t, handler, body, 71)
	if first.Code != http.StatusOK || second.Code != http.StatusOK {
		t.Fatalf("status first=%d second=%d", first.Code, second.Code)
	}
	var firstResponse, secondResponse struct {
		Accepted int64 `json:"accepted"`
	}
	if err := json.Unmarshal(first.Body.Bytes(), &firstResponse); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(second.Body.Bytes(), &secondResponse); err != nil {
		t.Fatal(err)
	}
	if firstResponse.Accepted != 1 || secondResponse.Accepted != 0 {
		t.Fatalf("accepted first=%d second=%d", firstResponse.Accepted, secondResponse.Accepted)
	}
	var count int64
	if err := db.Model(&models.CompetitionCandidateSignals{}).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("rows=%d want=1", count)
	}
}

func TestCompetitionCandidateSignalsAcceptFitTabExposureWithoutEvent(t *testing.T) {
	db := newCompetitionTestDB(t)
	recorder := signalRequest(t, NewCompetitionHandler(db).SubmitCompetitionCandidateSignals,
		`{"session_key":"fit-tab","signals":[{"event_id":0,"kind":"fit_tab_exposure","position":0}]}`,
		73,
	)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		Accepted int64 `json:"accepted"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.Accepted != 1 {
		t.Fatalf("accepted=%d", response.Accepted)
	}
	var row models.CompetitionCandidateSignals
	if err := db.First(&row).Error; err != nil {
		t.Fatal(err)
	}
	if row.Kind != models.CompetitionSignalFitTabExposure || row.EventID != 0 || row.CompetitionID != "" {
		t.Fatalf("fit tab 埋点内容不符：%+v", row)
	}
}

func TestCompetitionCandidateSignalsRejectMismatchedCompetitionID(t *testing.T) {
	db := newCompetitionTestDB(t)
	seedSignalEvents(t, db, models.CompetitionEvent{ID: 11, CompetitionID: "NAT-011"})
	recorder := signalRequest(t, NewCompetitionHandler(db).SubmitCompetitionCandidateSignals,
		`{"session_key":"s","signals":[{"event_id":11,"competition_id":"forged","kind":"candidate_click","position":0}]}`,
		72,
	)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestCompetitionCandidateSignalsRequireAuthentication(t *testing.T) {
	db := newCompetitionTestDB(t)
	recorder := signalRequest(
		t, NewCompetitionHandler(db).SubmitCompetitionCandidateSignals,
		`{"session_key":"s","signals":[{"event_id":1,"kind":"candidate_click","position":0}]}`, 0,
	)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

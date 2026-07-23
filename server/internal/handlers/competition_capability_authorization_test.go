package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/models"
)

func createCapabilityAuthorizationUsers(t *testing.T, handler *CompetitionHandler) {
	t.Helper()
	for _, user := range []models.User{
		{ID: 81, StudentID: "capability-a", PasswordHash: "test", Nickname: "A"},
		{ID: 82, StudentID: "capability-b", PasswordHash: "test", Nickname: "B"},
	} {
		if err := handler.db.Create(&user).Error; err != nil {
			t.Fatal(err)
		}
	}
}

func capabilityAuthorizationRequest(t *testing.T, handlerFunc func(*gin.Context), method, body string, userID uint) *httptest.ResponseRecorder {
	t.Helper()
	return preferenceRequest(t, handlerFunc, method, body, userID)
}

func decodeCapabilityAIAccess(t *testing.T, recorder *httptest.ResponseRecorder) competitionCapabilityAIAccessResponse {
	t.Helper()
	var response competitionCapabilityAIAccessResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func TestCompetitionCapabilityAIAccessDefaultsOffAndIsUserIsolated(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	createCapabilityAuthorizationUsers(t, handler)

	initialA := capabilityAuthorizationRequest(t, handler.GetCompetitionCapabilityAIAccess, http.MethodGet, "", 81)
	if initialA.Code != http.StatusOK || decodeCapabilityAIAccess(t, initialA).Enabled {
		t.Fatalf("initial A status=%d body=%s", initialA.Code, initialA.Body.String())
	}
	enabled := capabilityAuthorizationRequest(t, handler.PutCompetitionCapabilityAIAccess, http.MethodPut, `{"enabled":true}`, 81)
	state := decodeCapabilityAIAccess(t, enabled)
	if enabled.Code != http.StatusOK || !state.Enabled || state.EnabledAt == nil {
		t.Fatalf("enabled status=%d state=%+v", enabled.Code, state)
	}
	initialB := capabilityAuthorizationRequest(t, handler.GetCompetitionCapabilityAIAccess, http.MethodGet, "", 82)
	if initialB.Code != http.StatusOK || decodeCapabilityAIAccess(t, initialB).Enabled {
		t.Fatalf("A authorization leaked to B: %s", initialB.Body.String())
	}
}

func TestAICompetitionCapabilityProfileRequiresLiveAuthorization(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	createCapabilityAuthorizationUsers(t, handler)

	denied := capabilityAuthorizationRequest(t, handler.GetAICompetitionCapabilityProfile, http.MethodGet, "", 81)
	if denied.Code != http.StatusForbidden {
		t.Fatalf("denied status=%d body=%s", denied.Code, denied.Body.String())
	}
	if got := capabilityAuthorizationRequest(t, handler.PutCompetitionCapabilityAIAccess, http.MethodPut, `{"enabled":true}`, 81); got.Code != http.StatusOK {
		t.Fatalf("enable status=%d body=%s", got.Code, got.Body.String())
	}
	allowed := capabilityAuthorizationRequest(t, handler.GetAICompetitionCapabilityProfile, http.MethodGet, "", 81)
	if allowed.Code != http.StatusOK {
		t.Fatalf("allowed status=%d body=%s", allowed.Code, allowed.Body.String())
	}
	if got := capabilityAuthorizationRequest(t, handler.PutCompetitionCapabilityAIAccess, http.MethodPut, `{"enabled":false}`, 81); got.Code != http.StatusOK {
		t.Fatalf("disable status=%d body=%s", got.Code, got.Body.String())
	}
	deniedAgain := capabilityAuthorizationRequest(t, handler.GetAICompetitionCapabilityProfile, http.MethodGet, "", 81)
	if deniedAgain.Code != http.StatusForbidden {
		t.Fatalf("disabled authorization remained usable: %d %s", deniedAgain.Code, deniedAgain.Body.String())
	}
}

func TestCompetitionCapabilityAIAccessRejectsInvalidPayload(t *testing.T) {
	db := newCompetitionTestDB(t)
	handler := NewCompetitionHandler(db)
	createCapabilityAuthorizationUsers(t, handler)
	for _, body := range []string{`{}`, `{"enabled":"yes"}`, `{"enabled":true,"other":1}`, `{"enabled":true}{"enabled":false}`} {
		recorder := capabilityAuthorizationRequest(t, handler.PutCompetitionCapabilityAIAccess, http.MethodPut, body, 81)
		if recorder.Code != http.StatusBadRequest {
			t.Fatalf("body=%s status=%d response=%s", body, recorder.Code, recorder.Body.String())
		}
	}
}

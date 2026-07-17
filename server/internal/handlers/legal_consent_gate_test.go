package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

func TestLegacyUserMustAcceptLegalConsentsBeforeUsingBusinessAPIs(t *testing.T) {
	gin.SetMode(gin.TestMode)
	middleware.InvalidateTokenVersionCache(0)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	user := models.User{StudentID: "2026000001", PasswordHash: "hash"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}
	token, err := middleware.GenerateToken(user.ID, string(models.RoleUser), user.TokenVersion, "secret")
	if err != nil {
		t.Fatalf("generate token: %v", err)
	}

	handler := NewAuthHandler(db, "secret")
	router := gin.New()
	router.GET("/api/private", middleware.AuthMiddleware(db, "secret"), func(c *gin.Context) {
		c.Status(http.StatusOK)
	})
	router.POST("/api/user/legal-consents", middleware.AuthMiddleware(db, "secret"), handler.AcceptLegalConsents)

	privateRequest := httptest.NewRequest(http.MethodGet, "/api/private", nil)
	privateRequest.Header.Set("Authorization", "Bearer "+token)
	privateResponse := httptest.NewRecorder()
	router.ServeHTTP(privateResponse, privateRequest)
	if privateResponse.Code != http.StatusForbidden ||
		!strings.Contains(privateResponse.Body.String(), "legal_consent_required") {
		t.Fatalf("legacy private status=%d body=%s", privateResponse.Code, privateResponse.Body.String())
	}

	acceptRequest := httptest.NewRequest(
		http.MethodPost,
		"/api/user/legal-consents",
		strings.NewReader(`{"user_agreement_accepted":true,"privacy_policy_accepted":true,"community_rules_accepted":true,"minor_protection_accepted":true,"content_complaint_accepted":true,"sdk_disclosure_accepted":true}`),
	)
	acceptRequest.Header.Set("Authorization", "Bearer "+token)
	acceptRequest.Header.Set("Content-Type", "application/json")
	acceptResponse := httptest.NewRecorder()
	router.ServeHTTP(acceptResponse, acceptRequest)
	if acceptResponse.Code != http.StatusOK {
		t.Fatalf("accept status=%d body=%s", acceptResponse.Code, acceptResponse.Body.String())
	}
	var payload struct {
		User struct {
			LegalConsentsActive   bool `json:"legal_consents_active"`
			LegalConsentsRequired bool `json:"legal_consents_required"`
		} `json:"user"`
	}
	if err := json.Unmarshal(acceptResponse.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode accept response: %v", err)
	}
	if !payload.User.LegalConsentsActive || payload.User.LegalConsentsRequired {
		t.Fatalf("unexpected consent state: %#v", payload.User)
	}

	privateResponse = httptest.NewRecorder()
	router.ServeHTTP(privateResponse, privateRequest)
	if privateResponse.Code != http.StatusOK {
		t.Fatalf("accepted private status=%d body=%s", privateResponse.Code, privateResponse.Body.String())
	}
}

package handlers

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestFetchProviderModels(t *testing.T) {
	gin.SetMode(gin.TestMode)
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/models" {
			http.NotFound(w, r)
			return
		}
		if r.Header.Get("Authorization") != "Bearer secret-key" {
			t.Fatalf("unexpected authorization header")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":[{"id":"model-b"},{"id":"model-a"}]}`))
	}))
	defer remote.Close()

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.YunkaoAiProvider{}); err != nil {
		t.Fatal(err)
	}
	provider := models.YunkaoAiProvider{
		ProviderKey: "test",
		Label:       "Test",
		BaseURL:     remote.URL + "/v1",
		APIKey:      "secret-key",
	}
	if err := db.Create(&provider).Error; err != nil {
		t.Fatal(err)
	}

	handler := NewYunkaoAdminHandler(db)
	router := gin.New()
	router.GET("/providers/:id/remote-models", handler.FetchProviderModels)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(
		http.MethodGet,
		"/providers/"+strconv.FormatUint(uint64(provider.ID), 10)+"/remote-models",
		nil,
	)
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, `"models":["model-a","model-b"]`) {
		t.Fatalf("unexpected response: %s", body)
	}
}

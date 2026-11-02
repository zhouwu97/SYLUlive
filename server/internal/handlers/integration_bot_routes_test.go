package handlers

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

// Production can expose owner management while all automatic publishing stays disabled.
func TestManagedBotRoutesAvailableWithAutomaticPublishingDisabled(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	pool, err := db.DB()
	require.NoError(t, err)
	t.Cleanup(func() { _ = pool.Close() })
	h := NewIntegrationHandler(db, IntegrationOptions{PublicOrigin: "https://fixture.invalid", PersonalDataEnabled: true})
	router := gin.New()
	h.Register(router, "synthetic-routes-secret")
	for _, route := range []struct{ method, path string }{
		{http.MethodGet, "/api/connected-apps/bot"},
		{http.MethodPost, "/api/connected-apps/bot"},
		{http.MethodGet, "/api/integrations/v1/bot/policy"},
		{http.MethodPost, "/api/integrations/v1/bot/replies"},
		{http.MethodPost, "/api/connected-apps/personal-sync/grades"},
		{http.MethodDelete, "/api/connected-apps/personal-sync/grades"},
		{http.MethodGet, "/api/integrations/v1/me/grades"},
		{http.MethodGet, "/api/integrations/v1/me/erke"},
	} {
		t.Run(route.method+" "+route.path, func(t *testing.T) {
			out := httptest.NewRecorder()
			req := httptest.NewRequest(route.method, route.path, strings.NewReader("{}"))
			req.Header.Set("Content-Type", "application/json")
			router.ServeHTTP(out, req)
			require.Equal(t, http.StatusUnauthorized, out.Code, out.Body.String())
			require.Contains(t, out.Header().Get("Content-Type"), "application/json")
			require.NotContains(t, out.Body.String(), "404 page not found")
		})
	}
}

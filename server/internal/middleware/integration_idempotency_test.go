package middleware

import (
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestIdempotencyDoesNotCacheIntegrationCredentialsOrConfirmation(t *testing.T) {
	for _, path := range []string{"/api/oauth/token", "/api/connected-apps/actions/action/decision", "/api/integrations/v1/actions"} {
		t.Run(path, func(t *testing.T) {
			db := openIdempotencyTestDB(t)
			r := gin.New()
			r.Use(IdempotencyMiddleware(db))
			calls := 0
			r.POST(path, func(c *gin.Context) { calls++; c.JSON(200, gin.H{"result": calls}) })
			for i := 1; i <= 2; i++ {
				req := httptest.NewRequest("POST", path, strings.NewReader(`{}`))
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("Idempotency-Key", "same-key")
				w := httptest.NewRecorder()
				r.ServeHTTP(w, req)
				require.Equal(t, 200, w.Code)
			}
			require.Equal(t, 2, calls, "必须执行每一次当前授权/来源复核，由业务事务去重")
		})
	}
}

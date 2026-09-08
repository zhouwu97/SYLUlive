package middleware

import (
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSchoolSecretsFreezePreservesCleanupAndIdentityVerification(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, test := range []struct {
		method, path string
		blocked      bool
	}{
		{"POST", "/api/edu/bind", true}, {"POST", "/api/edu/grades", true},
		{"POST", "/api/edu/session/resume", true}, {"POST", "/api/login_edu", true},
		{"DELETE", "/api/edu/bind", false}, {"DELETE", "/api/edu/authorization", false},
		{"POST", "/api/edu/session/logout", false}, {"POST", "/api/edu/pre_verify", false},
		{"POST", "/api/student-identity/change", false},
	} {
		t.Run(test.method+test.path, func(t *testing.T) {
			router := gin.New()
			router.Use(SchoolLegacySecretsFreezeGate(true))
			called := false
			router.Any(test.path, func(c *gin.Context) { called = true; c.Status(http.StatusNoContent) })
			response := httptest.NewRecorder()
			router.ServeHTTP(response, httptest.NewRequest(test.method, test.path, nil))
			require.Equal(t, !test.blocked, called)
			if test.blocked {
				require.Equal(t, http.StatusGone, response.Code)
			}
		})
	}
}

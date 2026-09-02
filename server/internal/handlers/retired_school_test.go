package handlers

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

type bodyReadPanic struct{}

func (bodyReadPanic) Read([]byte) (int, error) { return 0, errors.New("request body must not be read") }
func (bodyReadPanic) Close() error             { return nil }

func TestRetiredSchoolRoutesReturnGoneBeforeBodyParse(t *testing.T) {
	gin.SetMode(gin.TestMode)
	cases := []struct {
		name    string
		handler gin.HandlerFunc
		path    string
		code    string
	}{
		{name: "legacy auth", handler: RetiredLegacyEduRoute, path: "/api/login_edu", code: LegacyEduRouteRetiredCode},
		{name: "academic", handler: RetiredSchoolAcademicRoute, path: "/api/edu/bind", code: SchoolAcademicRouteRetiredCode},
		{name: "device", handler: RetiredSchoolDeviceCapability, path: "/api/device/jobs", code: SchoolDeviceCapabilityRetiredCode},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			oldHandlerCalls := 0
			r := gin.New()
			r.Any("/*path", tc.handler, func(c *gin.Context) {
				oldHandlerCalls++
				c.Status(http.StatusTeapot)
			})
			req := httptest.NewRequest(http.MethodPost, tc.path, io.NopCloser(bodyReadPanic{}))
			req.ContentLength = 32
			response := httptest.NewRecorder()
			r.ServeHTTP(response, req)
			require.Equal(t, http.StatusGone, response.Code)
			require.Equal(t, "no-store", response.Header().Get("Cache-Control"))
			require.Contains(t, response.Header().Get("Sunset"), "true")
			require.Contains(t, response.Body.String(), tc.code)
			require.Equal(t, 0, oldHandlerCalls)
		})
	}
}

func TestRegisterRetiredSchoolAuthorityRoutesCoversReleaseDContract(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	RegisterRetiredSchoolAuthorityRoutes(router)

	cases := []struct {
		path string
		code string
	}{
		{path: "/api/login_edu", code: LegacyEduRouteRetiredCode},
		{path: "/api/register_with_edu", code: LegacyEduRouteRetiredCode},
		{path: "/api/forgot_password", code: LegacyEduRouteRetiredCode},
		{path: "/api/password/edu/reset", code: LegacyEduRouteRetiredCode},
		{path: "/api/personal-snapshots/erke", code: SchoolAcademicRouteRetiredCode},
		{path: "/api/edu", code: SchoolAcademicRouteRetiredCode},
		{path: "/api/edu/bind", code: SchoolAcademicRouteRetiredCode},
		{path: "/api/login_edu/", code: LegacyEduRouteRetiredCode},
		{path: "/api/personal-snapshots/erke/", code: SchoolAcademicRouteRetiredCode},
		{path: "/api/edu/", code: SchoolAcademicRouteRetiredCode},
	}

	for _, tc := range cases {
		t.Run(tc.path, func(t *testing.T) {
			for _, method := range []string{
				http.MethodGet,
				http.MethodHead,
				http.MethodPost,
				http.MethodPut,
				http.MethodPatch,
				http.MethodDelete,
				http.MethodOptions,
			} {
				request := httptest.NewRequest(method, tc.path, io.NopCloser(bodyReadPanic{}))
				request.ContentLength = 32
				request.Header.Set("Content-Type", "application/json")
				request.Header.Set("Authorization", "Bearer invalid-token-must-not-be-checked")
				response := httptest.NewRecorder()
				router.ServeHTTP(response, request)
				require.Equal(t, http.StatusGone, response.Code)
				if method != http.MethodHead {
					require.Contains(t, response.Body.String(), tc.code)
					require.NotContains(t, response.Body.String(), tc.path)
				}
			}
		})
	}
}

func TestRetiredSchoolAuthorityRoutesCoverEveryFormerGoEndpoint(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	RegisterRetiredSchoolAuthorityRoutes(router)

	cases := []struct {
		method string
		path   string
		code   string
	}{
		{method: http.MethodPost, path: "/api/login_edu", code: LegacyEduRouteRetiredCode},
		{method: http.MethodPost, path: "/api/register_with_edu", code: LegacyEduRouteRetiredCode},
		{method: http.MethodPost, path: "/api/forgot_password", code: LegacyEduRouteRetiredCode},
		{method: http.MethodPost, path: "/api/password/edu/reset", code: LegacyEduRouteRetiredCode},
		{method: http.MethodPut, path: "/api/personal-snapshots/erke", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodGet, path: "/api/personal-snapshots/erke", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodDelete, path: "/api/personal-snapshots/erke", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodGet, path: "/api/edu/status", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodPost, path: "/api/edu/bind", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodDelete, path: "/api/edu/bind", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodPost, path: "/api/edu/session/logout", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodPost, path: "/api/edu/session/resume", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodDelete, path: "/api/edu/authorization", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodPost, path: "/api/edu/courses", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodGet, path: "/api/edu/courses/local", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodPost, path: "/api/edu/courses/sync", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodPost, path: "/api/edu/grades", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodPost, path: "/api/edu/grades/detail", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodPost, path: "/api/edu/academic-situation", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodPost, path: "/api/edu/credit-requirements", code: SchoolAcademicRouteRetiredCode},
		{method: http.MethodPost, path: "/api/edu/pre_verify", code: SchoolAcademicRouteRetiredCode},
	}

	for _, tc := range cases {
		t.Run(tc.method+" "+tc.path, func(t *testing.T) {
			request := httptest.NewRequest(tc.method, tc.path, io.NopCloser(bodyReadPanic{}))
			request.ContentLength = 32
			request.Header.Set("Content-Type", "application/json")
			request.Header.Set("Authorization", "Bearer invalid-token-must-not-be-checked")
			response := httptest.NewRecorder()
			router.ServeHTTP(response, request)
			require.Equal(t, http.StatusGone, response.Code)
			require.Contains(t, response.Body.String(), tc.code)
		})
	}
}

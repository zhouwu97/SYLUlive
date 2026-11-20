package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"shenliyuan/internal/models"
)

func TestLegalDocumentsEmbeddedAndPublic(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	registerLegalDocumentRoutes(r)
	for path, title := range map[string]string{"/terms": "沈理校园用户协议", "/privacy": "沈理校园隐私政策", "/extension/privacy": "沈理校园教务助手隐私说明"} {
		t.Run(path, func(t *testing.T) {
			version := models.LegalDocumentVersion
			if path == "/extension/privacy" {
				version = "2026-11-11-e1"
			}
			for _, method := range []string{http.MethodGet, http.MethodHead} {
				w := httptest.NewRecorder()
				r.ServeHTTP(w, httptest.NewRequest(method, path, nil))
				if w.Code != http.StatusOK || !strings.HasPrefix(w.Header().Get("Content-Type"), "text/html") {
					t.Fatalf("%s %s: status=%d type=%q", method, path, w.Code, w.Header().Get("Content-Type"))
				}
				if w.Header().Get("Cache-Control") != "no-cache" || w.Header().Get("X-Content-Type-Options") != "nosniff" {
					t.Fatal("public legal document headers missing")
				}
				if method == http.MethodGet && (!strings.Contains(w.Body.String(), "<h1>"+title+"</h1>") || !strings.Contains(w.Body.String(), version) || strings.Contains(w.Body.String(), "TODO")) {
					t.Fatal("legal document is missing its body/version or still contains a placeholder")
				}
				if method == http.MethodGet {
					for _, contact := range []string{"纯合子：3170305904@qq.com", "掉分员：2350016823@qq.com", "Now：1517088507@qq.com"} {
						if !strings.Contains(w.Body.String(), contact) {
							t.Fatalf("%s is missing the App's public developer contact: %s", path, contact)
						}
					}
				}
			}
		})
	}
	for _, path := range []string{"/legal", "/legal/terms.html", "/privacy/other", "/legal_routes.go"} {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
		if w.Code != http.StatusNotFound {
			t.Fatalf("unexpected static resource exposure: %s returned %d", path, w.Code)
		}
	}
}

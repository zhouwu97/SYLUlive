package main

import (
	"net/http"

	"github.com/gin-gonic/gin"
	staticassets "shenliyuan/static"
)

func registerLegalDocumentRoutes(r *gin.Engine) {
	legal := r.Group("", func(c *gin.Context) {
		c.Header("Cache-Control", "no-cache")
		c.Header("X-Content-Type-Options", "nosniff")
		c.Header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
		c.Next()
	})
	files := http.FS(staticassets.LegalPages)
	legal.StaticFileFS("/terms", "legal/terms.html", files)
	legal.StaticFileFS("/privacy", "legal/privacy.html", files)
	legal.StaticFileFS("/extension/privacy", "legal/extension-privacy.html", files)
}

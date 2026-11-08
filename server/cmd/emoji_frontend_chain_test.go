package main

import (
	"encoding/json"
	"encoding/pem"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"shenliyuan/internal/academiccalendar"
	"shenliyuan/internal/handlers"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

// 仅供显式启动的 Flutter 联调：真实路由、临时 SQLite/上传卷与随机 loopback TLS 端口。
// 不读取服务端配置，也不连接已有数据库；常规 Go 测试不会启动常驻服务。
func TestEmojiFrontendChainServer(t *testing.T) {
	configPath := os.Getenv("EMOJI_CHAIN_CONFIG")
	if configPath == "" {
		t.Skip("set EMOJI_CHAIN_CONFIG for the isolated Flutter API chain")
	}
	f := newEmojiPackRoutesFixture(t)
	t.Setenv("UPLOAD_DIR", f.dir)
	oldLocal, oldShanghai := time.Local, academiccalendar.ShanghaiLocation
	require.NoError(t, academiccalendar.InitializeTimezone())
	t.Cleanup(func() { time.Local, academiccalendar.ShanghaiLocation = oldLocal, oldShanghai })
	require.NoError(t, f.db.Where("user_id = ?", 1).Delete(&models.EmojiCreator{}).Error)
	require.NoError(t, f.db.AutoMigrate(&models.Post{}, &models.Reply{}, &models.ReplyImage{}, &models.File{}, &models.FileUploadGrant{}, &models.ImageVariant{}, &models.Notification{}, &models.ExpLog{}, &models.IdempotencyRecord{}))
	require.NoError(t, f.db.Create(&models.Post{ID: 1, AuthorID: 2, BoardID: models.BoardMarket, Content: "隔离联调帖子", Status: models.PostStatusNormal}).Error)
	upload := handlers.NewUploadHandler(f.dir, 10<<20, f.db)
	f.router.POST("/api/upload", middleware.AuthMiddleware(f.db, "emoji-test-secret"), upload.Upload)
	f.router.GET("/uploads/*filepath", upload.ServePublic)
	replies := handlers.NewReplyHandler(f.db, "", "")
	f.router.POST("/api/posts/:id/replies", middleware.AuthMiddleware(f.db, "emoji-test-secret"), middleware.RequireCommunityRules(f.db), replies.Create)
	server := httptest.NewTLSServer(f.router)
	defer server.Close()
	config, err := json.Marshal(map[string]any{
		"base_url":    server.URL + "/api",
		"certificate": string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})),
		"tokens":      f.tokens,
	})
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(configPath, config, 0600))
	defer os.Remove(configPath)
	// 生命周期由仅本机的文件控制，避免给被测 API 添加额外控制路由。
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	deadline := time.After(12 * time.Minute)
	for {
		select {
		case <-ticker.C:
			if _, err := os.Stat(configPath + ".stop"); err == nil {
				_ = os.Remove(configPath + ".stop")
				return
			}
		case <-deadline:
			t.Fatal("isolated frontend chain server timed out")
		}
	}
}

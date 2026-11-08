package handlers

import (
	"encoding/json"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// This opt-in check runs the actual Web, Python client, SDK command dispatch and Go HTTP handlers.
// Only synthetic users and an in-memory DB are available; unmatched APIs never reach Vite's proxy.
func TestIntegrationWebAstrBotCrossRuntime(t *testing.T) {
	python := os.Getenv("SYLULIVE_FULL_CHAIN_PYTHON")
	if python == "" {
		t.Skip("set SYLULIVE_FULL_CHAIN_PYTHON to an isolated AstrBot 4.29.3 environment")
	}
	web, err := url.Parse(os.Getenv("SYLULIVE_FULL_CHAIN_WEB"))
	require.NoError(t, err)
	require.Equal(t, "http", web.Scheme)
	require.Equal(t, "127.0.0.1", web.Hostname())
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{Logger: logger.Discard})
	require.NoError(t, err)
	pool, err := db.DB()
	require.NoError(t, err)
	pool.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = pool.Close(); middleware.InvalidateTokenVersionCache(91234) })
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}, &models.AcademicIdentityBinding{}, &models.RefreshToken{}, &models.IntegrationBinding{}, &models.IntegrationCredential{}, &models.IntegrationDeviceRequest{}, &models.IntegrationAction{}, &models.IntegrationAudit{}, &models.IntegrationRateBucket{}, &models.Post{}, &models.Reply{}, &models.WaterSection{}, &models.WaterSectionMute{}, &models.ManagedBot{}, &models.PersonalUploadedSnapshot{}, &models.AcademicSnapshot{}, &models.AIUserPermission{}, &models.CheckIn{}, &models.File{}, &models.PostImage{}, &models.ReplyImage{}))
	const owner = 91234
	const otherOwner = owner + 1
	const secret = "synthetic-cross-runtime-only-secret"
	require.NoError(t, db.AutoMigrate(&models.Notification{}, &models.FileUploadGrant{}, &models.ImageVariant{}))
	require.NoError(t, db.Create(&models.User{ID: owner, Nickname: "跨端合成用户", Role: models.RoleUser, AccountStatus: "active"}).Error)
	require.NoError(t, db.Create(&models.AcademicIdentityBinding{UserID: owner, ProviderID: models.AcademicProviderUndergraduate, StudentID: "2099000001", VerifiedAt: time.Now(), VerificationMethod: "school_profile", VerificationVersion: "v1", BindingVersion: 1}).Error)
	for _, doc := range []string{models.LegalDocumentUserAgreement, models.LegalDocumentPrivacyPolicy, models.LegalDocumentCommunityRules} {
		ack := ""
		if doc == models.LegalDocumentCommunityRules {
			ack = "rules_acceptance"
		}
		require.NoError(t, db.Create(&models.UserLegalConsent{UserID: owner, Document: doc, Version: models.LegalDocumentVersion, AcceptedAt: time.Now(), AcknowledgementType: ack}).Error)
	}
	require.NoError(t, db.Create(&models.User{ID: otherOwner, Nickname: "第二个跨端合成用户", Role: models.RoleUser, AccountStatus: "active"}).Error)
	require.NoError(t, db.Create(&models.AcademicIdentityBinding{UserID: otherOwner, ProviderID: models.AcademicProviderUndergraduate, StudentID: "2099000002", VerifiedAt: time.Now(), VerificationMethod: "school_profile", VerificationVersion: "v1", BindingVersion: 1}).Error)
	for _, doc := range []string{models.LegalDocumentUserAgreement, models.LegalDocumentPrivacyPolicy, models.LegalDocumentCommunityRules} {
		ack := ""
		if doc == models.LegalDocumentCommunityRules {
			ack = "rules_acceptance"
		}
		require.NoError(t, db.Create(&models.UserLegalConsent{UserID: otherOwner, Document: doc, Version: models.LegalDocumentVersion, AcceptedAt: time.Now(), AcknowledgementType: ack}).Error)
	}
	t.Cleanup(func() { middleware.InvalidateTokenVersionCache(otherOwner) })
	for _, slug := range []string{"campus_life", "course_study"} {
		require.NoError(t, db.Create(&models.WaterSection{Slug: slug, Title: slug, Status: "active"}).Error)
	}
	require.NoError(t, db.Create(&models.Post{AuthorID: owner, Title: "跨端公开合成帖子", Content: "公开正文", Contact: "synthetic-private-contact", PostType: "campus_life", BoardID: models.BoardShuitie, Status: models.PostStatusNormal, ContentKind: models.PostContentKindNormal}).Error)
	r := gin.New()
	h := NewIntegrationHandler(db, IntegrationOptions{PersonalDataEnabled: true, ProposalsEnabled: true, AutoPostEnabled: true, AutoReplyEnabled: true})
	uploadRoot := t.TempDir()
	t.Setenv("UPLOAD_DIR", uploadRoot)
	h.SetBotUploader(NewUploadHandler(uploadRoot, 4<<20, db))
	h.Register(r, secret)
	personal := NewPersonalSnapshotHandler(services.NewPersonalSnapshotService(db, time.Now))
	ownerAPI := r.Group("/api", middleware.AuthMiddleware(db, secret))
	ownerAPI.GET("/user/profile", NewUserHandler(db).GetProfile)
	ownerAPI.PUT("/personal-snapshots/erke", personal.PutErke)
	ownerAPI.DELETE("/personal-snapshots/erke", personal.DeleteErke)
	proxy := httputil.NewSingleHostReverseProxy(web)
	r.NoRoute(func(c *gin.Context) {
		if strings.HasPrefix(c.Request.URL.Path, "/web") {
			proxy.ServeHTTP(c.Writer, c.Request)
			return
		}
		c.Status(404)
	})
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest("POST", "/api/login", nil)
	_, family, err := issueRefreshSessionForDB(db, owner, c)
	require.NoError(t, err)
	jwt, err := middleware.GenerateToken(owner, string(models.RoleUser), 0, secret, family)
	require.NoError(t, err)
	_, secondFamily, err := issueRefreshSessionForDB(db, otherOwner, c)
	require.NoError(t, err)
	secondJWT, err := middleware.GenerateToken(otherOwner, string(models.RoleUser), 0, secret, secondFamily)
	require.NoError(t, err)
	server := httptest.NewServer(r)
	h.options.PublicOrigin = server.URL
	defer server.Close()
	root, err := filepath.Abs("../../..")
	require.NoError(t, err)
	cmd := exec.Command(python, filepath.Join(root, "scripts", "verify-web-astrbot-chain.py"))
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "SYLULIVE_FULL_CHAIN_ORIGIN="+server.URL, "SYLULIVE_FULL_CHAIN_JWT="+jwt, "PYTHONUTF8=1", "ASTRBOT_ROOT="+t.TempDir(), "PYTHONPATH="+root+string(os.PathListSeparator)+filepath.Join(root, "astrbot_plugin_sylulive", "tests"))
	cmd.Env = append(cmd.Env, "SYLULIVE_FULL_CHAIN_SECOND_JWT="+secondJWT)
	output, err := cmd.CombinedOutput()
	require.NoError(t, err, string(output))
	var result map[string]any
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	require.NoError(t, json.Unmarshal([]byte(lines[len(lines)-1]), &result), string(output))
	require.Equal(t, true, result["passed"], string(output))
	var bot models.ManagedBot
	require.NoError(t, db.Where("owner_id = ?", owner).Take(&bot).Error)
	var posts []models.Post
	require.NoError(t, db.Preload("Author").Where("author_id = ?", bot.UserID).Find(&posts).Error)
	require.Len(t, posts, 1)
	require.NotNil(t, posts[0].Author.AIBot)
	require.EqualValues(t, owner, posts[0].Author.AIBot.OwnerID)
	var replies []models.Reply
	require.NoError(t, db.Preload("Author").Where("author_id = ?", bot.UserID).Find(&replies).Error)
	require.Len(t, replies, 1)
	require.NotEmpty(t, replies[0].StickerID)
	require.NotNil(t, replies[0].Author.AIBot)
	var images int64
	require.NoError(t, db.Model(&models.PostImage{}).Where("post_id = ?", posts[0].ID).Count(&images).Error)
	require.EqualValues(t, 1, images)
	var secondBot models.ManagedBot
	require.NoError(t, db.Where("owner_id = ?", otherOwner).Take(&secondBot).Error)
	var secondReplies []models.Reply
	require.NoError(t, db.Where("author_id = ?", secondBot.UserID).Find(&secondReplies).Error)
	require.Len(t, secondReplies, 1)
	var secondPosts []models.Post
	require.NoError(t, db.Where("author_id = ?", secondBot.UserID).Find(&secondPosts).Error)
	require.Len(t, secondPosts, 1)
	require.NotEqual(t, secondBot.UserID, bot.UserID)
	require.False(t, bot.Enabled, "pausing the first account does not stop the second")
	t.Log(string(lines[len(lines)-1]))
}

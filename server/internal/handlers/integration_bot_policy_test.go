package handlers

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
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

func TestManagedBotHTTPCreatePausedEditRecentPauseAndReadPolicy(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	require.NoError(t, err)
	pool, _ := db.DB()
	pool.SetMaxOpenConns(1)
	const owner = 92234
	const secret = "synthetic-bot-policy-secret"
	t.Cleanup(func() { _ = pool.Close(); middleware.InvalidateTokenVersionCache(owner) })
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.RefreshToken{}, &models.UserLegalConsent{}, &models.AcademicIdentityBinding{}, &models.ManagedBot{}, &models.IntegrationBinding{}, &models.IntegrationCredential{}, &models.IntegrationRateBucket{}, &models.WaterSection{}, &models.Post{}, &models.Reply{}, &models.PostImage{}, &models.ReplyImage{}, &models.File{}))
	require.NoError(t, db.Create(&models.User{ID: owner, Nickname: "公开创建者", AccountStatus: "active", PasswordHash: "synthetic"}).Error)
	academic := models.AcademicIdentityBinding{UserID: owner, ProviderID: models.AcademicProviderUndergraduate, StudentID: "synthetic-bot-owner", BindingVersion: 1, VerifiedAt: time.Now(), VerificationMethod: models.AcademicVerificationMethodSchoolProfile, VerificationVersion: "v1"}
	require.NoError(t, db.Create(&academic).Error)
	for _, doc := range []string{models.LegalDocumentUserAgreement, models.LegalDocumentPrivacyPolicy, models.LegalDocumentCommunityRules} {
		ack := ""
		if doc == models.LegalDocumentCommunityRules {
			ack = "rules_acceptance"
		}
		require.NoError(t, db.Create(&models.UserLegalConsent{UserID: owner, Document: doc, Version: models.LegalDocumentVersion, AcceptedAt: time.Now(), AcknowledgementType: ack}).Error)
	}
	for _, section := range []models.WaterSection{{Slug: "campus_life", Title: "校园生活", Status: "active"}, {Slug: "complaint", Title: "投诉", Status: "active"}, {Slug: "sensitive", Title: "敏感", Status: "active", SensitiveLevel: "high"}} {
		require.NoError(t, db.Create(&section).Error)
	}
	h := NewIntegrationHandler(db, IntegrationOptions{PublicOrigin: "https://fixture.invalid", AutoReplyEnabled: true})
	router := gin.New()
	h.Register(router, secret)
	login, _ := gin.CreateTestContext(httptest.NewRecorder())
	login.Request = httptest.NewRequest("POST", "/api/login", nil)
	_, family, err := issueRefreshSessionForDB(db, owner, login)
	require.NoError(t, err)
	jwt, err := middleware.GenerateToken(owner, string(models.RoleUser), 0, secret, family)
	require.NoError(t, err)
	send := func(method, path, token string, body interface{}) *httptest.ResponseRecorder {
		raw, _ := json.Marshal(body)
		req := httptest.NewRequest(method, path, strings.NewReader(string(raw)))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+token)
		out := httptest.NewRecorder()
		router.ServeHTTP(out, req)
		return out
	}
	w := send("GET", "/api/connected-apps/bot", jwt, nil)
	require.Equal(t, 200, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), `"policy_supported":true`)
	require.Contains(t, w.Body.String(), `"name":"校园生活"`)
	require.NotContains(t, w.Body.String(), "投诉")
	require.NotContains(t, w.Body.String(), "敏感")
	policy := services.DefaultManagedBotPolicy()
	policy.AllowedPostTypes = []string{"campus_life"}
	w = send("POST", "/api/connected-apps/bot", jwt, map[string]interface{}{"name": "新建鱼", "enabled": false, "avatar": "", "policy": policy})
	require.Equal(t, 200, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), `"name":"新建鱼"`)
	require.Contains(t, w.Body.String(), `"enabled":false`)
	require.Contains(t, w.Body.String(), `"nickname":"公开创建者"`)
	var bot models.ManagedBot
	require.NoError(t, db.First(&bot, "owner_id = ?", owner).Error)
	botPost := models.Post{BoardID: models.BoardShuitie, AuthorID: bot.UserID, PostType: "campus_life", Status: models.PostStatusNormal, ContentKind: models.PostContentKindNormal, Content: "AI公开归属验收"}
	require.NoError(t, db.Create(&botPost).Error)
	w = send("GET", fmt.Sprintf("/api/integrations/v1/public/community/posts/%d", botPost.ID), "", nil)
	require.Equal(t, 200, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), `"ai_bot":{"owner_id":92234,"owner_nickname":"公开创建者"}`)
	require.NotContains(t, w.Body.String(), "synthetic-bot-owner")
	require.NotContains(t, w.Body.String(), "password")
	require.NoError(t, db.Model(&bot).Update("enabled", true).Error)
	binding := models.IntegrationBinding{ID: uuid.NewString(), OwnerID: owner, InstallationID: uuid.NewString(), InstallationName: "合成安装", State: "active", Scopes: "community:read profile:read_minimal", Epoch: 1, AcademicBindingID: academic.ID, AcademicVersion: 1, TokenVersion: 0}
	require.NoError(t, db.Create(&binding).Error)
	token := "sa_synthetic_bot_policy"
	require.NoError(t, db.Create(&models.IntegrationCredential{ID: uuid.NewString(), BindingID: binding.ID, TokenHash: services.IntegrationSecretHash(token), Kind: "access", Epoch: 1, ExpiresAt: time.Now().Add(time.Hour)}).Error)
	w = send("GET", "/api/integrations/v1/bot/policy", token, nil)
	require.Equal(t, 200, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), `"public_read_enabled":true`)
	require.NotContains(t, w.Body.String(), "公开创建者")
	require.NotContains(t, w.Body.String(), "student")
	var ids []uint
	for _, slug := range []string{"campus_life", "complaint"} {
		p := models.Post{BoardID: models.BoardShuitie, AuthorID: owner, PostType: slug, Status: models.PostStatusNormal, ContentKind: models.PostContentKindNormal, Content: slug}
		require.NoError(t, db.Create(&p).Error)
		ids = append(ids, p.ID)
	}
	w = send("GET", "/api/integrations/v1/community/posts", token, nil)
	require.Equal(t, 200, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), "campus_life")
	require.NotContains(t, w.Body.String(), "complaint")
	w = send("GET", fmt.Sprintf("/api/integrations/v1/community/posts/%d", ids[1]), token, nil)
	require.Equal(t, 404, w.Code, w.Body.String())
	// Change permissions after the reader's SQL has completed but before HTTP writes the result.
	changeDuringRead := ""
	callback := "managed_bot_policy_change_" + uuid.NewString()
	require.NoError(t, db.Callback().Query().After("gorm:query").Register(callback, func(tx *gorm.DB) {
		if tx.Statement.Table != "posts" || changeDuringRead == "" {
			return
		}
		change := changeDuringRead
		changeDuringRead = ""
		switch change {
		case "pause":
			tx.AddError(db.Model(&models.ManagedBot{}).Where("owner_id = ?", owner).Update("enabled", false).Error)
		case "policy":
			changed := policy
			changed.AllowedPostTypes = []string{}
			raw, _ := json.Marshal(changed)
			tx.AddError(db.Model(&models.ManagedBot{}).Where("owner_id = ?", owner).Update("policy_json", string(raw)).Error)
		case "section":
			tx.AddError(db.Model(&models.WaterSection{}).Where("slug = ?", "campus_life").Update("status", "inactive").Error)
		}
	}))
	for _, change := range []string{"pause", "policy", "section"} {
		changeDuringRead = change
		w = send("GET", "/api/integrations/v1/community/posts", token, nil)
		require.Equal(t, 403, w.Code, change+": "+w.Body.String())
		require.Contains(t, w.Body.String(), "bot_permissions_changed")
		require.NotContains(t, w.Body.String(), "campus_life")
		raw, _ := json.Marshal(policy)
		require.NoError(t, db.Model(&models.ManagedBot{}).Where("owner_id = ?", owner).Updates(map[string]interface{}{"enabled": true, "policy_json": string(raw)}).Error)
		require.NoError(t, db.Model(&models.WaterSection{}).Where("slug = ?", "campus_life").Update("status", "active").Error)
	}
	require.NoError(t, db.Callback().Query().Remove(callback))
	// Stale authentication blocks edits but must not block the emergency pause.
	require.NoError(t, db.Model(&models.RefreshToken{}).Where("user_id = ?", owner).Update("authenticated_at", time.Now().Add(-time.Hour)).Error)
	w = send("POST", "/api/connected-apps/bot", jwt, map[string]interface{}{"name": "改名鱼", "enabled": false, "policy": policy})
	require.Equal(t, 403, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), "recent_authentication_required")
	w = send("POST", "/api/connected-apps/bot", jwt, map[string]interface{}{"enabled": false})
	require.Equal(t, 200, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), `"enabled":false`)
	w = send("GET", "/api/integrations/v1/community/posts", token, nil)
	require.Equal(t, 403, w.Code, w.Body.String())
	require.Contains(t, w.Body.String(), "bot_permission_denied")
	// An ordinary anonymous public visitor is not a bot principal and remains unaffected.
	w = send("GET", fmt.Sprintf("/api/integrations/v1/public/community/posts/%d", ids[1]), "", nil)
	require.Equal(t, 200, w.Code, w.Body.String())
}

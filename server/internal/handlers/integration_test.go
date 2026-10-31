package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"golang.org/x/oauth2"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"net/http"
	"net/http/httptest"
	"net/url"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"strings"
	"testing"
	"time"
)

func TestIntegrationHTTPAuthorizationReadDraftPublishRevoke(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	require.NoError(t, err)
	sqlDB, _ := db.DB()
	sqlDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = sqlDB.Close(); middleware.InvalidateTokenVersionCache(91234) })
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}, &models.AcademicIdentityBinding{}, &models.RefreshToken{}, &models.IntegrationBinding{}, &models.IntegrationCredential{}, &models.IntegrationDeviceRequest{}, &models.IntegrationAction{}, &models.IntegrationAudit{}, &models.IntegrationRateBucket{}, &models.Post{}, &models.Reply{}, &models.WaterSection{}, &models.WaterSectionMute{}))
	const owner = 91234
	const recipient = 91235
	const secret = "integration-http-test-secret"
	require.NoError(t, db.Create(&models.User{ID: owner, Nickname: "合成账号", Role: models.RoleUser, AccountStatus: "active"}).Error)
	require.NoError(t, db.Create(&models.User{ID: recipient, Nickname: "合成收件人", Role: models.RoleUser, AccountStatus: "active"}).Error)
	require.NoError(t, db.AutoMigrate(&models.Notification{}))
	require.NoError(t, db.Create(&models.AcademicIdentityBinding{UserID: owner, ProviderID: models.AcademicProviderUndergraduate, StudentID: "synthetic-http", VerifiedAt: time.Now(), VerificationMethod: "school_profile", VerificationVersion: "v1"}).Error)
	for _, doc := range []string{models.LegalDocumentUserAgreement, models.LegalDocumentPrivacyPolicy, models.LegalDocumentCommunityRules} {
		ack := ""
		if doc == models.LegalDocumentCommunityRules {
			ack = "rules_acceptance"
		}
		require.NoError(t, db.Create(&models.UserLegalConsent{UserID: owner, Document: doc, Version: models.LegalDocumentVersion, AcceptedAt: time.Now(), AcknowledgementType: ack}).Error)
	}
	middleware.InvalidateTokenVersionCache(owner)
	r := gin.New()
	// 使用生产全局中间件，防止标准 OAuth 错误被改写或网页/插件被 APK 版本策略拦截。
	r.Use(middleware.RequestTraceMiddleware(), middleware.AppVersionMiddleware(db, true, false))
	deliveries := 0
	h := NewIntegrationHandler(db, IntegrationOptions{PublicOrigin: "https://fixture.invalid", ProposalsEnabled: true, OwnerPublishEnabled: true, AfterReplyCommit: func(n models.Notification) {
		deliveries++
		require.EqualValues(t, recipient, n.UserID)
	}})
	h.Register(r, secret)
	r.GET("/ordinary-app", middleware.AuthMiddleware(db, secret), func(c *gin.Context) { c.Status(200) })
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest("POST", "/api/login", nil)
	_, family, err := issueRefreshSessionForDB(db, owner, c)
	require.NoError(t, err)
	jwt, err := middleware.GenerateToken(owner, string(models.RoleUser), 0, secret, family)
	require.NoError(t, err)
	send := func(method, path, token, contentType, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		if contentType != "" {
			req.Header.Set("Content-Type", contentType)
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		return w
	}
	postJSON := func(path, token string, body interface{}) *httptest.ResponseRecorder {
		raw, _ := json.Marshal(body)
		return send("POST", path, token, "application/json", string(raw))
	}
	form := url.Values{"client_id": {services.IntegrationClientID}, "installation_id": {uuid.NewString()}, "installation_name": {"合成安装"}, "scope": {"profile:read_minimal community:read actions:read_own community:propose"}}
	w := send("POST", "/api/oauth/device_authorization", "", "application/x-www-form-urlencoded", form.Encode())
	require.Equal(t, 200, w.Code, w.Body.String())
	var device map[string]interface{}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &device))
	require.Contains(t, device["verification_uri"], "https://fixture.invalid/web/connected-apps")
	w = postJSON("/api/connected-apps/device-requests/lookup", jwt, map[string]string{"user_code": device["user_code"].(string)})
	require.Equal(t, 200, w.Code, w.Body.String())
	var consent services.IntegrationConsent
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &consent))
	w = postJSON("/api/connected-apps/device-requests/"+consent.ID+"/decision", jwt, services.IntegrationConsentDecision{Allow: true, Scopes: consent.RequestedScopes, Nonce: consent.Nonce})
	require.Equal(t, 200, w.Code, w.Body.String())
	require.NoError(t, db.Model(&models.IntegrationDeviceRequest{}).Where("id = ?", consent.ID).Update("next_poll_at", time.Now().Add(-time.Second)).Error)
	w = send("POST", "/api/oauth/token", "", "application/x-www-form-urlencoded", url.Values{"client_id": {services.IntegrationClientID}, "grant_type": {services.IntegrationDeviceGrant}, "device_code": {device["device_code"].(string)}}.Encode())
	require.Equal(t, 200, w.Code, w.Body.String())
	var tokens services.IntegrationTokenResponse
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &tokens))
	require.Equal(t, 401, send("GET", "/ordinary-app", tokens.AccessToken, "", "").Code)
	require.Equal(t, 401, send("GET", "/api/integrations/v1/binding", jwt, "", "").Code)
	require.Equal(t, 401, send("GET", "/api/integrations/v1/binding", tokens.RefreshToken, "", "").Code)
	// 外部编号必须在转换为 uint 前受当前平台位宽约束，不能截断后命中其他对象。
	for _, path := range []string{
		"/api/integrations/v1/community/posts/18446744073709551616",
		"/api/integrations/v1/community/replies/18446744073709551616/context",
		"/api/integrations/v1/community/posts?after_id=18446744073709551616",
		"/api/integrations/v1/community/posts/-1",
	} {
		require.Equal(t, 422, send("GET", path, tokens.AccessToken, "", "").Code, path)
	}
	require.NoError(t, db.Create(&models.WaterSection{Slug: "campus_life", Title: "校园生活", Status: "active"}).Error)
	source := models.Post{BoardID: models.BoardShuitie, AuthorID: recipient, PostType: "campus_life", Status: models.PostStatusNormal, ContentKind: models.PostContentKindNormal, Content: "合成帖子", Contact: "must-not-leak", CreatedAt: time.Now().Add(-time.Hour)}
	require.NoError(t, db.Create(&source).Error)
	w = send("GET", fmt.Sprintf("/api/integrations/v1/community/posts/%d", source.ID), tokens.AccessToken, "", "")
	require.Equal(t, 200, w.Code, w.Body.String())
	require.NotContains(t, w.Body.String(), source.Contact)
	var read struct {
		Data struct {
			SourceVersion string `json:"source_version"`
		} `json:"data"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &read))
	proposal := services.IntegrationProposal{OperationID: uuid.NewString(), Kind: "reply", PostID: source.ID, SourceVersion: read.Data.SourceVersion, Content: "真实 HTTP 合成评论", StickerID: ListBuiltinStickers()[0].ID}
	w = postJSON("/api/integrations/v1/actions", tokens.AccessToken, proposal)
	require.Equal(t, 200, w.Code, w.Body.String())
	var created struct {
		ID string `json:"action_id"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &created))
	actionPath := "/api/connected-apps/actions/" + created.ID
	require.Equal(t, 401, send("GET", actionPath, tokens.AccessToken, "", "").Code)
	w = send("GET", actionPath, jwt, "", "")
	require.Equal(t, 200, w.Code, w.Body.String())
	var preview services.IntegrationActionPreview
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &preview))
	decision := services.IntegrationActionDecision{Allow: true, Nonce: preview.Nonce, Version: preview.Action.Version, PayloadHash: preview.Action.PayloadHash}
	// 真实事务已经提交，但确认响应在网络上超时；重试不得再次创建评论或通知。
	committed, releaseResponse := make(chan int, 1), make(chan struct{})
	lossy := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, request *http.Request) {
		recorder := httptest.NewRecorder()
		r.ServeHTTP(recorder, request)
		committed <- recorder.Code
		<-releaseResponse
	}))
	defer lossy.Close()
	encodedDecision, err := json.Marshal(decision)
	require.NoError(t, err)
	request, err := http.NewRequest("POST", lossy.URL+actionPath+"/decision", strings.NewReader(string(encodedDecision)))
	require.NoError(t, err)
	request.Header.Set("Authorization", "Bearer "+jwt)
	request.Header.Set("Content-Type", "application/json")
	lost, networkErr := (&http.Client{Timeout: time.Second}).Do(request)
	close(releaseResponse)
	if lost != nil {
		_ = lost.Body.Close()
	}
	require.True(t, errors.Is(networkErr, context.DeadlineExceeded), "确认响应应在事务提交后超时: %v", networkErr)
	select {
	case status := <-committed:
		require.Equal(t, 200, status, "丢失响应前必须已成功发布，不能把回滚当成超时后幂等")
	case <-time.After(time.Second):
		t.Fatal("确认请求未进入真实处理器")
	}
	var committedCount int64
	require.NoError(t, db.Model(&models.Reply{}).Count(&committedCount).Error)
	require.EqualValues(t, 1, committedCount, "重试之前必须已有一条提交成功的评论")
	require.Equal(t, 1, deliveries)
	for i := 0; i < 2; i++ {
		w = postJSON(actionPath+"/decision", jwt, decision)
		require.Equal(t, 200, w.Code, w.Body.String())
	}
	var count int64
	require.NoError(t, db.Model(&models.Reply{}).Count(&count).Error)
	require.EqualValues(t, 1, count)
	require.NoError(t, db.First(&source, source.ID).Error)
	require.Zero(t, source.ViewCount)
	require.Equal(t, 1, source.ReplyCount)
	var notification models.Notification
	require.NoError(t, db.First(&notification).Error)
	require.EqualValues(t, recipient, notification.UserID)
	require.EqualValues(t, owner, notification.FromUID)
	require.NoError(t, db.Model(&models.Notification{}).Count(&count).Error)
	require.EqualValues(t, 1, count)
	require.Equal(t, 1, deliveries)

	w = send("POST", "/api/oauth/revoke", "", "application/x-www-form-urlencoded", url.Values{"client_id": {services.IntegrationClientID}, "token": {tokens.RefreshToken}}.Encode())
	require.Equal(t, 200, w.Code)
	require.Equal(t, 401, send("GET", "/api/integrations/v1/binding", tokens.AccessToken, "", "").Code)
	require.Equal(t, 200, send("GET", "/ordinary-app", jwt, "", "").Code)
	// 使用官方 OAuth 客户端验证 RFC 8628 格式，不仅手工拼请求。
	server := httptest.NewServer(r)
	defer server.Close()
	client := oauth2.Config{ClientID: services.IntegrationClientID, Scopes: []string{"profile:read_minimal", "community:read"}, Endpoint: oauth2.Endpoint{DeviceAuthURL: server.URL + "/api/oauth/device_authorization", TokenURL: server.URL + "/api/oauth/token", AuthStyle: oauth2.AuthStyleInParams}}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	standardDevice, err := client.DeviceAuth(ctx, oauth2.SetAuthURLParam("installation_id", uuid.NewString()), oauth2.SetAuthURLParam("installation_name", "标准客户端互操作"))
	require.NoError(t, err)
	w = postJSON("/api/connected-apps/device-requests/lookup", jwt, map[string]string{"user_code": standardDevice.UserCode})
	require.Equal(t, 200, w.Code, w.Body.String())
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &consent))
	w = postJSON("/api/connected-apps/device-requests/"+consent.ID+"/decision", jwt, services.IntegrationConsentDecision{Allow: true, Scopes: consent.RequestedScopes, Nonce: consent.Nonce})
	require.Equal(t, 200, w.Code, w.Body.String())
	standardToken, err := client.DeviceAccessToken(ctx, standardDevice)
	require.NoError(t, err)
	require.True(t, standardToken.Valid())
	require.True(t, strings.HasPrefix(standardToken.AccessToken, "sa_"))
	// 登录时间不随 JWT/刷新延长；旧登录不能批准新的连接。
	require.NoError(t, db.Model(&models.RefreshToken{}).Where("user_id = ?", owner).Update("authenticated_at", time.Now().Add(-11*time.Minute)).Error)
	w = postJSON("/api/connected-apps/device-requests/lookup", jwt, map[string]string{"user_code": device["user_code"].(string)})
	require.Equal(t, 403, w.Code)
	require.Contains(t, w.Body.String(), "recent_authentication_required")
}

package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"image"
	"image/png"
	"mime/multipart"
	"net/http/httptest"
	"shenliyuan/internal/community"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"testing"
	"time"
)

func TestIntegrationBotMediaActualMultipartAndPostLinkedImage(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{Logger: logger.Discard})
	require.NoError(t, err)
	pool, _ := db.DB()
	pool.SetMaxOpenConns(1)
	t.Cleanup(func() { pool.Close() })
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}, &models.AcademicIdentityBinding{}, &models.IntegrationBinding{}, &models.IntegrationCredential{}, &models.IntegrationDeviceRequest{}, &models.IntegrationAction{}, &models.IntegrationAudit{}, &models.IntegrationRateBucket{}, &models.ManagedBot{}, &models.Post{}, &models.Reply{}, &models.WaterSection{}, &models.WaterSectionMute{}, &models.File{}, &models.FileUploadGrant{}, &models.PostImage{}, &models.ImageVariant{}))
	const owner = 72001
	require.NoError(t, db.Create(&models.User{ID: owner, Nickname: "合成创建者", Role: models.RoleUser, AccountStatus: "active"}).Error)
	require.NoError(t, db.Create(&models.AcademicIdentityBinding{UserID: owner, ProviderID: models.AcademicProviderUndergraduate, StudentID: "synthetic-media-owner", VerificationMethod: "school_profile", VerificationVersion: "v1", VerifiedAt: time.Now()}).Error)
	for _, doc := range []string{models.LegalDocumentUserAgreement, models.LegalDocumentPrivacyPolicy, models.LegalDocumentCommunityRules} {
		ack := ""
		if doc == models.LegalDocumentCommunityRules {
			ack = "rules_acceptance"
		}
		require.NoError(t, db.Create(&models.UserLegalConsent{UserID: owner, Document: doc, Version: models.LegalDocumentVersion, AcceptedAt: time.Now(), AcknowledgementType: ack}).Error)
	}
	require.NoError(t, db.Create(&models.WaterSection{Slug: "campus_life", Title: "校园生活", Status: "active"}).Error)
	source := models.Post{AuthorID: owner, BoardID: models.BoardShuitie, PostType: "campus_life", ContentKind: models.PostContentKindNormal, Status: models.PostStatusNormal, Content: "合成来源"}
	require.NoError(t, db.Create(&source).Error)
	root := t.TempDir()
	t.Setenv("UPLOAD_DIR", root)
	h := NewIntegrationHandler(db, IntegrationOptions{AutoPostEnabled: true, ProposalsEnabled: true})
	h.SetBotUploader(NewUploadHandler(root, 4<<20, db))
	r := gin.New()
	h.Register(r, "test-only-media-secret")
	d, err := h.auth.RequestDevice(context.Background(), uuid.NewString(), "合成媒体助手", services.IntegrationReadScope+" "+services.IntegrationActionScope+" "+services.IntegrationProposeScope+" "+services.IntegrationAutoPostScope)
	require.NoError(t, err)
	c, err := h.auth.LookupConsent(context.Background(), owner, d.UserCode)
	require.NoError(t, err)
	b, err := h.auth.DecideConsent(context.Background(), owner, c.ID, services.IntegrationConsentDecision{Allow: true, Scopes: c.RequestedScopes, Nonce: c.Nonce})
	require.NoError(t, err)
	h.auth.Now = func() time.Time { return time.Now().Add(6 * time.Second) }
	tokens, err := h.auth.ExchangeDevice(context.Background(), d.DeviceCode)
	require.NoError(t, err)
	bot, err := h.actions().ManageBot(context.Background(), owner, "合成校园助手", true)
	require.NoError(t, err)
	policy := services.DefaultManagedBotPolicy()
	policy.PostEnabled = true
	policy.ImageEnabled = true
	raw, err := json.Marshal(policy)
	require.NoError(t, err)
	require.NoError(t, db.Model(&bot).Update("policy_json", string(raw)).Error)
	capRequest := httptest.NewRequest("GET", "/api/integrations/v1/bot/capabilities", nil)
	capRequest.Header.Set("Authorization", "Bearer "+tokens.AccessToken)
	capResponse := httptest.NewRecorder()
	r.ServeHTTP(capResponse, capRequest)
	require.Equal(t, 200, capResponse.Code)
	require.JSONEq(t, `{"auto_post":true,"media_upload":true}`, capResponse.Body.String())
	upload := func(extra bool) *httptest.ResponseRecorder {
		var body bytes.Buffer
		writer := multipart.NewWriter(&body)
		part, e := writer.CreateFormFile("file", "approved.png")
		require.NoError(t, e)
		require.NoError(t, png.Encode(part, image.NewRGBA(image.Rect(0, 0, 2, 2))))
		if extra {
			require.NoError(t, writer.WriteField("user_id", "999"))
		}
		require.NoError(t, writer.Close())
		req := httptest.NewRequest("POST", "/api/integrations/v1/bot/media", &body)
		req.Header.Set("Content-Type", writer.FormDataContentType())
		req.Header.Set("Authorization", "Bearer "+tokens.AccessToken)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		return w
	}
	w := upload(true)
	require.Equal(t, 422, w.Code, w.Body.String())
	w = upload(false)
	require.Equal(t, 200, w.Code, w.Body.String())
	var uploaded struct {
		ID uint `json:"file_id"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &uploaded))
	require.Positive(t, uploaded.ID)
	var file models.File
	require.NoError(t, db.First(&file, uploaded.ID).Error)
	require.Equal(t, bot.UserID, file.UploaderID)
	require.Equal(t, models.FileAccessPrivate, file.AccessScope)
	p := services.IntegrationProposal{OperationID: uuid.NewString(), Kind: "post", Content: "根据合成公开来源生成的帖子", PostType: "campus_life", ImageFileIDs: []uint{file.ID}, Sources: []services.IntegrationPostSource{{PostID: source.ID, Version: community.PostDTO(source, 10000).SourceVersion}}}
	raw, e := json.Marshal(p)
	require.NoError(t, e)
	req := httptest.NewRequest("POST", "/api/integrations/v1/bot/posts", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+tokens.AccessToken)
	w = httptest.NewRecorder()
	r.ServeHTTP(w, req)
	require.Equal(t, 200, w.Code, w.Body.String())
	var published struct {
		ID    uint   `json:"post_id"`
		State string `json:"state"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &published))
	require.Equal(t, "published", published.State)
	var link models.PostImage
	require.NoError(t, db.First(&link, "post_id = ?", published.ID).Error)
	require.Equal(t, file.ID, link.FileID)
	require.NoError(t, db.First(&file, file.ID).Error)
	require.Equal(t, models.FileAccessPublic, file.AccessScope)
	h.options.AutoPostEnabled = false
	require.Equal(t, 403, upload(false).Code)
	require.NoError(t, h.auth.Revoke(context.Background(), b.OwnerID, b.ID))
	h.options.AutoPostEnabled = true
	require.Equal(t, 401, upload(false).Code)
}

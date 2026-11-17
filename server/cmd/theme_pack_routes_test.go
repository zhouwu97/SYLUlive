package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"

	"shenliyuan/internal/handlers"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

type themeRouteFixture struct {
	db     *gorm.DB
	router *gin.Engine
	dir    string
	tokens map[uint]string
	zipV1  []byte
}

func makeRouteTestZip(t *testing.T, themeName string) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, 1080, 2340))
	row := make([]byte, 1080*4)
	for x := 0; x < 1080; x++ {
		row[x*4+0] = 40
		row[x*4+1] = 110
		row[x*4+2] = 190
		row[x*4+3] = 255
	}
	for y := 0; y < 2340; y++ {
		copy(img.Pix[y*img.Stride:y*img.Stride+1080*4], row)
	}
	var pBuf bytes.Buffer
	enc := png.Encoder{CompressionLevel: png.BestSpeed}
	require.NoError(t, enc.Encode(&pBuf, img))
	previewPNG := pBuf.Bytes()

	lightTokens := map[string]string{
		"primary": "#147C72", "onPrimary": "#FFFFFF", "primaryContainer": "#EAF6F3", "onPrimaryContainer": "#0F635B",
		"background": "#FFFAF4", "surface": "#FFFFFF", "surfaceElevated": "#FFFFFF", "surfaceMuted": "#F2F3F1",
		"card": "#FFFFFF", "cardBorder": "#E2EFEA", "textPrimary": "#1F2328", "textSecondary": "#6E757C",
		"textTertiary": "#9AA1A1", "textDisabled": "#B8BDBA", "divider": "#E8EEE9", "outline": "#E2EFEA",
		"inputFill": "#F2F3F1", "inputFillFocused": "#EFF4F1", "searchFill": "#F1F2F0", "tagBackground": "#EEF2F0",
		"tagText": "#0F635B", "navBackground": "#9EEDF0F5", "navSelected": "#1765DA", "navUnselected": "#4B525E",
		"appBarBackground": "#F4FBF8", "appBarForeground": "#161D1C", "bubbleIncoming": "#F0F1EF", "bubbleIncomingText": "#1F2328",
		"bubbleOutgoing": "#76C4FF", "bubbleOutgoingText": "#1F2328", "feedSectionSurface": "#E8F5F1",
		"feedFeaturedSurface": "#FFF3E0", "feedFeaturedText": "#D97706", "courseCardText": "#1F2328",
		"timetableGrid": "#0D000000", "timetableToday": "#00000000",
	}
	darkTokens := map[string]string{
		"primary": "#7ED6C5", "onPrimary": "#0F2622", "primaryContainer": "#162B28", "onPrimaryContainer": "#7ED6C5",
		"background": "#111315", "surface": "#1A1D1F", "surfaceElevated": "#232729", "surfaceMuted": "#24282A",
		"card": "#1A1D1F", "cardBorder": "#303638", "textPrimary": "#F2F4F3", "textSecondary": "#A7AFAB",
		"textTertiary": "#8E9894", "textDisabled": "#5A615D", "divider": "#252A2C", "outline": "#303638",
		"inputFill": "#24282A", "inputFillFocused": "#2B3033", "searchFill": "#24282A", "tagBackground": "#282D30",
		"tagText": "#90D5C7", "navBackground": "#B8252A32", "navSelected": "#84BAFF", "navUnselected": "#D1D5DB",
		"appBarBackground": "#0E1513", "appBarForeground": "#DDE4E1", "bubbleIncoming": "#262A2C", "bubbleIncomingText": "#F2F4F3",
		"bubbleOutgoing": "#80C4FC", "bubbleOutgoingText": "#111315", "feedSectionSurface": "#162B28",
		"feedFeaturedSurface": "#3A2A18", "feedFeaturedText": "#F2B15A", "courseCardText": "#FFFFFF",
		"timetableGrid": "#33FFFFFF", "timetableToday": "#00000000",
	}
	manifest := map[string]any{
		"formatVersion": 1,
		"minAppVersion": "1.0.0",
		"id":            uuid.NewString(),
		"version":       1,
		"name":          themeName,
		"description":   "路由联调测试主题",
		"author":        "作者",
		"tags":          []string{"清新", "简约"},
		"license":       "CC-BY-4.0",
		"preview":       map[string]string{"light": "preview/light.png", "dark": "preview/dark.png"},
		"light": map[string]any{
			"seedColor":     "#147C72",
			"schemeVariant": "tonalSpot",
			"tokens":        lightTokens,
			"coursePalette": []string{"#5B9BFF", "#38D178", "#C46CE0", "#FF7A7A", "#FFB042"},
		},
		"dark": map[string]any{
			"seedColor":     "#7ED6C5",
			"schemeVariant": "tonalSpot",
			"tokens":        darkTokens,
			"coursePalette": []string{"#2E62A6", "#1F7A4C", "#6E3A88", "#A43A3A", "#995C14"},
		},
	}

	var zBuf bytes.Buffer
	zw := zip.NewWriter(&zBuf)
	mRaw, err := json.Marshal(manifest)
	require.NoError(t, err)
	mw, err := zw.Create("manifest.json")
	require.NoError(t, err)
	_, err = mw.Write(mRaw)
	require.NoError(t, err)
	for _, p := range []string{"preview/light.png", "preview/dark.png"} {
		pw, err := zw.Create(p)
		require.NoError(t, err)
		_, err = pw.Write(previewPNG)
		require.NoError(t, err)
	}
	// 加一张未引用壁纸以扩大包体积，验证 Range 分片续传
	extraImg := image.NewNRGBA(image.Rect(0, 0, 64, 64))
	extraImg.SetNRGBA(0, 0, color.NRGBA{R: 12, G: 34, B: 56, A: 255})
	require.NoError(t, zw.Close())
	return zBuf.Bytes()
}

func newThemeRouteFixture(t *testing.T) *themeRouteFixture {
	t.Helper()
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = sqlDB.Close() })

	for i := 0; i < 2; i++ {
		require.NoError(t, db.AutoMigrate(
			&models.User{},
			&models.UserLegalConsent{},
			&models.AdminLog{},
			&models.AdminActionLog{},
			&models.Notification{},
			&models.Report{},
			&models.SystemConfig{},
			&models.ThemePack{},
		))
	}
	require.NoError(t, db.Exec(`CREATE UNIQUE INDEX IF NOT EXISTS uq_pending_report_target ON reports (reporter_id, target_type, target_id, target_key) WHERE status = 'pending'`).Error)

	middleware.InvalidateTokenVersionCache(0)
	middleware.SetLegalConsentEnforcement(middleware.LegalConsentEnforcementOff)
	t.Cleanup(func() {
		middleware.InvalidateTokenVersionCache(0)
		middleware.SetLegalConsentEnforcement(middleware.LegalConsentEnforcementSoft)
	})

	secret := "theme-routes-test-secret"
	f := &themeRouteFixture{
		db:     db,
		router: gin.New(),
		dir:    t.TempDir(),
		tokens: map[uint]string{},
		zipV1:  makeRouteTestZip(t, "海盐蓝测试"),
	}
	f.router.Use(middleware.RequestBodyLimitMiddleware(
		1<<20,
		middleware.BodyLimitRule{Prefix: "/api/themes/submissions", Limit: services.ThemePackMaxRequestBodyBytes},
	))
	f.router.Use(middleware.IdempotencyMiddlewareWithJWT(db, secret))

	for id, role := range map[uint]models.Role{1: models.RoleUser, 2: models.RoleUser, 3: models.RoleAdmin} {
		require.NoError(t, db.Create(&models.User{
			ID:            id,
			PasswordHash:  "fixture",
			Role:          role,
			AccountStatus: "active",
			Nickname:      fmt.Sprintf("用户-%d", id),
		}).Error)
		tok, err := middleware.GenerateToken(id, string(role), 0, secret)
		require.NoError(t, err)
		f.tokens[id] = tok
	}

	registerThemePackRoutes(f.router, db, f.dir, secret)
	reportHandler := handlers.NewReportHandler(db)
	reports := f.router.Group("/api/reports", middleware.AuthMiddleware(db, secret))
	reports.POST("", reportHandler.Create)
	reports.PUT("/:id/handle", middleware.AdminMiddleware(), reportHandler.Handle)

	return f
}

func (f *themeRouteFixture) req(method, path string, user uint, body io.Reader, headers map[string]string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, body)
	if user != 0 {
		r.Header.Set("Authorization", "Bearer "+f.tokens[user])
	}
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	f.router.ServeHTTP(w, r)
	return w
}

func (f *themeRouteFixture) submitPack(t *testing.T, user uint, idemKey, familyID string, zipBytes []byte) *httptest.ResponseRecorder {
	t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	require.NoError(t, mw.WriteField("idempotencyKey", idemKey))
	if familyID != "" {
		require.NoError(t, mw.WriteField("familyId", familyID))
	}
	part, err := mw.CreateFormFile("package", "theme.sltheme")
	require.NoError(t, err)
	_, err = part.Write(zipBytes)
	require.NoError(t, err)
	require.NoError(t, mw.Close())

	return f.req(http.MethodPost, "/api/themes/submissions", user, &body, map[string]string{
		"Content-Type": mw.FormDataContentType(),
	})
}

func TestThemePackRoutesPermissionsCatalogVersionedDownloadAndRemoval(t *testing.T) {
	f := newThemeRouteFixture(t)

	// 1. 未登录投稿返回 401
	unauth := f.submitPack(t, 0, "idem-unauth-0001", "", f.zipV1)
	require.Equal(t, http.StatusUnauthorized, unauth.Code)

	// 2. 用户 1 投稿 v1：待审版本不出现在公开目录或个人作品页，他人读取私有包返回 404
	subV1 := f.submitPack(t, 1, "idem-user1-v1-0001", "", f.zipV1)
	require.Equal(t, http.StatusOK, subV1.Code)
	var v1Body map[string]any
	require.NoError(t, json.Unmarshal(subV1.Body.Bytes(), &v1Body))
	subV1ID := v1Body["id"].(string)
	familyID := v1Body["familyId"].(string)

	otherPriv := f.req(http.MethodGet, fmt.Sprintf("/api/themes/submissions/%s/package", subV1ID), 2, nil, nil)
	require.Equal(t, http.StatusNotFound, otherPriv.Code)
	otherPrev := f.req(http.MethodGet, fmt.Sprintf("/api/themes/submissions/%s/preview/light", subV1ID), 2, nil, nil)
	require.Equal(t, http.StatusNotFound, otherPrev.Code)

	ownerPriv := f.req(http.MethodGet, fmt.Sprintf("/api/themes/submissions/%s/package", subV1ID), 1, nil, nil)
	require.Equal(t, http.StatusOK, ownerPriv.Code)
	require.Contains(t, ownerPriv.Header().Get("Cache-Control"), "private")
	adminPriv := f.req(http.MethodGet, fmt.Sprintf("/api/themes/submissions/%s/package", subV1ID), 3, nil, nil)
	require.Equal(t, http.StatusOK, adminPriv.Code)

	catPending := f.req(http.MethodGet, "/api/themes", 0, nil, nil)
	require.Equal(t, http.StatusOK, catPending.Code)
	var catPendingBody struct {
		Items []map[string]any `json:"items"`
	}
	require.NoError(t, json.Unmarshal(catPending.Body.Bytes(), &catPendingBody))
	require.Empty(t, catPendingBody.Items)

	// 3. 管理员 3 审核通过 v1：目录出现 v1，验证 ETag 304 与 SHA-256 完整性
	revV1 := f.req(http.MethodPost, fmt.Sprintf("/api/admin/themes/%s/review", subV1ID), 3,
		bytes.NewBufferString(`{"approve":true}`),
		map[string]string{"Content-Type": "application/json"},
	)
	require.Equal(t, http.StatusOK, revV1.Code)

	catV1 := f.req(http.MethodGet, "/api/themes", 0, nil, nil)
	require.Equal(t, http.StatusOK, catV1.Code)
	catETag := catV1.Header().Get("ETag")
	require.NotEmpty(t, catETag)

	cat304 := f.req(http.MethodGet, "/api/themes", 0, nil, map[string]string{"If-None-Match": catETag})
	require.Equal(t, http.StatusNotModified, cat304.Code)

	var catV1Body struct {
		Items []map[string]any `json:"items"`
	}
	require.NoError(t, json.Unmarshal(catV1.Body.Bytes(), &catV1Body))
	require.Len(t, catV1Body.Items, 1)
	v1Entry := catV1Body.Items[0]
	v1PackageURL := v1Entry["packageUrl"].(string)
	v1SHA256 := v1Entry["packageSha256"].(string)

	dlV1Full := f.req(http.MethodGet, v1PackageURL, 0, nil, nil)
	require.Equal(t, http.StatusOK, dlV1Full.Code)
	sumV1 := sha256.Sum256(dlV1Full.Body.Bytes())
	require.Equal(t, v1SHA256, hex.EncodeToString(sumV1[:]))

	pkgETag := dlV1Full.Header().Get("ETag")
	dl304 := f.req(http.MethodGet, v1PackageURL, 0, nil, map[string]string{"If-None-Match": pkgETag})
	require.Equal(t, http.StatusNotModified, dl304.Code)

	// 4. 用户 1 发布 v2 并由管理员审核通过：此时通过旧的 v1 packageUrl 仍能下载 v1，且 Range 分片续传与完整包逐字节一致
	zipV2 := makeRouteTestZip(t, "海盐蓝二版")
	subV2 := f.submitPack(t, 1, "idem-user1-v2-0002", familyID, zipV2)
	require.Equal(t, http.StatusOK, subV2.Code)
	var v2SubBody map[string]any
	require.NoError(t, json.Unmarshal(subV2.Body.Bytes(), &v2SubBody))
	subV2ID := v2SubBody["id"].(string)

	// 管理员队列带出同家族已上架 v1 摘要
	adminQueue := f.req(http.MethodGet, "/api/admin/themes?status=pending", 3, nil, nil)
	require.Equal(t, http.StatusOK, adminQueue.Code)
	var queueBody struct {
		Items []map[string]any `json:"items"`
	}
	require.NoError(t, json.Unmarshal(adminQueue.Body.Bytes(), &queueBody))
	require.Len(t, queueBody.Items, 1)
	require.NotNil(t, queueBody.Items[0]["currentApproved"])

	revV2 := f.req(http.MethodPost, fmt.Sprintf("/api/admin/themes/%s/review", subV2ID), 3,
		bytes.NewBufferString(`{"approve":true}`),
		map[string]string{"Content-Type": "application/json"},
	)
	require.Equal(t, http.StatusOK, revV2.Code)

	fullBytes := dlV1Full.Body.Bytes()
	splitAt := len(fullBytes) / 2
	part1 := f.req(http.MethodGet, v1PackageURL, 0, nil, map[string]string{
		"Range": fmt.Sprintf("bytes=0-%d", splitAt-1),
	})
	require.Equal(t, http.StatusPartialContent, part1.Code)
	part2 := f.req(http.MethodGet, v1PackageURL, 0, nil, map[string]string{
		"Range": fmt.Sprintf("bytes=%d-%d", splitAt, len(fullBytes)-1),
	})
	require.Equal(t, http.StatusPartialContent, part2.Code)
	combined := append(append([]byte(nil), part1.Body.Bytes()...), part2.Body.Bytes()...)
	require.Equal(t, fullBytes, combined)

	// 5. ids 批量查询返回当前最新已上架版本 v2，并检查累计下载计数（完整下载 1 次 + Range bytes=0- 1 次 = 2，续传第 2 片不重复计数）
	batchResp := f.req(http.MethodGet, "/api/themes?ids="+familyID, 0, nil, nil)
	require.Equal(t, http.StatusOK, batchResp.Code)
	var batchBody struct {
		Items []map[string]any `json:"items"`
	}
	require.NoError(t, json.Unmarshal(batchResp.Body.Bytes(), &batchBody))
	require.Len(t, batchBody.Items, 1)
	require.Equal(t, float64(2), batchBody.Items[0]["version"])
	require.Equal(t, float64(2), batchBody.Items[0]["downloads"])
	v2PackageURL := batchBody.Items[0]["packageUrl"].(string)

	// 6. 举报接口支持 target_type=theme（familyId）
	repResp := f.req(http.MethodPost, "/api/reports", 2,
		bytes.NewBufferString(fmt.Sprintf(`{"target_type":"theme","target_id":"%s","reason":"壁纸角落疑似带水印"}`, familyID)),
		map[string]string{"Content-Type": "application/json"},
	)
	require.Equal(t, http.StatusCreated, repResp.Code)

	// 7. 管理员下架后：目录、详情、v1/v2 包与预览图全部返回 404
	rmResp := f.req(http.MethodPost, fmt.Sprintf("/api/admin/themes/%s/remove", familyID), 3,
		bytes.NewBufferString(`{"reasonCode":"wallpaper_text","note":"核实含水印"}`),
		map[string]string{"Content-Type": "application/json"},
	)
	require.Equal(t, http.StatusOK, rmResp.Code)

	catAfterRm := f.req(http.MethodGet, "/api/themes", 0, nil, nil)
	require.NoError(t, json.Unmarshal(catAfterRm.Body.Bytes(), &catPendingBody))
	require.Empty(t, catPendingBody.Items)
	require.Equal(t, http.StatusNotFound, f.req(http.MethodGet, "/api/themes/"+familyID, 0, nil, nil).Code)
	require.Equal(t, http.StatusNotFound, f.req(http.MethodGet, v1PackageURL, 0, nil, nil).Code)
	require.Equal(t, http.StatusNotFound, f.req(http.MethodGet, v2PackageURL, 0, nil, nil).Code)
	require.Equal(t, http.StatusNotFound, f.req(http.MethodGet, fmt.Sprintf("/api/themes/%s/versions/1/preview/light", familyID), 0, nil, nil).Code)
	require.Equal(t, http.StatusNotFound, f.req(http.MethodGet, fmt.Sprintf("/api/themes/%s/versions/2/preview/dark", familyID), 0, nil, nil).Code)

	// 8. 作者撤回已上架作品后，整个版本族不可下载
	subW1 := f.submitPack(t, 2, "idem-user2-w1-0001", "", f.zipV1)
	require.Equal(t, http.StatusOK, subW1.Code)
	var w1Body map[string]any
	require.NoError(t, json.Unmarshal(subW1.Body.Bytes(), &w1Body))
	w1ID := w1Body["id"].(string)
	wFam := w1Body["familyId"].(string)

	require.Equal(t, http.StatusOK, f.req(http.MethodPost, fmt.Sprintf("/api/admin/themes/%s/review", w1ID), 3,
		bytes.NewBufferString(`{"approve":true}`),
		map[string]string{"Content-Type": "application/json"},
	).Code)

	subW2 := f.submitPack(t, 2, "idem-user2-w2-0002", wFam, f.zipV1)
	require.Equal(t, http.StatusOK, subW2.Code)
	var w2Body map[string]any
	require.NoError(t, json.Unmarshal(subW2.Body.Bytes(), &w2Body))
	w2ID := w2Body["id"].(string)
	require.Equal(t, http.StatusOK, f.req(http.MethodPost, fmt.Sprintf("/api/admin/themes/%s/review", w2ID), 3,
		bytes.NewBufferString(`{"approve":true}`),
		map[string]string{"Content-Type": "application/json"},
	).Code)

	withdrawResp := f.req(http.MethodPost, fmt.Sprintf("/api/themes/submissions/%s/withdraw", w2ID), 2, nil, nil)
	require.Equal(t, http.StatusOK, withdrawResp.Code)
	require.Equal(t, http.StatusNotFound, f.req(http.MethodGet, fmt.Sprintf("/api/themes/%s/versions/1/package", wFam), 0, nil, nil).Code)
	require.Equal(t, http.StatusNotFound, f.req(http.MethodGet, fmt.Sprintf("/api/themes/%s/versions/2/package", wFam), 0, nil, nil).Code)
	require.Equal(t, http.StatusNotFound, f.req(http.MethodGet, "/api/themes/"+wFam, 0, nil, nil).Code)
}

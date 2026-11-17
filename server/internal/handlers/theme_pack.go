package handlers

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

type ThemePackHandler struct {
	service     *services.ThemePackService
	uploadSlots chan struct{}
}

func NewThemePackHandler(service *services.ThemePackService) *ThemePackHandler {
	return &ThemePackHandler{
		service:     service,
		uploadSlots: make(chan struct{}, 4),
	}
}

func (h *ThemePackHandler) isAdmin(c *gin.Context) bool {
	uid := c.GetUint("user_id")
	if uid == 0 {
		return false
	}
	var user models.User
	if err := h.service.DB.WithContext(c.Request.Context()).
		Select("id", "role", "account_status").
		First(&user, uid).Error; err != nil {
		return false
	}
	return (user.AccountStatus == "" || user.AccountStatus == "active") &&
		(user.Role == models.RoleAdmin || user.Role == models.RoleSuperAdmin)
}

func (h *ThemePackHandler) requireStoreEnabled(c *gin.Context) bool {
	if !h.service.IsStoreEnabled(c.Request.Context()) {
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"error": "主题商城暂未开放",
			"code":  "theme_store_disabled",
		})
		return false
	}
	return true
}

func writeThemeError(c *gin.Context, err error) {
	var te *services.ThemePackError
	if errors.As(err, &te) {
		payload := gin.H{
			"error": te.Message,
			"code":  te.Code,
		}
		if te.Field != "" {
			payload["field"] = te.Field
		}
		c.JSON(te.Status, payload)
		return
	}
	if errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusNotFound, gin.H{
			"error": "主题不存在或不可访问",
			"code":  services.ThemeCodeNotFound,
		})
		return
	}
	c.JSON(http.StatusInternalServerError, gin.H{
		"error": "主题服务操作失败，请稍后重试",
		"code":  services.ThemeCodeFailed,
	})
}

type themeCatalogCursor struct {
	Sort          string `json:"s"`
	Downloads     int64  `json:"d,omitempty"`
	CreatedAtNano int64  `json:"t"`
	ID            string `json:"i"`
}

func encodeThemeCursor(cur themeCatalogCursor) string {
	raw, _ := json.Marshal(cur)
	return base64.RawURLEncoding.EncodeToString(raw)
}

func decodeThemeCursor(s string) (themeCatalogCursor, bool) {
	var cur themeCatalogCursor
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(s))
	if err != nil {
		return cur, false
	}
	if err := json.Unmarshal(raw, &cur); err != nil || cur.ID == "" || cur.CreatedAtNano == 0 {
		return cur, false
	}
	return cur, true
}

type themeJoinedRow struct {
	models.ThemePack
	RootDownloads int64     `gorm:"column:root_downloads"`
	RootCreatedAt time.Time `gorm:"column:root_created_at"`
}

func (h *ThemePackHandler) loadAuthorsMap(c *gin.Context, ids []uint) map[uint]gin.H {
	out := make(map[uint]gin.H, len(ids))
	if len(ids) == 0 {
		return out
	}
	uniq := make([]uint, 0, len(ids))
	seen := make(map[uint]bool, len(ids))
	for _, id := range ids {
		if id != 0 && !seen[id] {
			seen[id] = true
			uniq = append(uniq, id)
		}
	}
	var users []models.User
	if len(uniq) > 0 {
		_ = h.service.DB.WithContext(c.Request.Context()).
			Select("id", "nickname", "avatar", "account_status").
			Where("id IN ?", uniq).
			Find(&users).Error
	}
	for _, u := range users {
		nickname := u.Nickname
		avatar := u.Avatar
		if u.AccountStatus == "cancelled" {
			nickname = "已注销用户"
			avatar = ""
		}
		out[u.ID] = gin.H{
			"id":        u.ID,
			"nickname":  nickname,
			"avatarUrl": avatar,
		}
	}
	return out
}

func formatPublicCatalogItem(row themeJoinedRow, author gin.H) gin.H {
	if author == nil {
		author = gin.H{"id": row.AuthorUserID, "nickname": "用户", "avatarUrl": ""}
	}
	tags := row.Tags
	if tags == nil {
		tags = []string{}
	}
	verBase := fmt.Sprintf("/api/themes/%s/versions/%d", row.FamilyID, row.Version)
	return gin.H{
		"familyId":      row.FamilyID,
		"version":       row.Version,
		"name":          row.Name,
		"description":   row.Description,
		"license":       row.License,
		"author":        author,
		"tags":          tags,
		"source":        row.Source,
		"previewLight":  verBase + "/preview/light",
		"previewDark":   verBase + "/preview/dark",
		"packageUrl":    verBase + "/package",
		"packageSize":   row.PackageSize,
		"packageSha256": row.PackageSHA256,
		"minAppVersion": row.MinAppVersion,
		"downloads":     row.RootDownloads,
		"updatedAt":     row.UpdatedAt,
		"createdAt":     row.CreatedAt,
	}
}

func formatReasonMessage(reasonCode, note string) string {
	base := services.ThemeReviewReasonMessages[reasonCode]
	if base == "" {
		return note
	}
	if note != "" {
		return base + "（" + note + "）"
	}
	return base
}

func formatSubmissionItem(pack models.ThemePack, author gin.H) gin.H {
	tags := pack.Tags
	if tags == nil {
		tags = []string{}
	}
	privBase := fmt.Sprintf("/api/themes/submissions/%s", pack.ID)
	res := gin.H{
		"id":               pack.ID,
		"familyId":         pack.FamilyID,
		"version":          pack.Version,
		"authorUserId":     pack.AuthorUserID,
		"name":             pack.Name,
		"description":      pack.Description,
		"tags":             tags,
		"license":          pack.License,
		"source":           pack.Source,
		"status":           pack.Status,
		"minAppVersion":    pack.MinAppVersion,
		"fontCopyright":    pack.FontCopyright,
		"fontLicenseNote":  pack.FontLicenseNote,
		"packageSha256":    pack.PackageSHA256,
		"packageSize":      pack.PackageSize,
		"packageUrl":       privBase + "/package",
		"previewLight":     privBase + "/preview/light",
		"previewDark":      privBase + "/preview/dark",
		"reviewReasonCode": pack.ReviewReasonCode,
		"reviewNote":       pack.ReviewNote,
		"reasonMessage":    formatReasonMessage(pack.ReviewReasonCode, pack.ReviewNote),
		"reviewedBy":       pack.ReviewedBy,
		"reviewedAt":       pack.ReviewedAt,
		"downloads":        pack.Downloads,
		"createdAt":        pack.CreatedAt,
		"updatedAt":        pack.UpdatedAt,
	}
	if author != nil {
		res["author"] = author
	}
	return res
}

func ifNoneMatchHit(headerVal, etag string) bool {
	if headerVal == "" || etag == "" {
		return false
	}
	if strings.TrimSpace(headerVal) == "*" {
		return true
	}
	for _, part := range strings.Split(headerVal, ",") {
		cand := strings.TrimSpace(part)
		cand = strings.TrimPrefix(cand, "W/")
		if cand == etag {
			return true
		}
	}
	return false
}

func respondJSONWithETag(c *gin.Context, cacheControl string, payload any) {
	raw, err := json.Marshal(payload)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "序列化失败", "code": services.ThemeCodeFailed})
		return
	}
	sum := sha256.Sum256(raw)
	etag := `"` + hex.EncodeToString(sum[:16]) + `"`
	c.Header("Cache-Control", cacheControl)
	c.Header("ETag", etag)
	if ifNoneMatchHit(c.GetHeader("If-None-Match"), etag) {
		c.Status(http.StatusNotModified)
		return
	}
	c.Data(http.StatusOK, "application/json; charset=utf-8", raw)
}

// ListCatalog 处理 GET /api/themes（支持 sort、tag、q、ids、cursor 与 ETag）。
func (h *ThemePackHandler) ListCatalog(c *gin.Context) {
	if !h.requireStoreEnabled(c) {
		return
	}
	db := h.service.DB.WithContext(c.Request.Context())
	baseQuery := db.Table("theme_packs").
		Select("theme_packs.*, roots.downloads AS root_downloads, roots.created_at AS root_created_at").
		Joins("JOIN theme_packs AS roots ON roots.id = theme_packs.family_id").
		Where("theme_packs.status = ? AND roots.status NOT IN ?",
			models.ThemeStatusApproved,
			[]string{models.ThemeStatusRemoved, models.ThemeStatusWithdrawn},
		)

	if idsRaw := strings.TrimSpace(c.Query("ids")); idsRaw != "" {
		parts := strings.Split(idsRaw, ",")
		ids := make([]string, 0, len(parts))
		seen := make(map[string]bool, len(parts))
		for _, p := range parts {
			id := strings.ToLower(strings.TrimSpace(p))
			if id == "" || seen[id] {
				continue
			}
			seen[id] = true
			ids = append(ids, id)
		}
		if len(ids) > 50 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "批量查询最多 50 个 ID", "code": services.ThemeCodeFieldInvalid, "field": "ids"})
			return
		}
		var rows []themeJoinedRow
		if len(ids) > 0 {
			if err := baseQuery.Where("theme_packs.family_id IN ?", ids).Find(&rows).Error; err != nil {
				writeThemeError(c, err)
				return
			}
		}
		authorIDs := make([]uint, 0, len(rows))
		for _, r := range rows {
			authorIDs = append(authorIDs, r.AuthorUserID)
		}
		authors := h.loadAuthorsMap(c, authorIDs)
		items := make([]gin.H, 0, len(rows))
		for _, r := range rows {
			items = append(items, formatPublicCatalogItem(r, authors[r.AuthorUserID]))
		}
		respondJSONWithETag(c, "public, max-age=0, must-revalidate", gin.H{"items": items})
		return
	}

	sortMode := c.DefaultQuery("sort", "latest")
	if sortMode != "latest" && sortMode != "popular" && sortMode != "official" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不支持的排序方式", "code": services.ThemeCodeFieldInvalid, "field": "sort"})
		return
	}
	if sortMode == "official" {
		baseQuery = baseQuery.Where("theme_packs.source = ?", models.ThemeSourceOfficial)
	}

	if tag := strings.TrimSpace(c.Query("tag")); tag != "" {
		tagToken, _ := json.Marshal(tag)
		baseQuery = baseQuery.Where("theme_packs.tags LIKE ?", "%"+string(tagToken)+"%")
	}

	if q := strings.TrimSpace(c.Query("q")); q != "" {
		if len([]rune(q)) > 60 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "搜索词过长", "code": services.ThemeCodeFieldInvalid, "field": "q"})
			return
		}
		like := "%" + strings.ToLower(q) + "%"
		baseQuery = baseQuery.Where("(LOWER(theme_packs.name) LIKE ? OR LOWER(theme_packs.description) LIKE ?)", like, like)
	}

	if cursorRaw := strings.TrimSpace(c.Query("cursor")); cursorRaw != "" {
		cur, ok := decodeThemeCursor(cursorRaw)
		if !ok || cur.Sort != sortMode {
			c.JSON(http.StatusBadRequest, gin.H{"error": "分页游标无效", "code": services.ThemeCodeFieldInvalid, "field": "cursor"})
			return
		}
		curTime := time.Unix(0, cur.CreatedAtNano)
		switch sortMode {
		case "latest":
			baseQuery = baseQuery.Where(
				"(theme_packs.created_at < ? OR (theme_packs.created_at = ? AND theme_packs.id < ?))",
				curTime, curTime, cur.ID,
			)
		case "popular":
			baseQuery = baseQuery.Where(
				"(roots.downloads < ? OR (roots.downloads = ? AND (theme_packs.created_at < ? OR (theme_packs.created_at = ? AND theme_packs.id < ?))))",
				cur.Downloads, cur.Downloads, curTime, curTime, cur.ID,
			)
		case "official":
			baseQuery = baseQuery.Where(
				"(roots.created_at > ? OR (roots.created_at = ? AND theme_packs.id > ?))",
				curTime, curTime, cur.ID,
			)
		}
	}

	switch sortMode {
	case "latest":
		baseQuery = baseQuery.Order("theme_packs.created_at DESC, theme_packs.id DESC")
	case "popular":
		baseQuery = baseQuery.Order("roots.downloads DESC, theme_packs.created_at DESC, theme_packs.id DESC")
	case "official":
		baseQuery = baseQuery.Order("roots.created_at ASC, theme_packs.id ASC")
	}

	const pageSize = 20
	var rows []themeJoinedRow
	if err := baseQuery.Limit(pageSize + 1).Find(&rows).Error; err != nil {
		writeThemeError(c, err)
		return
	}

	nextCursor := ""
	if len(rows) > pageSize {
		rows = rows[:pageSize]
		last := rows[len(rows)-1]
		ts := last.CreatedAt.UnixNano()
		if sortMode == "official" {
			ts = last.RootCreatedAt.UnixNano()
		}
		nextCursor = encodeThemeCursor(themeCatalogCursor{
			Sort:          sortMode,
			Downloads:     last.RootDownloads,
			CreatedAtNano: ts,
			ID:            last.ID,
		})
	}

	authorIDs := make([]uint, 0, len(rows))
	for _, r := range rows {
		authorIDs = append(authorIDs, r.AuthorUserID)
	}
	authors := h.loadAuthorsMap(c, authorIDs)
	items := make([]gin.H, 0, len(rows))
	for _, r := range rows {
		items = append(items, formatPublicCatalogItem(r, authors[r.AuthorUserID]))
	}
	resp := gin.H{"items": items}
	if nextCursor != "" {
		resp["nextCursor"] = nextCursor
	}
	respondJSONWithETag(c, "public, max-age=0, must-revalidate", resp)
}

// GetDetail 处理 GET /api/themes/:familyId。
func (h *ThemePackHandler) GetDetail(c *gin.Context) {
	if !h.requireStoreEnabled(c) {
		return
	}
	familyID := strings.ToLower(strings.TrimSpace(c.Param("familyId")))
	var row themeJoinedRow
	err := h.service.DB.WithContext(c.Request.Context()).
		Table("theme_packs").
		Select("theme_packs.*, roots.downloads AS root_downloads, roots.created_at AS root_created_at").
		Joins("JOIN theme_packs AS roots ON roots.id = theme_packs.family_id").
		Where("theme_packs.family_id = ? AND theme_packs.status = ? AND roots.status NOT IN ?",
			familyID,
			models.ThemeStatusApproved,
			[]string{models.ThemeStatusRemoved, models.ThemeStatusWithdrawn},
		).
		First(&row).Error
	if err != nil {
		writeThemeError(c, err)
		return
	}
	authors := h.loadAuthorsMap(c, []uint{row.AuthorUserID})
	item := formatPublicCatalogItem(row, authors[row.AuthorUserID])
	if manifest := h.service.ReadStoredManifest(row.ID); manifest != nil {
		item["manifest"] = manifest
	}
	respondJSONWithETag(c, "public, max-age=0, must-revalidate", item)
}

func (h *ThemePackHandler) findDownloadableVersion(c *gin.Context, familyID string, version int) (*models.ThemePack, error) {
	db := h.service.DB.WithContext(c.Request.Context())
	var root models.ThemePack
	if err := db.Select("id", "family_id", "status").First(&root, "id = ?", familyID).Error; err != nil {
		return nil, gorm.ErrRecordNotFound
	}
	if root.FamilyID != root.ID || root.Status == models.ThemeStatusRemoved || root.Status == models.ThemeStatusWithdrawn {
		return nil, gorm.ErrRecordNotFound
	}
	var pack models.ThemePack
	if err := db.Where("family_id = ? AND version = ? AND status IN ?",
		familyID,
		version,
		[]string{models.ThemeStatusApproved, models.ThemeStatusSuperseded},
	).First(&pack).Error; err != nil {
		return nil, gorm.ErrRecordNotFound
	}
	return &pack, nil
}

// ServePublicPackage 处理 GET /api/themes/:familyId/versions/:version/package。
func (h *ThemePackHandler) ServePublicPackage(c *gin.Context) {
	familyID := strings.ToLower(strings.TrimSpace(c.Param("familyId")))
	version, err := strconv.Atoi(c.Param("version"))
	if err != nil || version < 1 {
		writeThemeError(c, gorm.ErrRecordNotFound)
		return
	}
	pack, err := h.findDownloadableVersion(c, familyID, version)
	if err != nil {
		writeThemeError(c, err)
		return
	}

	etag := `"` + pack.PackageSHA256 + `"`
	c.Header("Cache-Control", "public, no-cache")
	c.Header("X-Content-Type-Options", "nosniff")
	c.Header("Content-Type", "application/vnd.sylulive.theme+zip")
	c.Header("ETag", etag)
	if ifNoneMatchHit(c.GetHeader("If-None-Match"), etag) {
		c.Status(http.StatusNotModified)
		return
	}

	filePath := filepath.Join(h.service.PackDir(pack.ID), "package.sltheme")
	file, err := os.Open(filePath)
	if err != nil {
		writeThemeError(c, gorm.ErrRecordNotFound)
		return
	}
	defer file.Close()

	if c.Request.Method == http.MethodGet {
		rangeHeader := strings.TrimSpace(c.GetHeader("Range"))
		if rangeHeader == "" || strings.HasPrefix(rangeHeader, "bytes=0-") {
			h.service.IncrementDownload(c.Request.Context(), familyID)
		}
	}
	http.ServeContent(c.Writer, c.Request, fmt.Sprintf("%s-v%d.sltheme", familyID, version), time.Time{}, file)
}

// ServePublicPreview 处理 GET /api/themes/:familyId/versions/:version/preview/:mode。
func (h *ThemePackHandler) ServePublicPreview(c *gin.Context) {
	familyID := strings.ToLower(strings.TrimSpace(c.Param("familyId")))
	version, err := strconv.Atoi(c.Param("version"))
	mode := strings.ToLower(strings.TrimSpace(c.Param("mode")))
	if err != nil || version < 1 || (mode != "light" && mode != "dark") {
		writeThemeError(c, gorm.ErrRecordNotFound)
		return
	}
	pack, err := h.findDownloadableVersion(c, familyID, version)
	if err != nil {
		writeThemeError(c, err)
		return
	}

	etag := fmt.Sprintf(`"%s-%s"`, pack.PackageSHA256, mode)
	c.Header("Cache-Control", "public, no-cache")
	c.Header("X-Content-Type-Options", "nosniff")
	c.Header("Content-Type", "image/jpeg")
	c.Header("ETag", etag)
	if ifNoneMatchHit(c.GetHeader("If-None-Match"), etag) {
		c.Status(http.StatusNotModified)
		return
	}

	filePath := filepath.Join(h.service.PackDir(pack.ID), "preview_"+mode+".jpg")
	file, err := os.Open(filePath)
	if err != nil {
		writeThemeError(c, gorm.ErrRecordNotFound)
		return
	}
	defer file.Close()

	http.ServeContent(c.Writer, c.Request, "preview_"+mode+".jpg", time.Time{}, file)
}

// ListUserThemes 处理 GET /api/users/:id/themes。
func (h *ThemePackHandler) ListUserThemes(c *gin.Context) {
	if !h.requireStoreEnabled(c) {
		return
	}
	uid64, err := strconv.ParseUint(strings.TrimSpace(c.Param("id")), 10, 64)
	if err != nil || uid64 == 0 {
		writeThemeError(c, gorm.ErrRecordNotFound)
		return
	}
	var rows []themeJoinedRow
	if err := h.service.DB.WithContext(c.Request.Context()).
		Table("theme_packs").
		Select("theme_packs.*, roots.downloads AS root_downloads, roots.created_at AS root_created_at").
		Joins("JOIN theme_packs AS roots ON roots.id = theme_packs.family_id").
		Where("theme_packs.author_user_id = ? AND theme_packs.status = ? AND roots.status NOT IN ?",
			uint(uid64),
			models.ThemeStatusApproved,
			[]string{models.ThemeStatusRemoved, models.ThemeStatusWithdrawn},
		).
		Order("theme_packs.created_at DESC, theme_packs.id DESC").
		Limit(50).
		Find(&rows).Error; err != nil {
		writeThemeError(c, err)
		return
	}
	authors := h.loadAuthorsMap(c, []uint{uint(uid64)})
	items := make([]gin.H, 0, len(rows))
	for _, r := range rows {
		items = append(items, formatPublicCatalogItem(r, authors[r.AuthorUserID]))
	}
	c.JSON(http.StatusOK, gin.H{"items": items})
}

// Submit 处理 POST /api/themes/submissions。
func (h *ThemePackHandler) Submit(c *gin.Context) {
	if !h.requireStoreEnabled(c) {
		return
	}
	userID := c.GetUint("user_id")
	if userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录", "code": services.ThemeCodeForbidden})
		return
	}
	select {
	case h.uploadSlots <- struct{}{}:
		defer func() { <-h.uploadSlots }()
	default:
		c.Header("Retry-After", "5")
		c.JSON(http.StatusServiceUnavailable, gin.H{"error": "上传繁忙，请稍后重试", "code": "theme_upload_busy"})
		return
	}

	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, services.ThemePackMaxRequestBodyBytes)
	err := c.Request.ParseMultipartForm(4 * 1024 * 1024)
	if c.Request.MultipartForm != nil {
		defer c.Request.MultipartForm.RemoveAll()
	}
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			c.JSON(http.StatusRequestEntityTooLarge, gin.H{"error": "主题文件过大", "code": services.ThemeCodeTooLarge})
			return
		}
		c.JSON(http.StatusBadRequest, gin.H{"error": "上传表单无效", "code": services.ThemeCodeFieldInvalid})
		return
	}

	if rc := strings.TrimSpace(c.PostForm("rightsConfirmed")); rc != "" && rc != "true" {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "请先确认拥有全部素材的使用权",
			"code":  services.ThemeCodeFieldInvalid,
			"field": "rightsConfirmed",
		})
		return
	}

	idemKey := strings.TrimSpace(c.PostForm("idempotencyKey"))
	if idemKey == "" {
		idemKey = strings.TrimSpace(c.GetHeader("Idempotency-Key"))
	}

	files := c.Request.MultipartForm.File["package"]
	if len(files) != 1 {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "请上传单个 .sltheme 主题包",
			"code":  services.ThemeCodeFieldInvalid,
			"field": "package",
		})
		return
	}
	header := files[0]
	if header.Size > services.ThemePackMaxPackageBytes {
		c.JSON(http.StatusRequestEntityTooLarge, gin.H{"error": "主题文件过大", "code": services.ThemeCodeTooLarge})
		return
	}
	file, err := header.Open()
	if err != nil {
		writeThemeError(c, err)
		return
	}
	rawZip, readErr := io.ReadAll(io.LimitReader(file, services.ThemePackMaxPackageBytes+1))
	_ = file.Close()
	if readErr != nil {
		writeThemeError(c, readErr)
		return
	}

	var overrides services.ThemeMetadataOverrides
	if _, hasName := c.GetPostForm("name"); hasName {
		v := strings.TrimSpace(c.PostForm("name"))
		overrides.Name = &v
	}
	if _, hasDesc := c.GetPostForm("description"); hasDesc {
		v := strings.TrimSpace(c.PostForm("description"))
		overrides.Description = &v
	}
	if _, hasLic := c.GetPostForm("license"); hasLic {
		v := strings.TrimSpace(c.PostForm("license"))
		overrides.License = &v
	}
	if rawTags, hasTags := c.GetPostForm("tags"); hasTags && strings.TrimSpace(rawTags) != "" {
		var parsedTags []string
		if json.Unmarshal([]byte(rawTags), &parsedTags) != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "标签格式无效", "code": services.ThemeCodeFieldInvalid, "field": "tags"})
			return
		}
		overrides.Tags = parsedTags
		overrides.HasTags = true
	}

	pack, err := h.service.Submit(c.Request.Context(), userID, services.ThemeSubmitOptions{
		IdempotencyKey:  idemKey,
		FamilyID:        c.PostForm("familyId"),
		RequestedSource: c.PostForm("source"),
		Overrides:       overrides,
	}, rawZip)
	if err != nil {
		writeThemeError(c, err)
		return
	}
	c.Header("Cache-Control", "private, no-store")
	c.JSON(http.StatusOK, formatSubmissionItem(*pack, nil))
}

// ListMine 处理 GET /api/themes/submissions。
func (h *ThemePackHandler) ListMine(c *gin.Context) {
	userID := c.GetUint("user_id")
	if userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录", "code": services.ThemeCodeForbidden})
		return
	}
	query := h.service.DB.WithContext(c.Request.Context()).
		Model(&models.ThemePack{}).
		Where("author_user_id = ?", userID)

	if status := strings.TrimSpace(c.Query("status")); status != "" {
		query = query.Where("status = ?", status)
	}

	var packs []models.ThemePack
	if err := query.Order("created_at DESC, version DESC").Limit(100).Find(&packs).Error; err != nil {
		writeThemeError(c, err)
		return
	}
	items := make([]gin.H, 0, len(packs))
	for _, p := range packs {
		items = append(items, formatSubmissionItem(p, nil))
	}
	c.Header("Cache-Control", "private, no-store")
	c.JSON(http.StatusOK, gin.H{"items": items})
}

func (h *ThemePackHandler) loadPrivateSubmission(c *gin.Context) (*models.ThemePack, error) {
	uid := c.GetUint("user_id")
	if uid == 0 {
		return nil, gorm.ErrRecordNotFound
	}
	id := strings.ToLower(strings.TrimSpace(c.Param("id")))
	var pack models.ThemePack
	if err := h.service.DB.WithContext(c.Request.Context()).First(&pack, "id = ?", id).Error; err != nil {
		return nil, gorm.ErrRecordNotFound
	}
	if pack.Status == models.ThemeStatusWithdrawn {
		return nil, gorm.ErrRecordNotFound
	}
	if pack.AuthorUserID != uid && !h.isAdmin(c) {
		return nil, gorm.ErrRecordNotFound
	}
	return &pack, nil
}

// ServePrivatePackage 处理 GET /api/themes/submissions/:id/package。
func (h *ThemePackHandler) ServePrivatePackage(c *gin.Context) {
	pack, err := h.loadPrivateSubmission(c)
	if err != nil {
		writeThemeError(c, err)
		return
	}
	filePath := filepath.Join(h.service.PackDir(pack.ID), "package.sltheme")
	file, err := os.Open(filePath)
	if err != nil {
		writeThemeError(c, gorm.ErrRecordNotFound)
		return
	}
	defer file.Close()

	c.Header("Cache-Control", "private, no-store")
	c.Header("X-Content-Type-Options", "nosniff")
	c.Header("Content-Type", "application/vnd.sylulive.theme+zip")
	c.Header("ETag", `"`+pack.PackageSHA256+`"`)
	http.ServeContent(c.Writer, c.Request, pack.ID+".sltheme", time.Time{}, file)
}

// ServePrivatePreview 处理 GET /api/themes/submissions/:id/preview/:mode。
func (h *ThemePackHandler) ServePrivatePreview(c *gin.Context) {
	mode := strings.ToLower(strings.TrimSpace(c.Param("mode")))
	if mode != "light" && mode != "dark" {
		writeThemeError(c, gorm.ErrRecordNotFound)
		return
	}
	pack, err := h.loadPrivateSubmission(c)
	if err != nil {
		writeThemeError(c, err)
		return
	}
	filePath := filepath.Join(h.service.PackDir(pack.ID), "preview_"+mode+".jpg")
	file, err := os.Open(filePath)
	if err != nil {
		writeThemeError(c, gorm.ErrRecordNotFound)
		return
	}
	defer file.Close()

	c.Header("Cache-Control", "private, no-store")
	c.Header("X-Content-Type-Options", "nosniff")
	c.Header("Content-Type", "image/jpeg")
	http.ServeContent(c.Writer, c.Request, "preview_"+mode+".jpg", time.Time{}, file)
}

// Withdraw 处理 POST /api/themes/submissions/:id/withdraw。
func (h *ThemePackHandler) Withdraw(c *gin.Context) {
	userID := c.GetUint("user_id")
	if userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录", "code": services.ThemeCodeForbidden})
		return
	}
	if err := h.service.Withdraw(c.Request.Context(), c.Param("id"), userID); err != nil {
		writeThemeError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已撤回"})
}

// AdminList 处理 GET /api/admin/themes?status=。
func (h *ThemePackHandler) AdminList(c *gin.Context) {
	if !h.isAdmin(c) {
		c.JSON(http.StatusForbidden, gin.H{"error": "无管理员权限", "code": services.ThemeCodeForbidden})
		return
	}
	status := strings.TrimSpace(c.Query("status"))
	if status == "" {
		status = models.ThemeStatusPending
	}
	db := h.service.DB.WithContext(c.Request.Context())
	query := db.Model(&models.ThemePack{})
	if status != "all" {
		query = query.Where("status = ?", status)
	}
	var packs []models.ThemePack
	if err := query.Order("created_at DESC, version DESC").Limit(100).Find(&packs).Error; err != nil {
		writeThemeError(c, err)
		return
	}

	authorIDs := make([]uint, 0, len(packs))
	familyIDs := make([]string, 0, len(packs))
	seenFam := make(map[string]bool, len(packs))
	for _, p := range packs {
		authorIDs = append(authorIDs, p.AuthorUserID)
		if !seenFam[p.FamilyID] {
			seenFam[p.FamilyID] = true
			familyIDs = append(familyIDs, p.FamilyID)
		}
	}
	authors := h.loadAuthorsMap(c, authorIDs)

	approvedByFamily := make(map[string]models.ThemePack, len(familyIDs))
	if len(familyIDs) > 0 {
		var approvedRows []models.ThemePack
		_ = db.Where("family_id IN ? AND status = ?", familyIDs, models.ThemeStatusApproved).Find(&approvedRows).Error
		for _, ap := range approvedRows {
			approvedByFamily[ap.FamilyID] = ap
		}
	}

	items := make([]gin.H, 0, len(packs))
	for _, p := range packs {
		item := formatSubmissionItem(p, authors[p.AuthorUserID])
		if mf := h.service.ReadStoredManifest(p.ID); mf != nil {
			item["manifest"] = mf
		}
		if ap, has := approvedByFamily[p.FamilyID]; has && ap.ID != p.ID {
			summary := formatSubmissionItem(ap, authors[ap.AuthorUserID])
			if apMf := h.service.ReadStoredManifest(ap.ID); apMf != nil {
				summary["manifest"] = apMf
			}
			item["currentApproved"] = summary
		}
		items = append(items, item)
	}
	c.Header("Cache-Control", "private, no-store")
	c.JSON(http.StatusOK, gin.H{"items": items})
}

// AdminReview 处理 POST /api/admin/themes/:id/review。
func (h *ThemePackHandler) AdminReview(c *gin.Context) {
	if !h.isAdmin(c) {
		c.JSON(http.StatusForbidden, gin.H{"error": "无管理员权限", "code": services.ThemeCodeForbidden})
		return
	}
	var input struct {
		Approve    *bool  `json:"approve"`
		ReasonCode string `json:"reasonCode"`
		Note       string `json:"note"`
	}
	if err := c.ShouldBindJSON(&input); err != nil || input.Approve == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "审核请求参数无效", "code": services.ThemeCodeFieldInvalid})
		return
	}
	updated, err := h.service.Review(c.Request.Context(), c.Param("id"), c.GetUint("user_id"), *input.Approve, input.ReasonCode, input.Note)
	if err != nil {
		writeThemeError(c, err)
		return
	}
	c.JSON(http.StatusOK, formatSubmissionItem(*updated, nil))
}

// AdminRemove 处理 POST /api/admin/themes/:familyId/remove。
func (h *ThemePackHandler) AdminRemove(c *gin.Context) {
	if !h.isAdmin(c) {
		c.JSON(http.StatusForbidden, gin.H{"error": "无管理员权限", "code": services.ThemeCodeForbidden})
		return
	}
	var input struct {
		ReasonCode string `json:"reasonCode"`
		Note       string `json:"note"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "下架请求参数无效", "code": services.ThemeCodeFieldInvalid})
		return
	}
	if err := h.service.Remove(c.Request.Context(), c.Param("familyId"), c.GetUint("user_id"), input.ReasonCode, input.Note); err != nil {
		writeThemeError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已下架"})
}

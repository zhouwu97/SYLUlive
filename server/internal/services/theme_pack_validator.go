package services

import (
	"archive/zip"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"image"
	"image/color"
	"image/draw"
	"image/jpeg"
	"image/png"
	"io"
	"math"
	"net/http"
	"path"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"unicode/utf8"

	"golang.org/x/image/font/sfnt"
	_ "golang.org/x/image/webp"
	"golang.org/x/text/encoding/simplifiedchinese"
)

const (
	ThemePackMaxRequestBodyBytes int64 = 49 * 1024 * 1024
	ThemePackMaxPackageBytes     int64 = 48 * 1024 * 1024
	ThemePackMaxExpandedBytes    int64 = 96 * 1024 * 1024
	ThemePackMaxManifestBytes    int64 = 64 * 1024
	ThemePackMaxFontBytes        int64 = 24 * 1024 * 1024
)

const (
	ThemeCodeZipInvalid        = "theme_zip_invalid"
	ThemeCodeTooLarge          = "theme_too_large"
	ThemeCodeManifestInvalid   = "theme_manifest_invalid"
	ThemeCodeFieldInvalid      = "theme_field_invalid"
	ThemeCodeFormatUnsupported = "theme_format_unsupported"
	ThemeCodeAppTooOld         = "theme_app_too_old"
	ThemeCodeAssetMissing      = "theme_asset_missing"
	ThemeCodeImageInvalid      = "theme_image_invalid"
	ThemeCodeContrastLow       = "theme_contrast_low"
	ThemeCodeFontInvalid       = "theme_font_invalid"
	ThemeCodeFontCoverageLow   = "theme_font_coverage_low"

	ThemeCodeNotFound  = "theme_not_found"
	ThemeCodeQuota     = "theme_quota"
	ThemeCodeConflict  = "theme_conflict"
	ThemeCodeForbidden = "theme_forbidden"
	ThemeCodeFailed    = "theme_failed"
)

// ThemePackError 统一承载契约第 8 节的错误码、字段路径与 HTTP 状态。
type ThemePackError struct {
	Code    string
	Field   string
	Message string
	Status  int
}

func (e *ThemePackError) Error() string {
	return e.Message
}

func newThemeError(status int, code, field, msg string) *ThemePackError {
	return &ThemePackError{Code: code, Field: field, Message: msg, Status: status}
}

func themeFieldError(field string) *ThemePackError {
	return newThemeError(http.StatusBadRequest, ThemeCodeFieldInvalid, field, fmt.Sprintf("主题设置有误：%s", field))
}

var (
	themeUUIDPattern       = regexp.MustCompile(`^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$`)
	themeSemverPattern     = regexp.MustCompile(`^\d+\.\d+\.\d+$`)
	themeOpaqueHexPattern  = regexp.MustCompile(`^#[a-fA-F0-9]{6}$`)
	themeAlphaHexPattern   = regexp.MustCompile(`^#(?:[a-fA-F0-9]{6}|[a-fA-F0-9]{8})$`)
	themeIdemKeyPattern    = regexp.MustCompile(`^[a-zA-Z0-9_-]{8,64}$`)
	themeOpaqueImgPathExpr = map[string]*regexp.Regexp{
		"preview":     regexp.MustCompile(`^preview/[a-z0-9_-]{1,40}\.(webp|jpg|png)$`),
		"wallpaper":   regexp.MustCompile(`^wallpaper/[a-z0-9_-]{1,40}\.(webp|jpg|png)$`),
		"decorations": regexp.MustCompile(`^decorations/[a-z0-9_-]{1,40}\.(webp|jpg|png)$`),
	}
	themeAlphaImgPathExpr = map[string]*regexp.Regexp{
		"icons":       regexp.MustCompile(`^icons/[a-z0-9_-]{1,40}\.(webp|png)$`),
		"decorations": regexp.MustCompile(`^decorations/[a-z0-9_-]{1,40}\.(webp|png)$`),
	}
	themeFontPathPattern = regexp.MustCompile(`^fonts/[a-z0-9_-]{1,40}\.(ttf|otf)$`)
)

var themeTokenKeys = []string{
	"primary",
	"onPrimary",
	"primaryContainer",
	"onPrimaryContainer",
	"background",
	"surface",
	"surfaceElevated",
	"surfaceMuted",
	"card",
	"cardBorder",
	"textPrimary",
	"textSecondary",
	"textTertiary",
	"textDisabled",
	"divider",
	"outline",
	"inputFill",
	"inputFillFocused",
	"searchFill",
	"tagBackground",
	"tagText",
	"navBackground",
	"navSelected",
	"navUnselected",
	"appBarBackground",
	"appBarForeground",
	"bubbleIncoming",
	"bubbleIncomingText",
	"bubbleOutgoing",
	"bubbleOutgoingText",
	"feedSectionSurface",
	"feedFeaturedSurface",
	"feedFeaturedText",
	"courseCardText",
	"timetableGrid",
	"timetableToday",
}

var themeTranslucentTokens = map[string]bool{
	"cardBorder":       true,
	"divider":          true,
	"outline":          true,
	"navBackground":    true,
	"appBarBackground": true,
	"timetableGrid":    true,
	"timetableToday":   true,
}

var themeAllowedTags = map[string]bool{
	"浅色": true, "深色": true, "明暗自适应": true, "简约": true, "清新": true,
	"可爱": true, "动漫": true, "风景": true, "校园": true, "节日": true,
	"纯色": true, "高对比": true, "复古": true, "科技": true,
}

// ThemeReviewReasonMessages 对应制作细则 8.2 节的 9 个拒绝/下架原因代码。
var ThemeReviewReasonMessages = map[string]string{
	"contrast":       "部分页面的文字看不清，请提高文字与背景的对比度",
	"wallpaper_text": "壁纸含文字、水印、二维码或联系方式",
	"copyright":      "素材授权不清，或使用了未授权的作品",
	"content":        "内容不符合社区规范",
	"icon_semantics": "底栏图标无法辨认原含义，或两态没有区别",
	"quality":        "画面模糊、拉伸、主体被遮挡等质量问题",
	"metadata":       "名称、简介或标签与内容不符，或含广告",
	"impersonation":  "冒充官方或他人",
	"duplicate":      "与已上架的主题重复",
}

type themeAssetKind string

const (
	themeAssetPreview   themeAssetKind = "preview"
	themeAssetWallpaper themeAssetKind = "wallpaper"
	themeAssetIcon      themeAssetKind = "icon"
	themeAssetLauncher  themeAssetKind = "launcher"
	themeAssetHeader    themeAssetKind = "header"
	themeAssetSticker   themeAssetKind = "sticker"
	themeAssetFont      themeAssetKind = "font"
	// 空状态、错误状态插画：透明 PNG/WebP，长边 ≤ 1024，≤ 1MB。
	themeAssetIllustration themeAssetKind = "illustration"
)

// 卡片角饰位置与可替换入口图标的键，与客户端 ThemeManifest 保持一致。
var (
	themeOrnamentSlots   = []string{"postCard", "campusHeader", "campusNotice", "campusServices", "fab"}
	themeServiceIconKeys = []string{"edu", "canteen", "ranking", "team", "map", "calendar", "erke", "fitness", "exam", "papers", "sites", "cloudGame", "lottery", "menu", "messages", "search"}
)

type themeAssetRef struct {
	Path string
	Kind themeAssetKind
}

// ThemeMetadataOverrides 允许投稿表单在进入契约校验前覆盖顶层展示元数据。
type ThemeMetadataOverrides struct {
	Name              *string
	Description       *string
	Tags              []string
	HasTags           bool
	License           *string
	CurrentAppVersion string
}

// ValidatedThemePack 保存锁外完整校验与图片重编码后的规范化产物。
type ValidatedThemePack struct {
	Manifest        map[string]any
	Name            string
	Description     string
	Tags            []string
	License         string
	MinAppVersion   string
	FontCopyright   string
	FontLicenseNote string
	PreviewLightJPG []byte
	PreviewDarkJPG  []byte
	NormalizedFiles map[string][]byte // 规范包内的路径 -> 重编码后图片或原样字体字节
}

var (
	gb2312Once  sync.Once
	gb2312Runes []rune
)

func loadGB2312Level1Runes() []rune {
	gb2312Once.Do(func() {
		dec := simplifiedchinese.GB18030.NewDecoder()
		runes := make([]rune, 0, 3755)
		for b1 := byte(0xB0); b1 <= 0xD7; b1++ {
			maxB2 := byte(0xFE)
			if b1 == 0xD7 {
				maxB2 = 0xF9
			}
			for b2 := byte(0xA1); b2 <= maxB2; b2++ {
				decoded, err := dec.Bytes([]byte{b1, b2})
				if err == nil {
					r, _ := utf8.DecodeRune(decoded)
					if r != utf8.RuneError {
						runes = append(runes, r)
					}
				}
			}
		}
		gb2312Runes = runes
	})
	return gb2312Runes
}

// ValidateAndNormalizeThemePack 在锁外执行容器、契约字段、WCAG 对比度、图片头部尺寸、字体覆盖率校验，并重编码去除全部图片元数据。
func ValidateAndNormalizeThemePack(rawZip []byte, overrides ThemeMetadataOverrides) (*ValidatedThemePack, error) {
	if len(rawZip) == 0 {
		return nil, newThemeError(http.StatusBadRequest, ThemeCodeZipInvalid, "", "这不是有效的主题文件")
	}
	if int64(len(rawZip)) > ThemePackMaxPackageBytes {
		return nil, newThemeError(http.StatusRequestEntityTooLarge, ThemeCodeTooLarge, "", "主题文件过大")
	}
	expectedCount, err := verifyZipCentralDirectoryCount(rawZip)
	if err != nil {
		return nil, err
	}
	zr, err := zip.NewReader(bytes.NewReader(rawZip), int64(len(rawZip)))
	if err != nil || len(zr.File) != expectedCount {
		return nil, newThemeError(http.StatusBadRequest, ThemeCodeZipInvalid, "", "这不是有效的主题文件")
	}

	entries := make(map[string]*zip.File, len(zr.File))
	for _, zf := range zr.File {
		if _, dup := entries[zf.Name]; dup {
			return nil, newThemeError(http.StatusBadRequest, ThemeCodeZipInvalid, zf.Name, "这不是有效的主题文件")
		}
		entries[zf.Name] = zf
	}

	manifestEntry, ok := entries["manifest.json"]
	if !ok {
		return nil, newThemeError(http.StatusBadRequest, ThemeCodeManifestInvalid, "manifest.json", "主题描述信息损坏")
	}
	manifestBytes, err := readZipEntryVerified(rawZip, manifestEntry, ThemePackMaxManifestBytes, ThemeCodeManifestInvalid)
	if err != nil {
		return nil, err
	}
	if !utf8.Valid(manifestBytes) {
		return nil, newThemeError(http.StatusBadRequest, ThemeCodeManifestInvalid, "manifest.json", "主题描述信息损坏")
	}
	var rawManifest any
	dec := json.NewDecoder(bytes.NewReader(manifestBytes))
	dec.UseNumber()
	if err := dec.Decode(&rawManifest); err != nil {
		return nil, newThemeError(http.StatusBadRequest, ThemeCodeManifestInvalid, "manifest.json", "主题描述信息损坏")
	}
	var trailing any
	if dec.Decode(&trailing) != io.EOF {
		return nil, newThemeError(http.StatusBadRequest, ThemeCodeManifestInvalid, "manifest.json", "主题描述信息损坏")
	}
	manifestObj, ok := rawManifest.(map[string]any)
	if !ok {
		return nil, newThemeError(http.StatusBadRequest, ThemeCodeManifestInvalid, "manifest.json", "主题描述信息损坏")
	}

	if overrides.Name != nil {
		manifestObj["name"] = *overrides.Name
	}
	if overrides.Description != nil {
		manifestObj["description"] = *overrides.Description
	}
	if overrides.HasTags {
		tagSlice := make([]any, len(overrides.Tags))
		for i, t := range overrides.Tags {
			tagSlice[i] = t
		}
		manifestObj["tags"] = tagSlice
	}
	if overrides.License != nil {
		manifestObj["license"] = *overrides.License
	}

	parsedManifest, refs, err := parseAndValidateManifest(manifestObj, overrides.CurrentAppVersion)
	if err != nil {
		return nil, err
	}
	if err := checkManifestContrast(parsedManifest); err != nil {
		return nil, err
	}

	// 按唯一 (path, kind) 解压引用资源并累计解压总预算（96MB），忽略未引用条目。
	var expandedTotal int64
	rawEntryCache := make(map[string][]byte, len(refs))
	for _, ref := range refs {
		if _, loaded := rawEntryCache[ref.Path]; loaded {
			continue
		}
		zf, exists := entries[ref.Path]
		if !exists {
			return nil, newThemeError(http.StatusBadRequest, ThemeCodeAssetMissing, ref.Path, fmt.Sprintf("主题缺少图片：%s", ref.Path))
		}
		remaining := ThemePackMaxExpandedBytes - expandedTotal
		if remaining <= 0 || zf.UncompressedSize64 > uint64(remaining) {
			return nil, newThemeError(http.StatusRequestEntityTooLarge, ThemeCodeTooLarge, ref.Path, "主题文件过大")
		}
		data, err := readZipEntryVerified(rawZip, zf, remaining, ThemeCodeTooLarge)
		if err != nil {
			return nil, err
		}
		expandedTotal += int64(len(data))
		rawEntryCache[ref.Path] = data
	}

	normalizedFiles := make(map[string][]byte, len(refs))
	pathMapping := make(map[string]string, len(refs))
	usedOutPaths := make(map[string]string, len(refs)) // outPath -> srcKey

	allocateOutPath := func(srcPath, targetExt, srcKey string) string {
		dir := path.Dir(srcPath)
		base := path.Base(srcPath)
		ext := path.Ext(base)
		stem := strings.TrimSuffix(base, ext)
		candidate := dir + "/" + stem + targetExt
		if owner, taken := usedOutPaths[candidate]; !taken || owner == srcKey {
			usedOutPaths[candidate] = srcKey
			return candidate
		}
		for idx := 2; ; idx++ {
			suffix := fmt.Sprintf("_%d", idx)
			maxStem := 40 - len(suffix)
			trimmed := stem
			if len(trimmed) > maxStem {
				trimmed = trimmed[:maxStem]
			}
			alt := dir + "/" + trimmed + suffix + targetExt
			if owner, taken := usedOutPaths[alt]; !taken || owner == srcKey {
				usedOutPaths[alt] = srcKey
				return alt
			}
		}
	}

	var fontCopyright, fontLicenseNote string
	for _, ref := range refs {
		srcKey := string(ref.Kind) + ":" + ref.Path
		if _, done := pathMapping[srcKey]; done {
			continue
		}
		rawAsset := rawEntryCache[ref.Path]
		if ref.Kind == themeAssetFont {
			cRight, licNote, err := validateThemeFont(rawAsset, ref.Path)
			if err != nil {
				return nil, err
			}
			if fontCopyright == "" && cRight != "" {
				fontCopyright = cRight
			}
			if fontLicenseNote == "" && licNote != "" {
				fontLicenseNote = licNote
			}
			outPath := allocateOutPath(ref.Path, path.Ext(ref.Path), srcKey)
			pathMapping[srcKey] = outPath
			normalizedFiles[outPath] = rawAsset
			continue
		}
		encoded, targetExt, err := validateAndNormalizeThemeImage(rawAsset, ref.Kind, ref.Path)
		if err != nil {
			return nil, err
		}
		outPath := allocateOutPath(ref.Path, targetExt, srcKey)
		pathMapping[srcKey] = outPath
		normalizedFiles[outPath] = encoded
	}

	rewriteManifestAssetPaths(parsedManifest, pathMapping)
	previewMap := parsedManifest["preview"].(map[string]any)
	previewLightPath := previewMap["light"].(string)
	previewDarkPath := previewMap["dark"].(string)

	tagsOut := []string{}
	if rawTags, ok := parsedManifest["tags"].([]string); ok {
		tagsOut = rawTags
	}

	return &ValidatedThemePack{
		Manifest:        parsedManifest,
		Name:            parsedManifest["name"].(string),
		Description:     parsedManifest["description"].(string),
		Tags:            tagsOut,
		License:         parsedManifest["license"].(string),
		MinAppVersion:   parsedManifest["minAppVersion"].(string),
		FontCopyright:   fontCopyright,
		FontLicenseNote: fontLicenseNote,
		PreviewLightJPG: normalizedFiles[previewLightPath],
		PreviewDarkJPG:  normalizedFiles[previewDarkPath],
		NormalizedFiles: normalizedFiles,
	}, nil
}

func verifyZipCentralDirectoryCount(raw []byte) (int, error) {
	if len(raw) < 22 {
		return 0, newThemeError(http.StatusBadRequest, ThemeCodeZipInvalid, "", "这不是有效的主题文件")
	}
	minPos := len(raw) - (65535 + 22)
	if minPos < 0 {
		minPos = 0
	}
	eocdPos := -1
	for i := len(raw) - 22; i >= minPos; i-- {
		if raw[i] == 0x50 && raw[i+1] == 0x4b && raw[i+2] == 0x05 && raw[i+3] == 0x06 {
			commentLen := int(binary.LittleEndian.Uint16(raw[i+20 : i+22]))
			if i+22+commentLen == len(raw) {
				eocdPos = i
				break
			}
		}
	}
	if eocdPos < 0 {
		return 0, newThemeError(http.StatusBadRequest, ThemeCodeZipInvalid, "", "这不是有效的主题文件")
	}
	diskNo := binary.LittleEndian.Uint16(raw[eocdPos+4 : eocdPos+6])
	cdDisk := binary.LittleEndian.Uint16(raw[eocdPos+6 : eocdPos+8])
	diskEntries := binary.LittleEndian.Uint16(raw[eocdPos+8 : eocdPos+10])
	totalEntries := binary.LittleEndian.Uint16(raw[eocdPos+10 : eocdPos+12])
	if diskNo != 0 || cdDisk != 0 || diskEntries != totalEntries {
		return 0, newThemeError(http.StatusBadRequest, ThemeCodeZipInvalid, "", "这不是有效的主题文件")
	}
	return int(totalEntries), nil
}

func readZipEntryVerified(rawZip []byte, zf *zip.File, maxBytes int64, tooLargeCode string) ([]byte, error) {
	tooLargeStatus := http.StatusRequestEntityTooLarge
	tooLargeMsg := "主题文件过大"
	if tooLargeCode == ThemeCodeManifestInvalid {
		tooLargeStatus = http.StatusBadRequest
		tooLargeMsg = "主题描述信息损坏"
	}
	if strings.HasSuffix(zf.Name, "/") || zf.Flags&0x1 != 0 || (zf.Method != zip.Store && zf.Method != zip.Deflate) {
		return nil, newThemeError(http.StatusBadRequest, ThemeCodeZipInvalid, zf.Name, "这不是有效的主题文件")
	}
	if err := verifyLocalHeaderCRC(rawZip, zf); err != nil {
		return nil, err
	}
	if zf.UncompressedSize64 > uint64(maxBytes) {
		return nil, newThemeError(tooLargeStatus, tooLargeCode, zf.Name, tooLargeMsg)
	}
	rc, err := zf.Open()
	if err != nil {
		return nil, newThemeError(http.StatusBadRequest, ThemeCodeZipInvalid, zf.Name, "这不是有效的主题文件")
	}
	data, readErr := io.ReadAll(io.LimitReader(rc, maxBytes+1))
	closeErr := rc.Close()
	if int64(len(data)) > maxBytes {
		return nil, newThemeError(tooLargeStatus, tooLargeCode, zf.Name, tooLargeMsg)
	}
	if readErr != nil || closeErr != nil {
		return nil, newThemeError(http.StatusBadRequest, ThemeCodeZipInvalid, zf.Name, "这不是有效的主题文件")
	}
	if crc32.ChecksumIEEE(data) != zf.CRC32 {
		return nil, newThemeError(http.StatusBadRequest, ThemeCodeZipInvalid, zf.Name, "这不是有效的主题文件")
	}
	return data, nil
}

func verifyLocalHeaderCRC(rawZip []byte, zf *zip.File) error {
	dataOffset, err := zf.DataOffset()
	if err != nil || dataOffset < 30 || int(dataOffset) > len(rawZip) {
		return newThemeError(http.StatusBadRequest, ThemeCodeZipInvalid, zf.Name, "这不是有效的主题文件")
	}
	// 当不使用 Data Descriptor（bit 3 == 0）时，核对本地文件头与中央目录中的 CRC32 一致。
	if zf.Flags&0x8 != 0 {
		return nil
	}
	// 从 dataOffset 反推本地文件头起点（30 + nameLen + extraLen）。
	searchStart := int(dataOffset) - 30 - len(zf.Name) - 65535
	if searchStart < 0 {
		searchStart = 0
	}
	for pos := int(dataOffset) - 30 - len(zf.Name); pos >= searchStart; pos-- {
		if pos+30 > len(rawZip) {
			continue
		}
		if rawZip[pos] == 0x50 && rawZip[pos+1] == 0x4b && rawZip[pos+2] == 0x03 && rawZip[pos+3] == 0x04 {
			nameLen := int(binary.LittleEndian.Uint16(rawZip[pos+26 : pos+28]))
			extraLen := int(binary.LittleEndian.Uint16(rawZip[pos+28 : pos+30]))
			if pos+30+nameLen+extraLen == int(dataOffset) {
				localCRC := binary.LittleEndian.Uint32(rawZip[pos+14 : pos+18])
				if localCRC != zf.CRC32 {
					return newThemeError(http.StatusBadRequest, ThemeCodeZipInvalid, zf.Name, "这不是有效的主题文件")
				}
				return nil
			}
		}
	}
	return newThemeError(http.StatusBadRequest, ThemeCodeZipInvalid, zf.Name, "这不是有效的主题文件")
}

func parseAndValidateManifest(source map[string]any, currentAppVersion string) (map[string]any, []themeAssetRef, error) {
	refs := make([]themeAssetRef, 0, 16)
	addRef := func(p string, k themeAssetKind) string {
		refs = append(refs, themeAssetRef{Path: p, Kind: k})
		return p
	}

	fmtVer, ok := parseJSONInt(source["formatVersion"])
	if !ok {
		return nil, nil, themeFieldError("formatVersion")
	}
	if fmtVer != 1 {
		return nil, nil, newThemeError(http.StatusBadRequest, ThemeCodeFormatUnsupported, "formatVersion", "这个主题需要更新版本的 App")
	}

	minApp, err := parseJSONText(source["minAppVersion"], "minAppVersion", 1, 30, false)
	if err != nil || !themeSemverPattern.MatchString(minApp) {
		return nil, nil, themeFieldError("minAppVersion")
	}
	if currentAppVersion != "" && themeSemverPattern.MatchString(currentAppVersion) {
		if compareSemver(currentAppVersion, minApp) < 0 {
			return nil, nil, newThemeError(http.StatusBadRequest, ThemeCodeAppTooOld, "minAppVersion", fmt.Sprintf("请升级到 %s 后再使用", minApp))
		}
	}

	idStr, err := parseJSONText(source["id"], "id", 36, 36, false)
	if err != nil || !themeUUIDPattern.MatchString(idStr) {
		return nil, nil, themeFieldError("id")
	}
	ver, ok := parseJSONInt(source["version"])
	if !ok || ver < 1 {
		return nil, nil, themeFieldError("version")
	}
	nameStr, err := parseJSONText(source["name"], "name", 1, 20, false)
	if err != nil {
		return nil, nil, err
	}
	authorStr, err := parseJSONText(source["author"], "author", 1, 20, false)
	if err != nil {
		return nil, nil, err
	}
	descStr := ""
	if source["description"] != nil {
		descStr, err = parseJSONText(source["description"], "description", 0, 200, true)
		if err != nil {
			return nil, nil, err
		}
	}
	licStr, err := parseJSONChoice(source["license"], "license", []string{"CC0-1.0", "CC-BY-4.0", "CC-BY-NC-4.0", "personal-use"})
	if err != nil {
		return nil, nil, err
	}

	previewObj, err := parseJSONObject(source["preview"], "preview")
	if err != nil {
		return nil, nil, err
	}
	previewLight, err := parseAssetPath(previewObj["light"], "preview.light", "preview", false)
	if err != nil {
		return nil, nil, err
	}
	previewDark, err := parseAssetPath(previewObj["dark"], "preview.dark", "preview", false)
	if err != nil {
		return nil, nil, err
	}
	addRef(previewLight, themeAssetPreview)
	addRef(previewDark, themeAssetPreview)

	lightMap, err := parseVariant(source["light"], "light", addRef)
	if err != nil {
		return nil, nil, err
	}
	darkMap, err := parseVariant(source["dark"], "dark", addRef)
	if err != nil {
		return nil, nil, err
	}

	out := map[string]any{
		"formatVersion": 1,
		"minAppVersion": minApp,
		"id":            strings.ToLower(idStr),
		"version":       ver,
		"name":          nameStr,
		"author":        authorStr,
		"description":   descStr,
		"license":       licStr,
		"preview": map[string]any{
			"light": previewLight,
			"dark":  previewDark,
		},
		"light": lightMap,
		"dark":  darkMap,
	}

	if source["tags"] != nil {
		rawList, err := parseJSONList(source["tags"], "tags", 0, 5)
		if err != nil {
			return nil, nil, err
		}
		tags := make([]string, 0, len(rawList))
		for i, item := range rawList {
			s, ok := item.(string)
			if !ok || !themeAllowedTags[s] {
				return nil, nil, themeFieldError(fmt.Sprintf("tags[%d]", i))
			}
			tags = append(tags, s)
		}
		out["tags"] = tags
	}

	if source["shape"] != nil {
		shapeStr, err := parseJSONChoice(source["shape"], "shape", []string{"compact", "standard", "rounded"})
		if err != nil {
			return nil, nil, err
		}
		out["shape"] = shapeStr
	}

	if source["bottomNav"] != nil {
		navObj, err := parseJSONObject(source["bottomNav"], "bottomNav")
		if err != nil {
			return nil, nil, err
		}
		navOut := map[string]any{}
		if navObj["style"] != nil {
			_, err := parseJSONChoice(navObj["style"], "bottomNav.style", []string{"normal", "floating", "liquid_glass"})
			if err != nil {
				return nil, nil, err
			}
		}
		tintRaw := any("template")
		if navObj["iconTint"] != nil {
			tintRaw = navObj["iconTint"]
		}
		tintStr, err := parseJSONChoice(tintRaw, "bottomNav.iconTint", []string{"template", "original"})
		if err != nil {
			return nil, nil, err
		}
		navOut["iconTint"] = tintStr

		iconsObj := map[string]any{}
		if navObj["icons"] != nil {
			iconsObj, err = parseJSONObject(navObj["icons"], "bottomNav.icons")
			if err != nil {
				return nil, nil, err
			}
		}
		iconsOut := map[string]any{}
		for _, slot := range []string{"home", "market", "schedule", "campus", "me"} {
			if iconsObj[slot] == nil {
				iconsOut[slot] = nil
				continue
			}
			pairObj, err := parseJSONObject(iconsObj[slot], "bottomNav.icons."+slot)
			if err != nil {
				return nil, nil, err
			}
			normalPath, err := parseAssetPath(pairObj["normal"], "bottomNav.icons."+slot+".normal", "icons", true)
			if err != nil {
				return nil, nil, err
			}
			selectedPath, err := parseAssetPath(pairObj["selected"], "bottomNav.icons."+slot+".selected", "icons", true)
			if err != nil {
				return nil, nil, err
			}
			iconsOut[slot] = map[string]any{
				"normal":   addRef(normalPath, themeAssetIcon),
				"selected": addRef(selectedPath, themeAssetIcon),
			}
		}
		navOut["icons"] = iconsOut
		out["bottomNav"] = navOut
	}

	if source["font"] != nil {
		fontObj, err := parseJSONObject(source["font"], "font")
		if err != nil {
			return nil, nil, err
		}
		fontLicenses := []string{"OFL-1.1", "Apache-2.0", "CC0-1.0", "author-owned"}
		if fontObj["regular"] == nil && fontObj["title"] == nil {
			return nil, nil, themeFieldError("font")
		}
		fontOut := map[string]any{}
		if fontObj["regular"] != nil {
			fontName, err := parseJSONText(fontObj["name"], "font.name", 1, 30, false)
			if err != nil {
				return nil, nil, err
			}
			regularPath, err := parseFontPath(fontObj["regular"], "font.regular")
			if err != nil {
				return nil, nil, err
			}
			fontLicense, err := parseJSONChoice(fontObj["license"], "font.license", fontLicenses)
			if err != nil {
				return nil, nil, err
			}
			fontOut["name"] = fontName
			fontOut["regular"] = addRef(regularPath, themeAssetFont)
			fontOut["license"] = fontLicense
			if fontObj["bold"] != nil {
				boldPath, err := parseFontPath(fontObj["bold"], "font.bold")
				if err != nil {
					return nil, nil, err
				}
				fontOut["bold"] = addRef(boldPath, themeAssetFont)
			}
		}
		if fontObj["title"] != nil {
			titleObj, err := parseJSONObject(fontObj["title"], "font.title")
			if err != nil {
				return nil, nil, err
			}
			titleName, err := parseJSONText(titleObj["name"], "font.title.name", 1, 30, false)
			if err != nil {
				return nil, nil, err
			}
			titlePath, err := parseFontPath(titleObj["regular"], "font.title.regular")
			if err != nil {
				return nil, nil, err
			}
			titleLicense, err := parseJSONChoice(titleObj["license"], "font.title.license", fontLicenses)
			if err != nil {
				return nil, nil, err
			}
			fontOut["title"] = map[string]any{
				"name":    titleName,
				"regular": addRef(titlePath, themeAssetFont),
				"license": titleLicense,
			}
		}
		out["font"] = fontOut
	}

	if source["launcherIcon"] != nil {
		launcherObj, err := parseJSONObject(source["launcherIcon"], "launcherIcon")
		if err != nil {
			return nil, nil, err
		}
		if launcherObj["builtin"] == nil && launcherObj["custom"] == nil {
			return nil, nil, themeFieldError("launcherIcon")
		}
		launcherOut := map[string]any{}
		if launcherObj["builtin"] != nil {
			b, err := parseJSONChoice(launcherObj["builtin"], "launcherIcon.builtin", []string{"default", "night", "sea", "sakura", "paper", "campus"})
			if err != nil {
				return nil, nil, err
			}
			launcherOut["builtin"] = b
		}
		if launcherObj["custom"] != nil {
			cPath, err := parseAssetPath(launcherObj["custom"], "launcherIcon.custom", "icons", true)
			if err != nil {
				return nil, nil, err
			}
			launcherOut["custom"] = addRef(cPath, themeAssetLauncher)
		}
		out["launcherIcon"] = launcherOut
	}

	if source["layout"] != nil {
		layoutObj, err := parseJSONObject(source["layout"], "layout")
		if err != nil {
			return nil, nil, err
		}
		layoutOut := map[string]any{}
		for _, slot := range []string{"home", "campus", "me"} {
			if layoutObj[slot] == nil {
				continue
			}
			hdr, err := parseHeaderLayout(layoutObj[slot], "layout."+slot)
			if err != nil {
				return nil, nil, err
			}
			layoutOut[slot] = hdr
		}
		if len(layoutOut) > 0 {
			out["layout"] = layoutOut
		}
	}

	return out, refs, nil
}

func parseVariant(raw any, field string, addRef func(string, themeAssetKind) string) (map[string]any, error) {
	v, err := parseJSONObject(raw, field)
	if err != nil {
		return nil, err
	}
	seed, err := parseJSONColor(v["seedColor"], field+".seedColor", false)
	if err != nil {
		return nil, err
	}
	schemeRaw := any("tonalSpot")
	if v["schemeVariant"] != nil {
		schemeRaw = v["schemeVariant"]
	}
	schemeVar, err := parseJSONChoice(schemeRaw, field+".schemeVariant", []string{"tonalSpot", "neutral", "vibrant", "expressive", "fidelity", "content"})
	if err != nil {
		return nil, err
	}

	tokensObj, err := parseJSONObject(v["tokens"], field+".tokens")
	if err != nil {
		return nil, err
	}
	tokensOut := make(map[string]string, len(themeTokenKeys))
	for _, key := range themeTokenKeys {
		col, err := parseJSONColor(tokensObj[key], field+".tokens."+key, themeTranslucentTokens[key])
		if err != nil {
			return nil, err
		}
		tokensOut[key] = col
	}

	courseList, err := parseJSONList(v["coursePalette"], field+".coursePalette", 5, 12)
	if err != nil {
		return nil, err
	}
	courseOut := make([]string, 0, len(courseList))
	for i, item := range courseList {
		col, err := parseJSONColor(item, fmt.Sprintf("%s.coursePalette[%d]", field, i), false)
		if err != nil {
			return nil, err
		}
		courseOut = append(courseOut, col)
	}

	out := map[string]any{
		"seedColor":     seed,
		"schemeVariant": schemeVar,
		"tokens":        tokensOut,
		"coursePalette": courseOut,
	}

	if v["wallpapers"] != nil {
		wallsObj, err := parseJSONObject(v["wallpapers"], field+".wallpapers")
		if err != nil {
			return nil, err
		}
		wallsOut := map[string]any{}
		for _, slot := range []string{"global", "home", "schedule", "me", "secondary"} {
			if wallsObj[slot] == nil {
				wallsOut[slot] = nil
				continue
			}
			wOut, err := parseWallpaper(wallsObj[slot], field+".wallpapers."+slot, addRef)
			if err != nil {
				return nil, err
			}
			wallsOut[slot] = wOut
		}
		out["wallpapers"] = wallsOut
	}

	if v["componentOpacity"] != nil {
		op, err := parseJSONNumber(v["componentOpacity"], field+".componentOpacity", 0.0, 1.0)
		if err != nil {
			return nil, err
		}
		out["componentOpacity"] = op
	}

	if v["frostedGlass"] != nil {
		frostObj, err := parseJSONObject(v["frostedGlass"], field+".frostedGlass")
		if err != nil {
			return nil, err
		}
		enabled, ok := frostObj["enabled"].(bool)
		if !ok {
			return nil, themeFieldError(field + ".frostedGlass.enabled")
		}
		strength, err := parseJSONNumber(frostObj["strength"], field+".frostedGlass.strength", 0, 1)
		if err != nil {
			return nil, err
		}
		out["frostedGlass"] = map[string]any{
			"enabled":  enabled,
			"strength": strength,
		}
	}

	if v["cardStyle"] != nil {
		csObj, err := parseJSONObject(v["cardStyle"], field+".cardStyle")
		if err != nil {
			return nil, err
		}
		csOut := map[string]any{}
		if csObj["borderWidth"] != nil {
			bw, err := parseJSONNumber(csObj["borderWidth"], field+".cardStyle.borderWidth", 0, 2)
			if err != nil {
				return nil, err
			}
			csOut["borderWidth"] = bw
		}
		if csObj["shadow"] != nil {
			sh, err := parseJSONChoice(csObj["shadow"], field+".cardStyle.shadow", []string{"none", "soft", "medium"})
			if err != nil {
				return nil, err
			}
			csOut["shadow"] = sh
		}
		if csObj["fill"] != nil {
			fill, err := parseJSONChoice(csObj["fill"], field+".cardStyle.fill", []string{"solid", "tint", "glass"})
			if err != nil {
				return nil, err
			}
			csOut["fill"] = fill
		}
		if len(csOut) > 0 {
			out["cardStyle"] = csOut
		}
	}

	if v["identityHarmony"] != nil {
		harmony, err := parseJSONNumber(v["identityHarmony"], field+".identityHarmony", 0, 1)
		if err != nil {
			return nil, err
		}
		out["identityHarmony"] = harmony
	}
	if v["backdrop"] != nil {
		backdrop, err := parseBackdrop(v["backdrop"], field+".backdrop", addRef)
		if err != nil {
			return nil, err
		}
		out["backdrop"] = backdrop
	}
	if v["sectionMark"] != nil {
		markObj, err := parseJSONObject(v["sectionMark"], field+".sectionMark")
		if err != nil {
			return nil, err
		}
		style, err := parseJSONChoice(markObj["style"], field+".sectionMark.style", []string{"none", "dot", "bar", "icon"})
		if err != nil {
			return nil, err
		}
		if style == "icon" && markObj["image"] == nil {
			return nil, themeFieldError(field + ".sectionMark.image")
		}
		markOut := map[string]any{"style": style}
		if markObj["image"] != nil {
			img, err := parseAssetPath(markObj["image"], field+".sectionMark.image", "decorations", true)
			if err != nil {
				return nil, err
			}
			markOut["image"] = addRef(img, themeAssetSticker)
		}
		out["sectionMark"] = markOut
	}
	if v["illustrations"] != nil {
		illObj, err := parseJSONObject(v["illustrations"], field+".illustrations")
		if err != nil {
			return nil, err
		}
		illOut := map[string]any{}
		for _, key := range []string{"empty", "error"} {
			if illObj[key] == nil {
				continue
			}
			img, err := parseAssetPath(illObj[key], field+".illustrations."+key, "decorations", true)
			if err != nil {
				return nil, err
			}
			illOut[key] = addRef(img, themeAssetIllustration)
		}
		out["illustrations"] = illOut
	}
	if v["ornaments"] != nil {
		ornObj, err := parseJSONObject(v["ornaments"], field+".ornaments")
		if err != nil {
			return nil, err
		}
		ornOut := map[string]any{}
		for _, key := range themeOrnamentSlots {
			if ornObj[key] == nil {
				continue
			}
			f := field + ".ornaments." + key
			o, err := parseJSONObject(ornObj[key], f)
			if err != nil {
				return nil, err
			}
			img, err := parseAssetPath(o["image"], f+".image", "decorations", true)
			if err != nil {
				return nil, err
			}
			corner := o["corner"]
			if corner == nil {
				corner = "topRight"
			}
			cornerVal, err := parseJSONChoice(corner, f+".corner", []string{"topLeft", "topRight", "bottomLeft", "bottomRight"})
			if err != nil {
				return nil, err
			}
			width, err := parseJSONNumber(o["width"], f+".width", 24, 160)
			if err != nil {
				return nil, err
			}
			dx, err := parseJSONNumberDefault(o["dx"], 0, f+".dx", -64, 240)
			if err != nil {
				return nil, err
			}
			dy, err := parseJSONNumberDefault(o["dy"], 0, f+".dy", -96, 96)
			if err != nil {
				return nil, err
			}
			opacity, err := parseJSONNumberDefault(o["opacity"], 1, f+".opacity", 0, 1)
			if err != nil {
				return nil, err
			}
			ornOut[key] = map[string]any{
				"image": addRef(img, themeAssetSticker), "corner": cornerVal,
				"width": width, "dx": dx, "dy": dy, "opacity": opacity,
			}
		}
		out["ornaments"] = ornOut
	}
	if v["cardArt"] != nil {
		f := field + ".cardArt"
		artObj, err := parseJSONObject(v["cardArt"], f)
		if err != nil {
			return nil, err
		}
		img, err := parseAssetPath(artObj["image"], f+".image", "decorations", true)
		if err != nil {
			return nil, err
		}
		align := artObj["alignment"]
		if align == nil {
			align = "bottomRight"
		}
		alignVal, err := parseJSONChoice(align, f+".alignment", []string{"bottomRight", "bottomLeft", "topRight", "topLeft"})
		if err != nil {
			return nil, err
		}
		width, err := parseJSONNumberDefault(artObj["width"], 0.42, f+".width", 0.2, 0.7)
		if err != nil {
			return nil, err
		}
		opacity, err := parseJSONNumberDefault(artObj["opacity"], 0.14, f+".opacity", 0.04, 0.4)
		if err != nil {
			return nil, err
		}
		out["cardArt"] = map[string]any{
			"image": addRef(img, themeAssetIllustration), "alignment": alignVal,
			"width": width, "opacity": opacity,
		}
	}
	if v["serviceIcons"] != nil {
		iconObj, err := parseJSONObject(v["serviceIcons"], field+".serviceIcons")
		if err != nil {
			return nil, err
		}
		iconOut := map[string]any{}
		for _, key := range themeServiceIconKeys {
			if iconObj[key] == nil {
				continue
			}
			img, err := parseAssetPath(iconObj[key], field+".serviceIcons."+key, "icons", true)
			if err != nil {
				return nil, err
			}
			iconOut[key] = addRef(img, themeAssetIcon)
		}
		out["serviceIcons"] = iconOut
	}

	if v["decorations"] != nil {
		decosObj, err := parseJSONObject(v["decorations"], field+".decorations")
		if err != nil {
			return nil, err
		}
		decosOut := map[string]any{}
		for _, slot := range []string{"home", "campus", "me"} {
			if decosObj[slot] == nil {
				decosOut[slot] = nil
				continue
			}
			dOut, err := parseHeaderDecoration(decosObj[slot], field+".decorations."+slot, addRef)
			if err != nil {
				return nil, err
			}
			decosOut[slot] = dOut
		}
		out["decorations"] = decosOut
	}

	return out, nil
}

// parseBackdrop 校验氛围背景：2–4 色渐变、最多 3 个光斑、可选平铺纹理，至少提供一项。
func parseBackdrop(raw any, field string, addRef func(string, themeAssetKind) string) (map[string]any, error) {
	obj, err := parseJSONObject(raw, field)
	if err != nil {
		return nil, err
	}
	out := map[string]any{}
	if obj["gradient"] != nil {
		gObj, err := parseJSONObject(obj["gradient"], field+".gradient")
		if err != nil {
			return nil, err
		}
		stops, err := parseJSONList(gObj["colors"], field+".gradient.colors", 2, 4)
		if err != nil {
			return nil, err
		}
		colors := make([]any, 0, len(stops))
		for i, c := range stops {
			hex, err := parseJSONColor(c, fmt.Sprintf("%s.gradient.colors[%d]", field, i), false)
			if err != nil {
				return nil, err
			}
			colors = append(colors, hex)
		}
		angle, err := parseJSONNumberDefault(gObj["angle"], 180, field+".gradient.angle", 0, 360)
		if err != nil {
			return nil, err
		}
		out["gradient"] = map[string]any{"colors": colors, "angle": angle}
	}
	glowsRaw := obj["glow"]
	if glowsRaw == nil {
		glowsRaw = []any{}
	}
	glows, err := parseJSONList(glowsRaw, field+".glow", 0, 3)
	if err != nil {
		return nil, err
	}
	glowOut := make([]any, 0, len(glows))
	for i, g := range glows {
		gf := fmt.Sprintf("%s.glow[%d]", field, i)
		gObj, err := parseJSONObject(g, gf)
		if err != nil {
			return nil, err
		}
		hex, err := parseJSONColor(gObj["color"], gf+".color", false)
		if err != nil {
			return nil, err
		}
		x, err := parseJSONNumber(gObj["x"], gf+".x", 0, 1)
		if err != nil {
			return nil, err
		}
		y, err := parseJSONNumber(gObj["y"], gf+".y", 0, 1)
		if err != nil {
			return nil, err
		}
		radius, err := parseJSONNumberDefault(gObj["radius"], .5, gf+".radius", .1, 1.5)
		if err != nil {
			return nil, err
		}
		opacity, err := parseJSONNumberDefault(gObj["opacity"], .6, gf+".opacity", 0, 1)
		if err != nil {
			return nil, err
		}
		glowOut = append(glowOut, map[string]any{"color": hex, "x": x, "y": y, "radius": radius, "opacity": opacity})
	}
	out["glow"] = glowOut
	if obj["pattern"] != nil {
		pObj, err := parseJSONObject(obj["pattern"], field+".pattern")
		if err != nil {
			return nil, err
		}
		tile, err := parseAssetPath(pObj["tile"], field+".pattern.tile", "decorations", true)
		if err != nil {
			return nil, err
		}
		opacity, err := parseJSONNumberDefault(pObj["opacity"], .2, field+".pattern.opacity", 0, 1)
		if err != nil {
			return nil, err
		}
		scale, err := parseJSONNumberDefault(pObj["scale"], 1, field+".pattern.scale", .5, 2)
		if err != nil {
			return nil, err
		}
		out["pattern"] = map[string]any{"tile": addRef(tile, themeAssetSticker), "opacity": opacity, "scale": scale}
	}
	if out["gradient"] == nil && len(glowOut) == 0 && out["pattern"] == nil {
		return nil, themeFieldError(field)
	}
	return out, nil
}

func parseWallpaper(raw any, field string, addRef func(string, themeAssetKind) string) (map[string]any, error) {
	v, err := parseJSONObject(raw, field)
	if err != nil {
		return nil, err
	}
	portrait, err := parseAssetPath(v["portrait"], field+".portrait", "wallpaper", false)
	if err != nil {
		return nil, err
	}
	settings, err := parseImageSettings(v, field)
	if err != nil {
		return nil, err
	}
	settings["portrait"] = addRef(portrait, themeAssetWallpaper)
	if v["landscape"] != nil {
		landscape, err := parseAssetPath(v["landscape"], field+".landscape", "wallpaper", false)
		if err != nil {
			return nil, err
		}
		settings["landscape"] = addRef(landscape, themeAssetWallpaper)
	}
	return settings, nil
}

func parseImageSettings(v map[string]any, field string) (map[string]any, error) {
	fitRaw := any("cover")
	if v["fit"] != nil {
		fitRaw = v["fit"]
	}
	fit, err := parseJSONChoice(fitRaw, field+".fit", []string{"cover", "contain"})
	if err != nil {
		return nil, err
	}
	focalX, err := parseJSONNumberDefault(v["focalX"], 0.5, field+".focalX", 0, 1)
	if err != nil {
		return nil, err
	}
	focalY, err := parseJSONNumberDefault(v["focalY"], 0.5, field+".focalY", 0, 1)
	if err != nil {
		return nil, err
	}
	blurVal, err := parseJSONNumberDefault(v["blur"], 0, field+".blur", 0, 20)
	if err != nil {
		return nil, err
	}
	scrimVal, err := parseJSONNumberDefault(v["scrim"], 0, field+".scrim", 0, 0.6)
	if err != nil {
		return nil, err
	}
	out := map[string]any{
		"fit":    fit,
		"focalX": focalX,
		"focalY": focalY,
		"blur":   blurVal,
		"scrim":  scrimVal,
	}
	if v["adjustments"] != nil {
		adjObj, err := parseJSONObject(v["adjustments"], field+".adjustments")
		if err != nil {
			return nil, err
		}
		br, err := parseJSONNumberDefault(adjObj["brightness"], 0, field+".adjustments.brightness", -100, 100)
		if err != nil {
			return nil, err
		}
		ct, err := parseJSONNumberDefault(adjObj["contrast"], 100, field+".adjustments.contrast", 0, 200)
		if err != nil {
			return nil, err
		}
		st, err := parseJSONNumberDefault(adjObj["saturation"], 100, field+".adjustments.saturation", 0, 200)
		if err != nil {
			return nil, err
		}
		out["adjustments"] = map[string]any{
			"brightness": br,
			"contrast":   ct,
			"saturation": st,
		}
	}
	return out, nil
}

func parseHeaderLayout(raw any, field string) (map[string]any, error) {
	v, err := parseJSONObject(raw, field)
	if err != nil {
		return nil, err
	}
	presetRaw := any("standard")
	if v["preset"] != nil {
		presetRaw = v["preset"]
	}
	preset, err := parseJSONChoice(presetRaw, field+".preset", []string{"standard", "compact", "immersive"})
	if err != nil {
		return nil, err
	}
	alignRaw := any("start")
	if v["alignment"] != nil {
		alignRaw = v["alignment"]
	}
	alignment, err := parseJSONChoice(alignRaw, field+".alignment", []string{"start", "center", "end"})
	if err != nil {
		return nil, err
	}
	imgH, err := parseJSONNumberDefault(v["imageHeight"], 150, field+".imageHeight", 96, 280)
	if err != nil {
		return nil, err
	}
	imgW, err := parseJSONNumberDefault(v["imageWidth"], 1.0, field+".imageWidth", 0.45, 1.0)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"preset":      preset,
		"alignment":   alignment,
		"imageHeight": imgH,
		"imageWidth":  imgW,
	}, nil
}

func parseHeaderDecoration(raw any, field string, addRef func(string, themeAssetKind) string) (map[string]any, error) {
	v, err := parseJSONObject(raw, field)
	if err != nil {
		return nil, err
	}
	out := map[string]any{}
	if v["background"] != nil {
		bgObj, err := parseJSONObject(v["background"], field+".background")
		if err != nil {
			return nil, err
		}
		bgImg, err := parseAssetPath(bgObj["image"], field+".background.image", "decorations", false)
		if err != nil {
			return nil, err
		}
		settings, err := parseImageSettings(bgObj, field+".background")
		if err != nil {
			return nil, err
		}
		settings["image"] = addRef(bgImg, themeAssetHeader)
		out["background"] = settings
	}
	stickersRaw := any([]any{})
	if v["stickers"] != nil {
		stickersRaw = v["stickers"]
	}
	stickerList, err := parseJSONList(stickersRaw, field+".stickers", 0, 5)
	if err != nil {
		return nil, err
	}
	stickersOut := make([]map[string]any, 0, len(stickerList))
	for i, item := range stickerList {
		sf := fmt.Sprintf("%s.stickers[%d]", field, i)
		sObj, err := parseJSONObject(item, sf)
		if err != nil {
			return nil, err
		}
		imgPath, err := parseAssetPath(sObj["image"], sf+".image", "decorations", true)
		if err != nil {
			return nil, err
		}
		xVal, err := parseJSONNumber(sObj["x"], sf+".x", 0, 1)
		if err != nil {
			return nil, err
		}
		yVal, err := parseJSONNumber(sObj["y"], sf+".y", 0, 1)
		if err != nil {
			return nil, err
		}
		wVal, err := parseJSONNumber(sObj["width"], sf+".width", 0.08, 0.40)
		if err != nil {
			return nil, err
		}
		rotVal, err := parseJSONNumberDefault(sObj["rotation"], 0, sf+".rotation", -180, 180)
		if err != nil {
			return nil, err
		}
		stickersOut = append(stickersOut, map[string]any{
			"image":    addRef(imgPath, themeAssetSticker),
			"x":        xVal,
			"y":        yVal,
			"width":    wVal,
			"rotation": rotVal,
		})
	}
	out["stickers"] = stickersOut
	return out, nil
}

func rewriteManifestAssetPaths(manifest map[string]any, mapping map[string]string) {
	preview := manifest["preview"].(map[string]any)
	preview["light"] = mapping[string(themeAssetPreview)+":"+preview["light"].(string)]
	preview["dark"] = mapping[string(themeAssetPreview)+":"+preview["dark"].(string)]

	for _, mode := range []string{"light", "dark"} {
		variant := manifest[mode].(map[string]any)
		if walls, ok := variant["wallpapers"].(map[string]any); ok {
			for _, wRaw := range walls {
				if wMap, ok := wRaw.(map[string]any); ok && wMap != nil {
					wMap["portrait"] = mapping[string(themeAssetWallpaper)+":"+wMap["portrait"].(string)]
					if l, hasL := wMap["landscape"].(string); hasL {
						wMap["landscape"] = mapping[string(themeAssetWallpaper)+":"+l]
					}
				}
			}
		}
		if backdrop, ok := variant["backdrop"].(map[string]any); ok {
			if pattern, ok := backdrop["pattern"].(map[string]any); ok {
				pattern["tile"] = mapping[string(themeAssetSticker)+":"+pattern["tile"].(string)]
			}
		}
		if mark, ok := variant["sectionMark"].(map[string]any); ok {
			if img, has := mark["image"].(string); has {
				mark["image"] = mapping[string(themeAssetSticker)+":"+img]
			}
		}
		if ills, ok := variant["illustrations"].(map[string]any); ok {
			for key, img := range ills {
				ills[key] = mapping[string(themeAssetIllustration)+":"+img.(string)]
			}
		}
		if orns, ok := variant["ornaments"].(map[string]any); ok {
			for _, o := range orns {
				orn := o.(map[string]any)
				orn["image"] = mapping[string(themeAssetSticker)+":"+orn["image"].(string)]
			}
		}
		if art, ok := variant["cardArt"].(map[string]any); ok {
			art["image"] = mapping[string(themeAssetIllustration)+":"+art["image"].(string)]
		}
		if icons, ok := variant["serviceIcons"].(map[string]any); ok {
			for key, img := range icons {
				icons[key] = mapping[string(themeAssetIcon)+":"+img.(string)]
			}
		}
		if decos, ok := variant["decorations"].(map[string]any); ok {
			for _, dRaw := range decos {
				if dMap, ok := dRaw.(map[string]any); ok && dMap != nil {
					if bgMap, ok := dMap["background"].(map[string]any); ok && bgMap != nil {
						bgMap["image"] = mapping[string(themeAssetHeader)+":"+bgMap["image"].(string)]
					}
					if stickers, ok := dMap["stickers"].([]map[string]any); ok {
						for _, st := range stickers {
							st["image"] = mapping[string(themeAssetSticker)+":"+st["image"].(string)]
						}
					}
				}
			}
		}
	}
	if nav, ok := manifest["bottomNav"].(map[string]any); ok {
		if icons, ok := nav["icons"].(map[string]any); ok {
			for _, pairRaw := range icons {
				if pair, ok := pairRaw.(map[string]any); ok && pair != nil {
					pair["normal"] = mapping[string(themeAssetIcon)+":"+pair["normal"].(string)]
					pair["selected"] = mapping[string(themeAssetIcon)+":"+pair["selected"].(string)]
				}
			}
		}
	}
	if font, ok := manifest["font"].(map[string]any); ok {
		if regular, hasRegular := font["regular"].(string); hasRegular {
			font["regular"] = mapping[string(themeAssetFont)+":"+regular]
		}
		if title, hasTitle := font["title"].(map[string]any); hasTitle {
			title["regular"] = mapping[string(themeAssetFont)+":"+title["regular"].(string)]
		}
		if bold, hasBold := font["bold"].(string); hasBold {
			font["bold"] = mapping[string(themeAssetFont)+":"+bold]
		}
	}
	if launcher, ok := manifest["launcherIcon"].(map[string]any); ok {
		if custom, hasCustom := launcher["custom"].(string); hasCustom {
			launcher["custom"] = mapping[string(themeAssetLauncher)+":"+custom]
		}
	}
}

type argbColor struct {
	a, r, g, b float64
}

func parseHexARGB(hexStr string) argbColor {
	s := strings.TrimPrefix(hexStr, "#")
	if len(s) == 6 {
		s = "FF" + s
	}
	v, _ := strconv.ParseUint(s, 16, 32)
	return argbColor{
		a: float64((v>>24)&0xFF) / 255.0,
		r: float64((v>>16)&0xFF) / 255.0,
		g: float64((v>>8)&0xFF) / 255.0,
		b: float64(v&0xFF) / 255.0,
	}
}

func alphaBlend(fg, bg argbColor) argbColor {
	outA := fg.a + bg.a*(1-fg.a)
	if outA <= 0 {
		return argbColor{}
	}
	return argbColor{
		a: outA,
		r: (fg.r*fg.a + bg.r*bg.a*(1-fg.a)) / outA,
		g: (fg.g*fg.a + bg.g*bg.a*(1-fg.a)) / outA,
		b: (fg.b*fg.a + bg.b*bg.a*(1-fg.a)) / outA,
	}
}

func linearizeChannel(c float64) float64 {
	if c <= 0.03928 {
		return c / 12.92
	}
	return math.Pow((c+0.055)/1.055, 2.4)
}

func relativeLuminance(c argbColor) float64 {
	return 0.2126*linearizeChannel(c.r) + 0.7152*linearizeChannel(c.g) + 0.0722*linearizeChannel(c.b)
}

func contrastRatio(fg, bg argbColor) float64 {
	la := relativeLuminance(fg)
	lb := relativeLuminance(bg)
	if la < lb {
		la, lb = lb, la
	}
	return (la + 0.05) / (lb + 0.05)
}

func checkManifestContrast(manifest map[string]any) error {
	type pairRule struct {
		fg  string
		bg  string
		min float64
	}
	rules := []pairRule{
		{"textPrimary", "background", 4.5},
		{"textPrimary", "card", 4.5},
		{"textSecondary", "card", 4.5},
		{"onPrimary", "primary", 4.5},
		{"tagText", "tagBackground", 4.5},
		{"appBarForeground", "appBarBackground", 4.5},
		{"bubbleOutgoingText", "bubbleOutgoing", 4.5},
		{"navSelected", "navBackground", 3.0},
		{"navUnselected", "navBackground", 3.0},
	}

	for _, mode := range []string{"light", "dark"} {
		variant := manifest[mode].(map[string]any)
		tokens := variant["tokens"].(map[string]string)
		pageBg := parseHexARGB(tokens["background"])

		for _, rule := range rules {
			base := alphaBlend(parseHexARGB(tokens[rule.bg]), pageBg)
			front := alphaBlend(parseHexARGB(tokens[rule.fg]), base)
			if contrastRatio(front, base) < rule.min {
				field := fmt.Sprintf("%s.tokens.%s", mode, rule.fg)
				return newThemeError(
					http.StatusBadRequest,
					ThemeCodeContrastLow,
					field,
					fmt.Sprintf("文字与背景对比度不足：%s / %s", rule.fg, rule.bg),
				)
			}
		}

		courseText := parseHexARGB(tokens["courseCardText"])
		coursePalette := variant["coursePalette"].([]string)
		for i, cHex := range coursePalette {
			c := parseHexARGB(cHex)
			c.a = 0.45
			base := alphaBlend(c, pageBg)
			front := alphaBlend(courseText, base)
			if contrastRatio(front, base) < 4.5 {
				field := fmt.Sprintf("%s.coursePalette[%d]", mode, i)
				return newThemeError(
					http.StatusBadRequest,
					ThemeCodeContrastLow,
					field,
					fmt.Sprintf("文字与背景对比度不足：courseCardText / coursePalette[%d]", i),
				)
			}
		}
	}
	return nil
}

func detectThemeImageFormat(data []byte) (string, bool) {
	if len(data) >= 8 && bytes.Equal(data[:8], []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}) {
		return "png", false
	}
	if len(data) >= 3 && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff {
		return "jpeg", false
	}
	if len(data) >= 16 && bytes.Equal(data[:4], []byte("RIFF")) && bytes.Equal(data[8:12], []byte("WEBP")) {
		animated := false
		if len(data) >= 21 && bytes.Equal(data[12:16], []byte("VP8X")) && data[20]&0x02 != 0 {
			animated = true
		}
		if bytes.Contains(data, []byte("ANIM")) || bytes.Contains(data, []byte("ANMF")) {
			animated = true
		}
		return "webp", animated
	}
	return "", false
}

func validateAndNormalizeThemeImage(data []byte, kind themeAssetKind, assetPath string) ([]byte, string, error) {
	imgErr := func() error {
		return newThemeError(http.StatusBadRequest, ThemeCodeImageInvalid, assetPath, fmt.Sprintf("主题图片不符合要求：%s", assetPath))
	}
	if len(data) == 0 {
		return nil, "", imgErr()
	}

	var maxBytes int64
	allowJPEG := false
	switch kind {
	case themeAssetWallpaper:
		maxBytes = 8 * 1024 * 1024
		allowJPEG = true
	case themeAssetPreview:
		maxBytes = 2 * 1024 * 1024
		allowJPEG = true
	case themeAssetHeader:
		maxBytes = 2 * 1024 * 1024
		allowJPEG = true
	case themeAssetLauncher:
		maxBytes = 1 * 1024 * 1024
	case themeAssetSticker:
		maxBytes = 512 * 1024
	case themeAssetIllustration:
		maxBytes = 1024 * 1024
	case themeAssetIcon:
		maxBytes = 256 * 1024
	default:
		return nil, "", imgErr()
	}

	if int64(len(data)) > maxBytes {
		return nil, "", imgErr()
	}
	format, animated := detectThemeImageFormat(data)
	if format == "" || animated || (format == "jpeg" && !allowJPEG) {
		return nil, "", imgErr()
	}

	// 先读取图片头部尺寸，超限直接拒绝，不做完整像素解码。
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || cfg.Width < 1 || cfg.Height < 1 {
		return nil, "", imgErr()
	}
	maxSide := cfg.Width
	if cfg.Height > maxSide {
		maxSide = cfg.Height
	}
	switch kind {
	case themeAssetPreview:
		if cfg.Width != 1080 || cfg.Height != 2340 {
			return nil, "", imgErr()
		}
	case themeAssetWallpaper:
		if maxSide > 4096 {
			return nil, "", imgErr()
		}
	case themeAssetHeader:
		if maxSide < 1200 || maxSide > 2048 {
			return nil, "", imgErr()
		}
	case themeAssetSticker, themeAssetIllustration:
		if maxSide > 1024 {
			return nil, "", imgErr()
		}
	case themeAssetIcon:
		if cfg.Width != cfg.Height || cfg.Width < 48 || cfg.Width > 256 {
			return nil, "", imgErr()
		}
	case themeAssetLauncher:
		if cfg.Width != cfg.Height || cfg.Width < 432 || cfg.Width > 1024 {
			return nil, "", imgErr()
		}
	}

	decoded, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, "", imgErr()
	}
	bounds := decoded.Bounds()
	if bounds.Dx() != cfg.Width || bounds.Dy() != cfg.Height {
		return nil, "", imgErr()
	}

	if kind == themeAssetLauncher {
		for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
			for x := bounds.Min.X; x < bounds.Max.X; x++ {
				if _, _, _, a := decoded.At(x, y).RGBA(); a != 0xffff {
					return nil, "", imgErr()
				}
			}
		}
	}

	var out bytes.Buffer
	switch kind {
	case themeAssetWallpaper, themeAssetPreview, themeAssetHeader:
		dst := image.NewRGBA(image.Rect(0, 0, bounds.Dx(), bounds.Dy()))
		draw.Draw(dst, dst.Bounds(), &image.Uniform{C: color.Black}, image.Point{}, draw.Src)
		draw.Draw(dst, dst.Bounds(), decoded, bounds.Min, draw.Over)
		if err := jpeg.Encode(&out, dst, &jpeg.Options{Quality: 88}); err != nil {
			return nil, "", imgErr()
		}
		return out.Bytes(), ".jpg", nil
	default:
		dst := image.NewNRGBA(image.Rect(0, 0, bounds.Dx(), bounds.Dy()))
		draw.Draw(dst, dst.Bounds(), decoded, bounds.Min, draw.Src)
		if err := png.Encode(&out, dst); err != nil {
			return nil, "", imgErr()
		}
		return out.Bytes(), ".png", nil
	}
}

func validateThemeFont(data []byte, assetPath string) (string, string, error) {
	if len(data) == 0 {
		return "", "", newThemeError(http.StatusBadRequest, ThemeCodeFontInvalid, assetPath, "主题字体无法使用")
	}
	if int64(len(data)) > ThemePackMaxFontBytes {
		return "", "", newThemeError(http.StatusRequestEntityTooLarge, ThemeCodeTooLarge, assetPath, "主题文件过大")
	}
	if len(data) >= 4 && bytes.Equal(data[:4], []byte("ttcf")) {
		return "", "", newThemeError(http.StatusBadRequest, ThemeCodeFontInvalid, assetPath, "主题字体无法使用")
	}
	f, err := sfnt.Parse(data)
	if err != nil {
		return "", "", newThemeError(http.StatusBadRequest, ThemeCodeFontInvalid, assetPath, "主题字体无法使用")
	}
	var buf sfnt.Buffer
	for r := rune(0x20); r <= 0x7E; r++ {
		idx, err := f.GlyphIndex(&buf, r)
		if err != nil || idx == 0 {
			return "", "", newThemeError(http.StatusBadRequest, ThemeCodeFontCoverageLow, assetPath, "字体缺少可打印 ASCII 字符")
		}
	}
	runes := loadGB2312Level1Runes()
	covered := 0
	for _, r := range runes {
		idx, err := f.GlyphIndex(&buf, r)
		if err == nil && idx != 0 {
			covered++
		}
	}
	ratio := float64(covered) / float64(len(runes))
	if ratio < 0.99 {
		return "", "", newThemeError(
			http.StatusBadRequest,
			ThemeCodeFontCoverageLow,
			assetPath,
			fmt.Sprintf("字体缺少常用汉字，覆盖率 %.1f%%", ratio*100),
		)
	}

	readName := func(id sfnt.NameID, maxRunes int) string {
		val, err := f.Name(&buf, id)
		if err != nil {
			return ""
		}
		val = strings.TrimSpace(strings.ReplaceAll(val, "\x00", ""))
		if utf8.RuneCountInString(val) > maxRunes {
			rs := []rune(val)
			return string(rs[:maxRunes])
		}
		return val
	}
	return readName(sfnt.NameIDCopyright, 1000), readName(sfnt.NameIDLicense, 2000), nil
}

func parseJSONObject(v any, field string) (map[string]any, error) {
	m, ok := v.(map[string]any)
	if !ok || m == nil {
		return nil, themeFieldError(field)
	}
	return m, nil
}

func parseJSONList(v any, field string, minLen, maxLen int) ([]any, error) {
	l, ok := v.([]any)
	if !ok || len(l) < minLen || len(l) > maxLen {
		return nil, themeFieldError(field)
	}
	return l, nil
}

func parseJSONInt(v any) (int, bool) {
	switch n := v.(type) {
	case json.Number:
		s := n.String()
		if strings.ContainsAny(s, ".eE") {
			return 0, false
		}
		iv, err := strconv.Atoi(s)
		return iv, err == nil
	case int:
		return n, true
	case int64:
		return int(n), true
	case float64:
		if math.Trunc(n) != n || math.IsNaN(n) || math.IsInf(n, 0) {
			return 0, false
		}
		return int(n), true
	default:
		return 0, false
	}
}

func parseJSONNumber(v any, field string, minVal, maxVal float64) (float64, error) {
	var f float64
	switch n := v.(type) {
	case json.Number:
		parsed, err := strconv.ParseFloat(n.String(), 64)
		if err != nil {
			return 0, themeFieldError(field)
		}
		f = parsed
	case float64:
		f = n
	case int:
		f = float64(n)
	case int64:
		f = float64(n)
	default:
		return 0, themeFieldError(field)
	}
	if math.IsNaN(f) || math.IsInf(f, 0) || f < minVal || f > maxVal {
		return 0, themeFieldError(field)
	}
	return f, nil
}

func parseJSONNumberDefault(v any, def float64, field string, minVal, maxVal float64) (float64, error) {
	if v == nil {
		return def, nil
	}
	return parseJSONNumber(v, field, minVal, maxVal)
}

func parseJSONText(v any, field string, minRunes, maxRunes int, multiline bool) (string, error) {
	s, ok := v.(string)
	if !ok {
		return "", themeFieldError(field)
	}
	rc := utf8.RuneCountInString(s)
	if rc < minRunes || rc > maxRunes {
		return "", themeFieldError(field)
	}
	if !multiline && strings.ContainsAny(s, "\r\n") {
		return "", themeFieldError(field)
	}
	return s, nil
}

func parseJSONChoice(v any, field string, allowed []string) (string, error) {
	s, ok := v.(string)
	if !ok {
		return "", themeFieldError(field)
	}
	for _, a := range allowed {
		if s == a {
			return s, nil
		}
	}
	return "", themeFieldError(field)
}

func parseJSONColor(v any, field string, allowAlpha bool) (string, error) {
	s, ok := v.(string)
	if !ok {
		return "", themeFieldError(field)
	}
	re := themeOpaqueHexPattern
	if allowAlpha {
		re = themeAlphaHexPattern
	}
	if !re.MatchString(s) {
		return "", themeFieldError(field)
	}
	return strings.ToUpper(s), nil
}

func parseAssetPath(v any, field, folder string, transparentOnly bool) (string, error) {
	s, ok := v.(string)
	if !ok {
		return "", themeFieldError(field)
	}
	var re *regexp.Regexp
	if transparentOnly {
		re = themeAlphaImgPathExpr[folder]
	} else {
		re = themeOpaqueImgPathExpr[folder]
	}
	if re == nil || !re.MatchString(s) {
		return "", themeFieldError(field)
	}
	return s, nil
}

func parseFontPath(v any, field string) (string, error) {
	s, ok := v.(string)
	if !ok || !themeFontPathPattern.MatchString(s) {
		return "", themeFieldError(field)
	}
	return s, nil
}

func compareSemver(a, b string) int {
	pa := strings.Split(a, ".")
	pb := strings.Split(b, ".")
	for i := 0; i < 3; i++ {
		na, _ := strconv.ParseInt(pa[i], 10, 64)
		nb, _ := strconv.ParseInt(pb[i], 10, 64)
		if na < nb {
			return -1
		}
		if na > nb {
			return 1
		}
	}
	return 0
}

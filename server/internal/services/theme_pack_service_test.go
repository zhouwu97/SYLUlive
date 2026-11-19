package services

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"unicode/utf16"

	"shenliyuan/internal/models"

	"github.com/glebarez/sqlite"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"golang.org/x/image/font/sfnt"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

type testAssetSpec struct {
	Width   int
	Height  int
	Format  string // "png" (默认), "jpeg_exif_xmp", "webp"
	Color   color.NRGBA
	RawData []byte
}

func defaultValidVariant(dark bool) map[string]any {
	if dark {
		return map[string]any{
			"seedColor":     "#7ED6C5",
			"schemeVariant": "tonalSpot",
			"tokens": map[string]any{
				"primary":             "#7ED6C5",
				"onPrimary":           "#0F2622",
				"primaryContainer":    "#162B28",
				"onPrimaryContainer":  "#7ED6C5",
				"background":          "#111315",
				"surface":             "#1A1D1F",
				"surfaceElevated":     "#232729",
				"surfaceMuted":        "#24282A",
				"card":                "#1A1D1F",
				"cardBorder":          "#303638",
				"textPrimary":         "#F2F4F3",
				"textSecondary":       "#A7AFAB",
				"textTertiary":        "#8E9894",
				"textDisabled":        "#5A615D",
				"divider":             "#252A2C",
				"outline":             "#303638",
				"inputFill":           "#24282A",
				"inputFillFocused":    "#2B3033",
				"searchFill":          "#24282A",
				"tagBackground":       "#282D30",
				"tagText":             "#90D5C7",
				"navBackground":       "#B8252A32",
				"navSelected":         "#84BAFF",
				"navUnselected":       "#D1D5DB",
				"appBarBackground":    "#0E1513",
				"appBarForeground":    "#DDE4E1",
				"bubbleIncoming":      "#262A2C",
				"bubbleIncomingText":  "#F2F4F3",
				"bubbleOutgoing":      "#80C4FC",
				"bubbleOutgoingText":  "#111315",
				"feedSectionSurface":  "#162B28",
				"feedFeaturedSurface": "#3A2A18",
				"feedFeaturedText":    "#F2B15A",
				"courseCardText":      "#FFFFFF",
				"timetableGrid":       "#33FFFFFF",
				"timetableToday":      "#00000000",
			},
			"coursePalette": []any{"#2E62A6", "#1F7A4C", "#6E3A88", "#A43A3A", "#995C14"},
		}
	}
	return map[string]any{
		"seedColor":     "#147C72",
		"schemeVariant": "tonalSpot",
		"tokens": map[string]any{
			"primary":             "#147C72",
			"onPrimary":           "#FFFFFF",
			"primaryContainer":    "#EAF6F3",
			"onPrimaryContainer":  "#0F635B",
			"background":          "#FFFAF4",
			"surface":             "#FFFFFF",
			"surfaceElevated":     "#FFFFFF",
			"surfaceMuted":        "#F2F3F1",
			"card":                "#FFFFFF",
			"cardBorder":          "#E2EFEA",
			"textPrimary":         "#1F2328",
			"textSecondary":       "#6E757C",
			"textTertiary":        "#9AA1A1",
			"textDisabled":        "#B8BDBA",
			"divider":             "#E8EEE9",
			"outline":             "#E2EFEA",
			"inputFill":           "#F2F3F1",
			"inputFillFocused":    "#EFF4F1",
			"searchFill":          "#F1F2F0",
			"tagBackground":       "#EEF2F0",
			"tagText":             "#0F635B",
			"navBackground":       "#9EEDF0F5",
			"navSelected":         "#1765DA",
			"navUnselected":       "#4B525E",
			"appBarBackground":    "#F4FBF8",
			"appBarForeground":    "#161D1C",
			"bubbleIncoming":      "#F0F1EF",
			"bubbleIncomingText":  "#1F2328",
			"bubbleOutgoing":      "#76C4FF",
			"bubbleOutgoingText":  "#1F2328",
			"feedSectionSurface":  "#E8F5F1",
			"feedFeaturedSurface": "#FFF3E0",
			"feedFeaturedText":    "#D97706",
			"courseCardText":      "#1F2328",
			"timetableGrid":       "#0D000000",
			"timetableToday":      "#00000000",
		},
		"coursePalette": []any{"#5B9BFF", "#38D178", "#C46CE0", "#FF7A7A", "#FFB042"},
	}
}

func defaultValidManifest() map[string]any {
	return map[string]any{
		"formatVersion": 1,
		"minAppVersion": "1.0.0",
		"id":            uuid.NewString(),
		"version":       1,
		"name":          "海盐测试",
		"description":   "用于内存单测的主题包",
		"author":        "测试作者",
		"tags":          []any{"清新", "浅色"},
		"license":       "CC-BY-4.0",
		"preview": map[string]any{
			"light": "preview/light.png",
			"dark":  "preview/dark.png",
		},
		"light": defaultValidVariant(false),
		"dark":  defaultValidVariant(true),
	}
}

func defaultValidAssets() map[string]testAssetSpec {
	return map[string]testAssetSpec{
		"preview/light.png": {Width: 1080, Height: 2340, Color: color.NRGBA{R: 245, G: 249, B: 255, A: 255}},
		"preview/dark.png":  {Width: 1080, Height: 2340, Color: color.NRGBA{R: 17, G: 19, B: 21, A: 255}},
	}
}

func encodeSolidPNG(t *testing.T, w, h int, c color.NRGBA) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	row := make([]byte, w*4)
	for x := 0; x < w; x++ {
		row[x*4+0] = c.R
		row[x*4+1] = c.G
		row[x*4+2] = c.B
		row[x*4+3] = c.A
	}
	for y := 0; y < h; y++ {
		copy(img.Pix[y*img.Stride:y*img.Stride+w*4], row)
	}
	var buf bytes.Buffer
	enc := png.Encoder{CompressionLevel: png.BestSpeed}
	require.NoError(t, enc.Encode(&buf, img))
	return buf.Bytes()
}

func encodeJPEGWithExifAndXMP(t *testing.T, w, h int, c color.NRGBA) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.SetRGBA(x, y, color.RGBA{R: c.R, G: c.G, B: c.B, A: 255})
		}
	}
	var rawJPG bytes.Buffer
	require.NoError(t, jpeg.Encode(&rawJPG, img, &jpeg.Options{Quality: 85}))
	src := rawJPG.Bytes()

	makeAPP1 := func(payload []byte) []byte {
		seg := make([]byte, 4+len(payload))
		seg[0] = 0xff
		seg[1] = 0xe1
		binary.BigEndian.PutUint16(seg[2:4], uint16(len(payload)+2))
		copy(seg[4:], payload)
		return seg
	}
	exifSeg := makeAPP1([]byte("Exif\x00\x00II*\x00\x08\x00\x00\x00\x00\x00"))
	xmpSeg := makeAPP1([]byte("http://ns.adobe.com/xap/1.0/\x00<x:xmpmeta>camera-secret</x:xmpmeta>"))

	var out bytes.Buffer
	out.Write(src[:2])
	out.Write(exifSeg)
	out.Write(xmpSeg)
	out.Write(src[2:])
	return out.Bytes()
}

// encodeSolidVP8LWebP 在内存中生成任意尺寸与 RGBA 的无损 VP8L WebP。
func encodeSolidVP8LWebP(w, h int, c color.NRGBA) []byte {
	var bitBuf uint64
	var bitCount uint
	var stream []byte
	writeBits := func(val uint32, n uint) {
		bitBuf |= uint64(val) << bitCount
		bitCount += n
		for bitCount >= 8 {
			stream = append(stream, byte(bitBuf&0xff))
			bitBuf >>= 8
			bitCount -= 8
		}
	}
	// 无变换、无颜色缓存、单一前缀码组
	writeBits(0, 1)
	writeBits(0, 1)
	writeBits(0, 1)
	// G, R, B, A, Distance 五棵单符号简单前缀树（每像素读取 0 bit 即可还原纯色）
	for _, sym := range []uint32{uint32(c.G), uint32(c.R), uint32(c.B), uint32(c.A), 0} {
		writeBits(1, 1) // is_simple
		writeBits(0, 1) // num_symbols - 1 = 0
		writeBits(1, 1) // 8-bit symbol
		writeBits(sym, 8)
	}
	if bitCount > 0 {
		stream = append(stream, byte(bitBuf&0xff))
	}

	vp8l := make([]byte, 5+len(stream))
	vp8l[0] = 0x2f
	hdr := uint32(w-1) | (uint32(h-1) << 14) | (1 << 28)
	binary.LittleEndian.PutUint32(vp8l[1:5], hdr)
	copy(vp8l[5:], stream)

	paddedLen := len(vp8l)
	if paddedLen%2 != 0 {
		paddedLen++
	}
	riff := make([]byte, 12+8+paddedLen)
	copy(riff[0:4], "RIFF")
	binary.LittleEndian.PutUint32(riff[4:8], uint32(4+8+paddedLen))
	copy(riff[8:12], "WEBP")
	copy(riff[12:16], "VP8L")
	binary.LittleEndian.PutUint32(riff[16:20], uint32(len(vp8l)))
	copy(riff[20:], vp8l)
	return riff
}

// buildMinimalSFNTFont 在内存中构造合法 TrueType SFNT 字体，映射指定码点并写入 name 表版权与许可。
func buildMinimalSFNTFont(runes []rune, copyrightText, licenseText string) []byte {
	sorted := make([]int, 0, len(runes))
	seen := make(map[rune]bool, len(runes))
	for _, r := range runes {
		if r >= 0 && !seen[r] {
			seen[r] = true
			sorted = append(sorted, int(r))
		}
	}
	sort.Ints(sorted)

	type cmapGroup struct{ start, end uint32 }
	var groups []cmapGroup
	for _, cp := range sorted {
		u := uint32(cp)
		if len(groups) > 0 && groups[len(groups)-1].end+1 == u {
			groups[len(groups)-1].end = u
		} else {
			groups = append(groups, cmapGroup{start: u, end: u})
		}
	}

	subLen := 16 + len(groups)*12
	cmap := make([]byte, 12+subLen)
	binary.BigEndian.PutUint16(cmap[0:2], 0)
	binary.BigEndian.PutUint16(cmap[2:4], 1)
	binary.BigEndian.PutUint16(cmap[4:6], 3)  // Windows
	binary.BigEndian.PutUint16(cmap[6:8], 10) // UCS-4
	binary.BigEndian.PutUint32(cmap[8:12], 12)
	binary.BigEndian.PutUint16(cmap[12:14], 12) // Format 12
	binary.BigEndian.PutUint32(cmap[16:20], uint32(subLen))
	binary.BigEndian.PutUint32(cmap[24:28], uint32(len(groups)))
	for i, g := range groups {
		off := 28 + i*12
		binary.BigEndian.PutUint32(cmap[off:off+4], g.start)
		binary.BigEndian.PutUint32(cmap[off+4:off+8], g.end)
		binary.BigEndian.PutUint32(cmap[off+8:off+12], 1) // glyphID = 1
	}

	head := make([]byte, 54)
	binary.BigEndian.PutUint32(head[0:4], 0x00010000)
	binary.BigEndian.PutUint32(head[12:16], 0x5F0F3CF5)
	binary.BigEndian.PutUint16(head[16:18], 0x000B)
	binary.BigEndian.PutUint16(head[18:20], 1000)

	hhea := make([]byte, 36)
	binary.BigEndian.PutUint32(hhea[0:4], 0x00010000)
	binary.BigEndian.PutUint16(hhea[4:6], 800)
	binary.BigEndian.PutUint16(hhea[6:8], 0xFF38) // -200
	binary.BigEndian.PutUint16(hhea[34:36], 2)

	maxp := make([]byte, 32)
	binary.BigEndian.PutUint32(maxp[0:4], 0x00010000)
	binary.BigEndian.PutUint16(maxp[4:6], 2) // 2 glyphs: .notdef (0) + covered (1)

	hmtx := make([]byte, 8)
	binary.BigEndian.PutUint16(hmtx[0:2], 500)
	binary.BigEndian.PutUint16(hmtx[4:6], 500)

	loca := make([]byte, 6) // short loca: 3 uint16 offsets = [0, 0, 0]
	glyf := make([]byte, 4)
	post := make([]byte, 32)
	binary.BigEndian.PutUint32(post[0:4], 0x00030000)

	encodeUTF16BE := func(s string) []byte {
		u16 := utf16.Encode([]rune(s))
		b := make([]byte, len(u16)*2)
		for i, v := range u16 {
			binary.BigEndian.PutUint16(b[i*2:i*2+2], v)
		}
		return b
	}
	cBytes := encodeUTF16BE(copyrightText)
	lBytes := encodeUTF16BE(licenseText)
	nameHdrLen := 6 + 2*12
	name := make([]byte, nameHdrLen+len(cBytes)+len(lBytes))
	binary.BigEndian.PutUint16(name[0:2], 0)
	binary.BigEndian.PutUint16(name[2:4], 2)
	binary.BigEndian.PutUint16(name[4:6], uint16(nameHdrLen))
	// Record 0: NameID 0 (Copyright)
	binary.BigEndian.PutUint16(name[6:8], 3)
	binary.BigEndian.PutUint16(name[8:10], 1)
	binary.BigEndian.PutUint16(name[10:12], 0x0409)
	binary.BigEndian.PutUint16(name[12:14], 0)
	binary.BigEndian.PutUint16(name[14:16], uint16(len(cBytes)))
	binary.BigEndian.PutUint16(name[16:18], 0)
	// Record 1: NameID 13 (License)
	binary.BigEndian.PutUint16(name[18:20], 3)
	binary.BigEndian.PutUint16(name[20:22], 1)
	binary.BigEndian.PutUint16(name[22:24], 0x0409)
	binary.BigEndian.PutUint16(name[24:26], 13)
	binary.BigEndian.PutUint16(name[26:28], uint16(len(lBytes)))
	binary.BigEndian.PutUint16(name[28:30], uint16(len(cBytes)))
	copy(name[nameHdrLen:], cBytes)
	copy(name[nameHdrLen+len(cBytes):], lBytes)

	os2 := make([]byte, 96)
	binary.BigEndian.PutUint16(os2[0:2], 2)       // version 2 (含 sxHeight 与 sCapHeight)
	binary.BigEndian.PutUint16(os2[4:6], 400)     // usWeightClass Regular
	binary.BigEndian.PutUint16(os2[6:8], 5)       // usWidthClass Medium
	binary.BigEndian.PutUint16(os2[68:70], 800)   // sTypoAscender
	binary.BigEndian.PutUint16(os2[70:72], 0xFF38) // sTypoDescender (-200)
	binary.BigEndian.PutUint16(os2[86:88], 500)   // sxHeight
	binary.BigEndian.PutUint16(os2[88:90], 700)   // sCapHeight

	tables := []struct {
		tag  string
		data []byte
	}{
		{"OS/2", os2},
		{"cmap", cmap},
		{"glyf", glyf},
		{"head", head},
		{"hhea", hhea},
		{"hmtx", hmtx},
		{"loca", loca},
		{"maxp", maxp},
		{"name", name},
		{"post", post},
	}

	sfntChecksum := func(b []byte) uint32 {
		var sum uint32
		padded := b
		if rem := len(b) % 4; rem != 0 {
			padded = make([]byte, len(b)+(4-rem))
			copy(padded, b)
		}
		for i := 0; i < len(padded); i += 4 {
			sum += binary.BigEndian.Uint32(padded[i : i+4])
		}
		return sum
	}

	dirSize := 12 + len(tables)*16
	totalSize := dirSize
	for _, tb := range tables {
		padded := (len(tb.data) + 3) &^ 3
		totalSize += padded
	}
	out := make([]byte, totalSize)
	binary.BigEndian.PutUint32(out[0:4], 0x00010000)
	binary.BigEndian.PutUint16(out[4:6], uint16(len(tables)))
	binary.BigEndian.PutUint16(out[6:8], 128) // 8 * 16
	binary.BigEndian.PutUint16(out[8:10], 3)
	binary.BigEndian.PutUint16(out[10:12], uint16(len(tables)*16-128))

	offset := dirSize
	for i, tb := range tables {
		rec := out[12+i*16 : 12+(i+1)*16]
		copy(rec[0:4], tb.tag)
		binary.BigEndian.PutUint32(rec[4:8], sfntChecksum(tb.data))
		binary.BigEndian.PutUint32(rec[8:12], uint32(offset))
		binary.BigEndian.PutUint32(rec[12:16], uint32(len(tb.data)))
		copy(out[offset:], tb.data)
		offset += (len(tb.data) + 3) &^ 3
	}
	return out
}

func buildTestThemeZip(t *testing.T, manifest any, assets map[string]testAssetSpec) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)

	if manifest != nil {
		var mBytes []byte
		switch v := manifest.(type) {
		case []byte:
			mBytes = v
		default:
			raw, err := json.Marshal(v)
			require.NoError(t, err)
			mBytes = raw
		}
		w, err := zw.CreateHeader(&zip.FileHeader{Name: "manifest.json", Method: zip.Deflate})
		require.NoError(t, err)
		_, err = w.Write(mBytes)
		require.NoError(t, err)
	}

	keys := make([]string, 0, len(assets))
	for k := range assets {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		spec := assets[k]
		var content []byte
		if spec.RawData != nil {
			content = spec.RawData
		} else {
			col := spec.Color
			if col == (color.NRGBA{}) {
				col = color.NRGBA{R: 60, G: 120, B: 200, A: 255}
			}
			switch spec.Format {
			case "jpeg_exif_xmp":
				content = encodeJPEGWithExifAndXMP(t, spec.Width, spec.Height, col)
			case "webp":
				content = encodeSolidVP8LWebP(spec.Width, spec.Height, col)
			default:
				content = encodeSolidPNG(t, spec.Width, spec.Height, col)
			}
		}
		w, err := zw.CreateHeader(&zip.FileHeader{Name: k, Method: zip.Deflate})
		require.NoError(t, err)
		_, err = w.Write(content)
		require.NoError(t, err)
	}

	require.NoError(t, zw.Close())
	return buf.Bytes()
}

// tamperZipCRC32 同时篡改目标条目在本地文件头和中央目录中的 CRC32，保持压缩流仍可正常解压。
func tamperZipCRC32(t *testing.T, rawZip []byte, targetName string) []byte {
	t.Helper()
	dup := append([]byte(nil), rawZip...)
	nameBytes := []byte(targetName)

	localModified := false
	cdModified := false
	for i := 0; i+30 <= len(dup); i++ {
		// Local file header: 0x04034b50
		if dup[i] == 0x50 && dup[i+1] == 0x4b && dup[i+2] == 0x03 && dup[i+3] == 0x04 {
			nLen := int(binary.LittleEndian.Uint16(dup[i+26 : i+28]))
			if i+30+nLen <= len(dup) && bytes.Equal(dup[i+30:i+30+nLen], nameBytes) {
				crc := binary.LittleEndian.Uint32(dup[i+14 : i+18])
				binary.LittleEndian.PutUint32(dup[i+14:i+18], crc^0xFFFFFFFF)
				localModified = true
			}
		}
		// Central directory header: 0x02014b50
		if i+46 <= len(dup) && dup[i] == 0x50 && dup[i+1] == 0x4b && dup[i+2] == 0x01 && dup[i+3] == 0x02 {
			nLen := int(binary.LittleEndian.Uint16(dup[i+28 : i+30]))
			if i+46+nLen <= len(dup) && bytes.Equal(dup[i+46:i+46+nLen], nameBytes) {
				crc := binary.LittleEndian.Uint32(dup[i+16 : i+20])
				binary.LittleEndian.PutUint32(dup[i+16:i+20], crc^0xFFFFFFFF)
				cdModified = true
			}
		}
	}
	require.True(t, localModified && cdModified, "应当同时定位并修改本地头与中央目录 CRC32")
	return dup
}

func fullFontRunes(coverageRatio float64) []rune {
	var runes []rune
	for r := rune(0x20); r <= 0x7E; r++ {
		runes = append(runes, r)
	}
	gb := loadGB2312Level1Runes()
	take := int(float64(len(gb)) * coverageRatio)
	if take > len(gb) {
		take = len(gb)
	}
	runes = append(runes, gb[:take]...)
	return runes
}

func TestThemePackValidatorTable(t *testing.T) {
	validFont := buildMinimalSFNTFont(fullFontRunes(0.995), "Copyright 2026 SYLU", "OFL-1.1")
	_, sfntErr := sfnt.Parse(validFont)
	require.NoError(t, sfntErr)
	lowCovFont := buildMinimalSFNTFont(fullFontRunes(0.60), "Copyright 2026 SYLU", "OFL-1.1")

	validFullManifest := defaultValidManifest()
	validFullManifest["font"] = map[string]any{
		"name":    "测试楷体",
		"regular": "fonts/test_kai.ttf",
		"license": "OFL-1.1",
	}
	validFullManifest["launcherIcon"] = map[string]any{
		"builtin": "sea",
		"custom":  "icons/launcher_custom.png",
	}
	validFullAssets := defaultValidAssets()
	validFullAssets["fonts/test_kai.ttf"] = testAssetSpec{RawData: validFont}
	validFullAssets["icons/launcher_custom.png"] = testAssetSpec{Width: 512, Height: 512, Color: color.NRGBA{R: 30, G: 90, B: 180, A: 255}}

	res, err := ValidateAndNormalizeThemePack(buildTestThemeZip(t, validFullManifest, validFullAssets), ThemeMetadataOverrides{})
	require.NoError(t, err)
	require.Equal(t, "Copyright 2026 SYLU", res.FontCopyright)
	require.Equal(t, "OFL-1.1", res.FontLicenseNote)

	cases := []struct {
		name     string
		build    func() ([]byte, ThemeMetadataOverrides)
		wantCode string
	}{
		{
			name: "非 ZIP 字节返回 theme_zip_invalid",
			build: func() ([]byte, ThemeMetadataOverrides) {
				return []byte("not-a-zip-archive"), ThemeMetadataOverrides{}
			},
			wantCode: ThemeCodeZipInvalid,
		},
		{
			name: "本地头与中央目录同时篡改 CRC32 返回 theme_zip_invalid",
			build: func() ([]byte, ThemeMetadataOverrides) {
				raw := buildTestThemeZip(t, defaultValidManifest(), defaultValidAssets())
				return tamperZipCRC32(t, raw, "preview/light.png"), ThemeMetadataOverrides{}
			},
			wantCode: ThemeCodeZipInvalid,
		},
		{
			name: "伪造超 96MB 解压体积返回 theme_too_large",
			build: func() ([]byte, ThemeMetadataOverrides) {
				raw := buildTestThemeZip(t, defaultValidManifest(), defaultValidAssets())
				// 将中央目录中的 uncompressed size 改为 100MB 触发解压总预算拦截
				dup := append([]byte(nil), raw...)
				target := []byte("preview/light.png")
				for i := 0; i+46 <= len(dup); i++ {
					if dup[i] == 0x50 && dup[i+1] == 0x4b && dup[i+2] == 0x01 && dup[i+3] == 0x02 {
						nLen := int(binary.LittleEndian.Uint16(dup[i+28 : i+30]))
						if i+46+nLen <= len(dup) && bytes.Equal(dup[i+46:i+46+nLen], target) {
							binary.LittleEndian.PutUint32(dup[i+24:i+28], 100*1024*1024)
						}
					}
				}
				return dup, ThemeMetadataOverrides{}
			},
			wantCode: ThemeCodeTooLarge,
		},
		{
			name: "缺少 manifest.json 返回 theme_manifest_invalid",
			build: func() ([]byte, ThemeMetadataOverrides) {
				return buildTestThemeZip(t, nil, defaultValidAssets()), ThemeMetadataOverrides{}
			},
			wantCode: ThemeCodeManifestInvalid,
		},
		{
			name: "manifest 超过 64KB 返回 theme_manifest_invalid",
			build: func() ([]byte, ThemeMetadataOverrides) {
				m := defaultValidManifest()
				m["extraPadding"] = strings.Repeat("x", 70*1024)
				return buildTestThemeZip(t, m, defaultValidAssets()), ThemeMetadataOverrides{}
			},
			wantCode: ThemeCodeManifestInvalid,
		},
		{
			name: "formatVersion 不等于 1 返回 theme_format_unsupported",
			build: func() ([]byte, ThemeMetadataOverrides) {
				m := defaultValidManifest()
				m["formatVersion"] = 2
				return buildTestThemeZip(t, m, defaultValidAssets()), ThemeMetadataOverrides{}
			},
			wantCode: ThemeCodeFormatUnsupported,
		},
		{
			name: "minAppVersion 高于当前版本返回 theme_app_too_old",
			build: func() ([]byte, ThemeMetadataOverrides) {
				m := defaultValidManifest()
				m["minAppVersion"] = "9.9.0"
				return buildTestThemeZip(t, m, defaultValidAssets()), ThemeMetadataOverrides{CurrentAppVersion: "1.0.0"}
			},
			wantCode: ThemeCodeAppTooOld,
		},
		{
			name: "未知页头模板返回 theme_field_invalid",
			build: func() ([]byte, ThemeMetadataOverrides) {
				m := defaultValidManifest()
				m["layout"] = map[string]any{"home": map[string]any{"preset": "masonry"}}
				return buildTestThemeZip(t, m, defaultValidAssets()), ThemeMetadataOverrides{}
			},
			wantCode: ThemeCodeFieldInvalid,
		},
		{
			name: "6 张贴纸超限返回 theme_field_invalid（不静默截断）",
			build: func() ([]byte, ThemeMetadataOverrides) {
				m := defaultValidManifest()
				stickers := make([]any, 6)
				for i := range stickers {
					stickers[i] = map[string]any{"image": "decorations/s.png", "x": 0.5, "y": 0.5, "width": 0.2}
				}
				m["light"].(map[string]any)["decorations"] = map[string]any{
					"home": map[string]any{"stickers": stickers},
				}
				return buildTestThemeZip(t, m, defaultValidAssets()), ThemeMetadataOverrides{}
			},
			wantCode: ThemeCodeFieldInvalid,
		},
		{
			name: "越界卡片描边返回 theme_field_invalid（不静默截断）",
			build: func() ([]byte, ThemeMetadataOverrides) {
				m := defaultValidManifest()
				m["light"].(map[string]any)["cardStyle"] = map[string]any{"borderWidth": 4.0}
				return buildTestThemeZip(t, m, defaultValidAssets()), ThemeMetadataOverrides{}
			},
			wantCode: ThemeCodeFieldInvalid,
		},
		{
			name: "引用图片缺失返回 theme_asset_missing",
			build: func() ([]byte, ThemeMetadataOverrides) {
				m := defaultValidManifest()
				m["light"].(map[string]any)["wallpapers"] = map[string]any{
					"global": map[string]any{"portrait": "wallpaper/missing.png"},
				}
				return buildTestThemeZip(t, m, defaultValidAssets()), ThemeMetadataOverrides{}
			},
			wantCode: ThemeCodeAssetMissing,
		},
		{
			name: "预览图尺寸不等于 1080x2340 返回 theme_image_invalid",
			build: func() ([]byte, ThemeMetadataOverrides) {
				assets := defaultValidAssets()
				assets["preview/light.png"] = testAssetSpec{Width: 600, Height: 800}
				return buildTestThemeZip(t, defaultValidManifest(), assets), ThemeMetadataOverrides{}
			},
			wantCode: ThemeCodeImageInvalid,
		},
		{
			name: "自定义桌面图标含透明像素返回 theme_image_invalid",
			build: func() ([]byte, ThemeMetadataOverrides) {
				m := defaultValidManifest()
				m["launcherIcon"] = map[string]any{"custom": "icons/custom.png"}
				assets := defaultValidAssets()
				assets["icons/custom.png"] = testAssetSpec{Width: 512, Height: 512, Color: color.NRGBA{R: 20, G: 40, B: 80, A: 200}}
				return buildTestThemeZip(t, m, assets), ThemeMetadataOverrides{}
			},
			wantCode: ThemeCodeImageInvalid,
		},
		{
			name: "对比度低于阈值返回 theme_contrast_low",
			build: func() ([]byte, ThemeMetadataOverrides) {
				m := defaultValidManifest()
				// 默认内置浅色 #747B82 在白卡片上对比度 4.29 < 4.5
				m["light"].(map[string]any)["tokens"].(map[string]any)["textSecondary"] = "#747B82"
				return buildTestThemeZip(t, m, defaultValidAssets()), ThemeMetadataOverrides{}
			},
			wantCode: ThemeCodeContrastLow,
		},
		{
			name: "损坏或 TTC 字体返回 theme_font_invalid",
			build: func() ([]byte, ThemeMetadataOverrides) {
				m := defaultValidManifest()
				m["font"] = map[string]any{"name": "坏字体", "regular": "fonts/bad.ttf", "license": "OFL-1.1"}
				assets := defaultValidAssets()
				assets["fonts/bad.ttf"] = testAssetSpec{RawData: []byte("ttcf\x00\x01\x00\x00broken")}
				return buildTestThemeZip(t, m, assets), ThemeMetadataOverrides{}
			},
			wantCode: ThemeCodeFontInvalid,
		},
		{
			name: "GB2312 一级汉字覆盖率不足 99% 返回 theme_font_coverage_low",
			build: func() ([]byte, ThemeMetadataOverrides) {
				m := defaultValidManifest()
				m["font"] = map[string]any{"name": "残缺字体", "regular": "fonts/low.ttf", "license": "OFL-1.1"}
				assets := defaultValidAssets()
				assets["fonts/low.ttf"] = testAssetSpec{RawData: lowCovFont}
				return buildTestThemeZip(t, m, assets), ThemeMetadataOverrides{}
			},
			wantCode: ThemeCodeFontCoverageLow,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			raw, ov := tc.build()
			_, err := ValidateAndNormalizeThemePack(raw, ov)
			require.Error(t, err)
			var te *ThemePackError
			require.ErrorAs(t, err, &te)
			require.Equal(t, tc.wantCode, te.Code)
		})
	}
}

func openSQLiteThemeDB(t *testing.T) *gorm.DB {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "theme.sqlite")
	db, err := gorm.Open(sqlite.Open(dbPath+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)"), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = sqlDB.Close() })
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.AdminLog{}, &models.Notification{}, &models.SystemConfig{}, &models.ThemePack{}))
	return db
}

func TestThemePackNormalizationAndFields(t *testing.T) {
	db := openSQLiteThemeDB(t)
	require.NoError(t, db.Create(&models.User{ID: 10, Nickname: "普通创作者", Role: models.RoleUser, AccountStatus: "active", PasswordHash: "x"}).Error)
	svc := NewThemePackService(db, t.TempDir())

	m := defaultValidManifest()
	m["unknownTopField"] = "should-be-stripped"
	m["source"] = "official" // 普通用户伪造 official 应被强制改为 community
	m["layout"] = map[string]any{
		"home": map[string]any{
			"preset":      "immersive",
			"alignment":   "center",
			"imageHeight": 210.0,
			"imageWidth":  0.85,
		},
		"campus": map[string]any{
			"preset":      "compact",
			"alignment":   "end",
			"imageHeight": 120.0,
			"imageWidth":  0.6,
		},
	}
	light := m["light"].(map[string]any)
	light["cardStyle"] = map[string]any{
		"borderWidth": 1.5,
		"shadow":      "medium",
		"unknownKey":  99,
	}
	light["wallpapers"] = map[string]any{
		"global": map[string]any{
			"portrait": "wallpaper/sea_bg.webp",
			"fit":      "cover",
			"focalX":   0.3,
			"focalY":   0.7,
			"blur":     6.0,
			"scrim":    0.25,
			"adjustments": map[string]any{
				"brightness": 12.0,
				"contrast":   115.0,
				"saturation": 90.0,
			},
		},
	}
	light["decorations"] = map[string]any{
		"home": map[string]any{
			"background": map[string]any{
				"image":  "decorations/hdr_bg.jpg",
				"fit":    "cover",
				"focalX": 0.4,
				"focalY": 0.6,
				"blur":   2.0,
				"scrim":  0.1,
				"adjustments": map[string]any{
					"brightness": -10.0,
					"contrast":   105.0,
					"saturation": 120.0,
				},
			},
			"stickers": []any{
				map[string]any{"image": "decorations/st_first.webp", "x": 0.2, "y": 0.3, "width": 0.15, "rotation": -15.0},
				map[string]any{"image": "decorations/st_alpha.png", "x": 0.8, "y": 0.6, "width": 0.25, "rotation": 30.0},
			},
		},
	}

	assets := map[string]testAssetSpec{
		"preview/light.png":         {Width: 1080, Height: 2340, Format: "jpeg_exif_xmp", Color: color.NRGBA{R: 240, G: 248, B: 255, A: 255}},
		"preview/dark.png":          {Width: 1080, Height: 2340, Format: "webp", Color: color.NRGBA{R: 18, G: 20, B: 24, A: 255}},
		"wallpaper/sea_bg.webp":     {Width: 64, Height: 64, Format: "webp", Color: color.NRGBA{R: 40, G: 110, B: 180, A: 255}},
		"decorations/hdr_bg.jpg":    {Width: 120, Height: 60, Format: "jpeg_exif_xmp", Color: color.NRGBA{R: 80, G: 140, B: 200, A: 255}},
		"decorations/st_first.webp": {Width: 48, Height: 48, Format: "webp", Color: color.NRGBA{R: 255, G: 200, B: 80, A: 180}},
		"decorations/st_alpha.png":  {Width: 48, Height: 48, Format: "png", Color: color.NRGBA{R: 255, G: 100, B: 120, A: 128}},
	}
	// preview/light 路径改为 .jpg 以匹配 jpeg_exif_xmp 输入后缀
	m["preview"].(map[string]any)["light"] = "preview/light.jpg"
	assets["preview/light.jpg"] = assets["preview/light.png"]
	delete(assets, "preview/light.png")

	pack, err := svc.Submit(context.Background(), 10, ThemeSubmitOptions{
		IdempotencyKey:  "idem-norm-000001",
		RequestedSource: "official",
	}, buildTestThemeZip(t, m, assets))
	require.NoError(t, err)
	require.Equal(t, models.ThemeSourceCommunity, pack.Source)

	pkgBytes, err := os.ReadFile(filepath.Join(svc.PackDir(pack.ID), "package.sltheme"))
	require.NoError(t, err)
	lightPreviewBytes, err := os.ReadFile(filepath.Join(svc.PackDir(pack.ID), "preview_light.jpg"))
	require.NoError(t, err)
	require.False(t, bytes.Contains(lightPreviewBytes, []byte("Exif")))
	require.False(t, bytes.Contains(lightPreviewBytes, []byte("http://ns.adobe.com/xap")))

	zr, err := zip.NewReader(bytes.NewReader(pkgBytes), int64(len(pkgBytes)))
	require.NoError(t, err)
	entryBytes := map[string][]byte{}
	for _, f := range zr.File {
		require.False(t, strings.HasSuffix(f.Name, ".webp"), "规范包内不能残留 WebP: %s", f.Name)
		rc, err := f.Open()
		require.NoError(t, err)
		b, err := os.ReadFile(os.DevNull)
		_ = b
		var cBuf bytes.Buffer
		_, err = cBuf.ReadFrom(rc)
		require.NoError(t, err)
		_ = rc.Close()
		data := cBuf.Bytes()
		require.False(t, bytes.Contains(data, []byte("Exif")), "资源不能含 Exif: %s", f.Name)
		require.False(t, bytes.Contains(data, []byte("http://ns.adobe.com/xap")), "资源不能含 XMP: %s", f.Name)
		entryBytes[f.Name] = data
	}

	var storedManifest map[string]any
	require.NoError(t, json.Unmarshal(entryBytes["manifest.json"], &storedManifest))
	require.NotContains(t, storedManifest, "unknownTopField")
	require.Equal(t, "community", storedManifest["source"])
	require.Equal(t, pack.FamilyID, storedManifest["id"])
	require.Equal(t, float64(1), storedManifest["version"])
	require.Equal(t, "普通创作者", storedManifest["author"])

	// 核对 layout、cardStyle、adjustments、装饰顺序与路径重写
	storedLayout := storedManifest["layout"].(map[string]any)["home"].(map[string]any)
	require.Equal(t, "immersive", storedLayout["preset"])
	require.Equal(t, "center", storedLayout["alignment"])
	require.Equal(t, 210.0, storedLayout["imageHeight"])
	require.Equal(t, 0.85, storedLayout["imageWidth"])

	storedLight := storedManifest["light"].(map[string]any)
	storedCS := storedLight["cardStyle"].(map[string]any)
	require.NotContains(t, storedCS, "unknownKey")
	require.Equal(t, 1.5, storedCS["borderWidth"])
	require.Equal(t, "medium", storedCS["shadow"])

	storedWall := storedLight["wallpapers"].(map[string]any)["global"].(map[string]any)
	require.Equal(t, "wallpaper/sea_bg.jpg", storedWall["portrait"])
	require.Contains(t, entryBytes, "wallpaper/sea_bg.jpg")
	storedAdj := storedWall["adjustments"].(map[string]any)
	require.Equal(t, 12.0, storedAdj["brightness"])
	require.Equal(t, 115.0, storedAdj["contrast"])
	require.Equal(t, 90.0, storedAdj["saturation"])

	storedDeco := storedLight["decorations"].(map[string]any)["home"].(map[string]any)
	bgPath := storedDeco["background"].(map[string]any)["image"].(string)
	require.Equal(t, "decorations/hdr_bg.jpg", bgPath)
	require.Contains(t, entryBytes, bgPath)

	stickers := storedDeco["stickers"].([]any)
	require.Len(t, stickers, 2)
	s0 := stickers[0].(map[string]any)
	s1 := stickers[1].(map[string]any)
	require.Equal(t, "decorations/st_first.png", s0["image"])
	require.Equal(t, -15.0, s0["rotation"])
	require.Equal(t, "decorations/st_alpha.png", s1["image"])
	require.Equal(t, 30.0, s1["rotation"])

	// 验证透明贴纸重编码为 PNG 后 alpha 保留
	decodedSticker, err := png.Decode(bytes.NewReader(entryBytes["decorations/st_alpha.png"]))
	require.NoError(t, err)
	_, _, _, a16 := decodedSticker.At(10, 10).RGBA()
	alpha8 := a16 >> 8
	require.InDelta(t, 128, int(alpha8), 2)
}

func runThemePackConcurrencyAndLifecycleSuite(t *testing.T, db *gorm.DB) {
	t.Helper()
	svc := NewThemePackService(db, t.TempDir())
	rawZip := buildTestThemeZip(t, defaultValidManifest(), defaultValidAssets())

	require.NoError(t, db.Create(&models.User{ID: 101, Nickname: "作者甲", Role: models.RoleUser, AccountStatus: "active", PasswordHash: "x"}).Error)
	require.NoError(t, db.Create(&models.User{ID: 102, Nickname: "作者乙", Role: models.RoleUser, AccountStatus: "active", PasswordHash: "x"}).Error)
	require.NoError(t, db.Create(&models.User{ID: 201, Nickname: "管理员一", Role: models.RoleAdmin, AccountStatus: "active", PasswordHash: "x"}).Error)
	require.NoError(t, db.Create(&models.User{ID: 202, Nickname: "管理员二", Role: models.RoleAdmin, AccountStatus: "active", PasswordHash: "x"}).Error)

	ctx := context.Background()

	// 1. 幂等：同一幂等键返回同一记录
	first, err := svc.Submit(ctx, 101, ThemeSubmitOptions{IdempotencyKey: "idem-key-alpha-01"}, rawZip)
	require.NoError(t, err)
	dup, err := svc.Submit(ctx, 101, ThemeSubmitOptions{IdempotencyKey: "idem-key-alpha-01"}, rawZip)
	require.NoError(t, err)
	require.Equal(t, first.ID, dup.ID)
	require.Equal(t, 1, first.Version)
	require.Equal(t, first.ID, first.FamilyID)

	// 2. 配额边界：待审上限 3（第 2、3 个通过，第 4 个拒绝），24 小时上限 5（审核释放待审后第 4、5 个通过，第 6 个拒绝）
	p2, err := svc.Submit(ctx, 101, ThemeSubmitOptions{IdempotencyKey: "idem-key-alpha-02"}, rawZip)
	require.NoError(t, err)
	p3, err := svc.Submit(ctx, 101, ThemeSubmitOptions{IdempotencyKey: "idem-key-alpha-03"}, rawZip)
	require.NoError(t, err)
	_, err = svc.Submit(ctx, 101, ThemeSubmitOptions{IdempotencyKey: "idem-key-alpha-04"}, rawZip)
	var te *ThemePackError
	require.ErrorAs(t, err, &te)
	require.Equal(t, ThemeCodeQuota, te.Code)

	// 审核处理 p2、p3 后待审降为 1，此时 24h 内已有 3 条：第 4、5 条通过，第 6 条触发 24h 上限 5
	_, err = svc.Review(ctx, p2.ID, 201, false, "quality", "测试释放待审")
	require.NoError(t, err)
	_, err = svc.Review(ctx, p3.ID, 201, false, "quality", "测试释放待审")
	require.NoError(t, err)

	_, err = svc.Submit(ctx, 101, ThemeSubmitOptions{IdempotencyKey: "idem-key-alpha-04b"}, rawZip)
	require.NoError(t, err)
	_, err = svc.Submit(ctx, 101, ThemeSubmitOptions{IdempotencyKey: "idem-key-alpha-05b"}, rawZip)
	require.NoError(t, err)
	_, err = svc.Submit(ctx, 101, ThemeSubmitOptions{IdempotencyKey: "idem-key-alpha-06b"}, rawZip)
	require.ErrorAs(t, err, &te)
	require.Equal(t, ThemeCodeQuota, te.Code)

	// 3. 管理员不能审核自己的投稿
	adminOwn, err := svc.Submit(ctx, 201, ThemeSubmitOptions{IdempotencyKey: "idem-admin-own-01", RequestedSource: "official"}, rawZip)
	require.NoError(t, err)
	require.Equal(t, models.ThemeSourceOfficial, adminOwn.Source)
	_, err = svc.Review(ctx, adminOwn.ID, 201, true, "", "")
	require.ErrorAs(t, err, &te)
	require.Equal(t, ThemeCodeForbidden, te.Code)

	// 4. 新版本并发投稿与并发审核（使用作者乙 102）
	v1, err := svc.Submit(ctx, 102, ThemeSubmitOptions{IdempotencyKey: "idem-beta-v1-0001"}, rawZip)
	require.NoError(t, err)
	_, err = svc.Review(ctx, v1.ID, 201, true, "", "")
	require.NoError(t, err)

	// 非作者投新版本被拒绝
	_, err = svc.Submit(ctx, 201, ThemeSubmitOptions{IdempotencyKey: "idem-hijack-0001", FamilyID: v1.FamilyID}, rawZip)
	require.ErrorAs(t, err, &te)
	require.Equal(t, ThemeCodeForbidden, te.Code)

	// 两个新版本并发投稿，版本号必须为不重复连续的 2 和 3，且包内 manifest id/version 一致
	var wg sync.WaitGroup
	subResults := make([]*models.ThemePack, 2)
	subErrs := make([]error, 2)
	for i := 0; i < 2; i++ {
		i := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			subResults[i], subErrs[i] = svc.Submit(ctx, 102, ThemeSubmitOptions{
				IdempotencyKey: fmt.Sprintf("idem-beta-conc-%d", i),
				FamilyID:       v1.FamilyID,
			}, rawZip)
		}()
	}
	wg.Wait()
	require.NoError(t, subErrs[0])
	require.NoError(t, subErrs[1])
	vers := []int{subResults[0].Version, subResults[1].Version}
	sort.Ints(vers)
	require.Equal(t, []int{2, 3}, vers)

	for _, sr := range subResults {
		mf := svc.ReadStoredManifest(sr.ID)
		require.Equal(t, sr.FamilyID, mf["id"])
		require.Equal(t, float64(sr.Version), mf["version"])
	}

	var v2Rec, v3Rec *models.ThemePack
	if subResults[0].Version == 2 {
		v2Rec, v3Rec = subResults[0], subResults[1]
	} else {
		v2Rec, v3Rec = subResults[1], subResults[0]
	}

	// 两位管理员并发审核 v2 和 v3：结束后整个版本族只有一条 approved，且为最高已通过版本
	revErrs := make([]error, 2)
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, revErrs[0] = svc.Review(ctx, v2Rec.ID, 201, true, "", "")
	}()
	go func() {
		defer wg.Done()
		_, revErrs[1] = svc.Review(ctx, v3Rec.ID, 202, true, "", "")
	}()
	wg.Wait()
	// 若 v3 先获锁通过，v2 会被标为 superseded 并返回 409；若 v2 先通过，v3 随后通过并将 v2 标为 superseded
	for _, re := range revErrs {
		if re != nil {
			require.ErrorAs(t, re, &te)
			require.Equal(t, ThemeCodeConflict, te.Code)
		}
	}
	var approvedRows []models.ThemePack
	require.NoError(t, db.Where("family_id = ? AND status = ?", v1.FamilyID, models.ThemeStatusApproved).Find(&approvedRows).Error)
	require.Len(t, approvedRows, 1)
	require.Equal(t, 3, approvedRows[0].Version)

	// 5. 显式顺序：先通过高版本 v5，待审 v4 立即变为 superseded 且发通知，再审 v4 返回 409
	v4, err := svc.Submit(ctx, 102, ThemeSubmitOptions{IdempotencyKey: "idem-beta-v4-0004", FamilyID: v1.FamilyID}, rawZip)
	require.NoError(t, err)
	v5, err := svc.Submit(ctx, 102, ThemeSubmitOptions{IdempotencyKey: "idem-beta-v5-0005", FamilyID: v1.FamilyID}, rawZip)
	require.NoError(t, err)
	require.Equal(t, 4, v4.Version)
	require.Equal(t, 5, v5.Version)

	_, err = svc.Review(ctx, v5.ID, 201, true, "", "")
	require.NoError(t, err)

	var v4Reloaded models.ThemePack
	require.NoError(t, db.First(&v4Reloaded, "id = ?", v4.ID).Error)
	require.Equal(t, models.ThemeStatusSuperseded, v4Reloaded.Status)

	var supNotifCount int64
	require.NoError(t, db.Model(&models.Notification{}).
		Where("user_id = ? AND content LIKE ?", 102, "%已被 v5 取代%").
		Count(&supNotifCount).Error)
	require.EqualValues(t, 1, supNotifCount)

	_, err = svc.Review(ctx, v4.ID, 202, true, "", "")
	require.ErrorAs(t, err, &te)
	require.Equal(t, ThemeCodeConflict, te.Code)
	require.Equal(t, 409, te.Status)

	// 6. 先通过低版本再通过高版本（使用管理员一的官方主题家族 adminOwn，由管理员二审核）
	_, err = svc.Review(ctx, adminOwn.ID, 202, true, "", "")
	require.NoError(t, err)
	adminV2, err := svc.Submit(ctx, 201, ThemeSubmitOptions{IdempotencyKey: "idem-admin-own-02", FamilyID: adminOwn.FamilyID, RequestedSource: "official"}, rawZip)
	require.NoError(t, err)
	adminV3, err := svc.Submit(ctx, 201, ThemeSubmitOptions{IdempotencyKey: "idem-admin-own-03", FamilyID: adminOwn.FamilyID, RequestedSource: "official"}, rawZip)
	require.NoError(t, err)
	_, err = svc.Review(ctx, adminV2.ID, 202, true, "", "")
	require.NoError(t, err)
	_, err = svc.Review(ctx, adminV3.ID, 202, true, "", "")
	require.NoError(t, err)
	var adminV2After models.ThemePack
	require.NoError(t, db.First(&adminV2After, "id = ?", adminV2.ID).Error)
	require.Equal(t, models.ThemeStatusSuperseded, adminV2After.Status)

	// 7. 下架后不能再投新版本
	require.NoError(t, svc.Remove(ctx, adminOwn.FamilyID, 202, "copyright", "测试下架"))
	_, err = svc.Submit(ctx, 201, ThemeSubmitOptions{IdempotencyKey: "idem-admin-own-04", FamilyID: adminOwn.FamilyID}, rawZip)
	require.ErrorAs(t, err, &te)
	require.Equal(t, ThemeCodeConflict, te.Code)
}

func TestThemePackLifecycleAndConcurrencySQLite(t *testing.T) {
	db := openSQLiteThemeDB(t)
	runThemePackConcurrencyAndLifecycleSuite(t, db)
}

func TestThemePackPostgresAutoMigrateAndConcurrency(t *testing.T) {
	dsn := strings.TrimSpace(os.Getenv("THEME_TEST_PG_DSN"))
	if dsn == "" {
		t.Skip("未设置 THEME_TEST_PG_DSN，跳过隔离 PostgreSQL 锁语义测试")
	}
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	t.Cleanup(func() { _ = sqlDB.Close() })

	// 验证首次与重复启动 AutoMigrate 均幂等无错
	for i := 0; i < 2; i++ {
		require.NoError(t, db.AutoMigrate(
			&models.User{},
			&models.Report{},
			&models.AdminLog{},
			&models.Notification{},
			&models.SystemConfig{},
			&models.ThemePack{},
		))
	}
	runThemePackConcurrencyAndLifecycleSuite(t, db)
}

func TestThemePackV2FieldsAndTitleFont(t *testing.T) {
	titleFont := buildMinimalSFNTFont(fullFontRunes(0.995), "Copyright 2026 SYLU", "OFL-1.1")
	m := defaultValidManifest()
	m["font"] = map[string]any{
		"title": map[string]any{"name": "测试标题体", "regular": "fonts/title.ttf", "license": "OFL-1.1"},
	}
	light := m["light"].(map[string]any)
	light["identityHarmony"] = 0.6
	light["cardStyle"] = map[string]any{"fill": "tint"}
	light["backdrop"] = map[string]any{
		"gradient": map[string]any{"colors": []any{"#EAF2FF", "#FFF6EE"}, "angle": 160.0},
		"glow":     []any{map[string]any{"color": "#BFD6FF", "x": 0.9, "y": 0.1}},
		"pattern":  map[string]any{"tile": "decorations/tile.png", "opacity": 0.2},
	}
	light["sectionMark"] = map[string]any{"style": "icon", "image": "decorations/mark.png"}
	light["illustrations"] = map[string]any{"empty": "decorations/empty.png"}
	light["ornaments"] = map[string]any{
		"postCard": map[string]any{"image": "decorations/ear.png", "width": 56.0, "dx": 56.0, "dy": -20.0},
	}
	light["serviceIcons"] = map[string]any{"edu": "icons/edu.png"}
	assets := defaultValidAssets()
	assets["decorations/ear.png"] = testAssetSpec{Width: 224, Height: 112}
	assets["icons/edu.png"] = testAssetSpec{Width: 256, Height: 256}
	assets["fonts/title.ttf"] = testAssetSpec{RawData: titleFont}
	assets["decorations/tile.png"] = testAssetSpec{Width: 64, Height: 64}
	assets["decorations/mark.png"] = testAssetSpec{Width: 48, Height: 48}
	assets["decorations/empty.png"] = testAssetSpec{Width: 400, Height: 400}

	res, err := ValidateAndNormalizeThemePack(buildTestThemeZip(t, m, assets), ThemeMetadataOverrides{})
	require.NoError(t, err)
	out := res.Manifest["light"].(map[string]any)
	require.Equal(t, 0.6, out["identityHarmony"])
	require.Equal(t, "tint", out["cardStyle"].(map[string]any)["fill"])
	backdrop := out["backdrop"].(map[string]any)
	require.Equal(t, 0.5, backdrop["glow"].([]any)[0].(map[string]any)["radius"])
	require.True(t, strings.HasPrefix(backdrop["pattern"].(map[string]any)["tile"].(string), "decorations/"))
	require.True(t, strings.HasSuffix(out["illustrations"].(map[string]any)["empty"].(string), ".png"))
	ear := out["ornaments"].(map[string]any)["postCard"].(map[string]any)
	require.Equal(t, "topRight", ear["corner"])
	require.Equal(t, 1.0, ear["opacity"])
	require.True(t, strings.HasPrefix(ear["image"].(string), "decorations/"))
	require.True(t, strings.HasPrefix(out["serviceIcons"].(map[string]any)["edu"].(string), "icons/"))
	title := res.Manifest["font"].(map[string]any)["title"].(map[string]any)
	require.True(t, strings.HasPrefix(title["regular"].(string), "fonts/"))
	_, hasRegular := res.Manifest["font"].(map[string]any)["regular"]
	require.False(t, hasRegular)

	for _, bad := range []map[string]any{
		{"backdrop": map[string]any{}},
		{"backdrop": map[string]any{"gradient": map[string]any{"colors": []any{"#FFFFFF"}}}},
		{"sectionMark": map[string]any{"style": "icon"}},
		{"identityHarmony": 1.5},
		{"cardStyle": map[string]any{"fill": "neon"}},
		{"ornaments": map[string]any{"postCard": map[string]any{"image": "decorations/ear.png", "width": 400.0}}},
	} {
		broken := defaultValidManifest()
		for k, v := range bad {
			broken["light"].(map[string]any)[k] = v
		}
		_, err := ValidateAndNormalizeThemePack(buildTestThemeZip(t, broken, defaultValidAssets()), ThemeMetadataOverrides{})
		var themeErr *ThemePackError
		require.ErrorAs(t, err, &themeErr, "%v", bad)
		require.Equal(t, "theme_field_invalid", themeErr.Code, "%v", bad)
	}
}

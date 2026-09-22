package handlers

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image"
	"image/gif"
	_ "image/jpeg"
	_ "image/png"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

// 官方目录复用经过发布审核的内嵌资源，不接受客户端路径或任意 URL。
type officialEmojiPack struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	Version        int    `json:"version"`
	AssetCount     int    `json:"asset_count"`
	TotalSize      int    `json:"total_size"`
	ManifestSHA256 string `json:"manifest_sha256"`
	manifest       []byte
	assets         map[string]stickerCatalogItem
}

var officialEmojiPacks = loadOfficialEmojiPacks()

func loadOfficialEmojiPacks() []officialEmojiPack {
	data, err := stickerAssetFS.ReadFile("sticker_assets/catalog.json")
	if err != nil {
		panic(err)
	}
	var groups []stickerCatalogGroup
	if err := json.Unmarshal(data, &groups); err != nil {
		panic(err)
	}
	packs := make([]officialEmojiPack, 0, len(groups))
	// 一批资源通常会同时重新发布，收集全部问题一次报清，免得发布时逐包试。
	var invalidPacks []string
	for _, group := range groups {
		pack := officialEmojiPack{ID: group.ID, Name: group.Name, Version: group.Version,
			AssetCount: len(group.Items), assets: make(map[string]stickerCatalogItem)}
		assets := make([]map[string]any, 0, len(group.Items))
		for _, item := range group.Items {
			content, err := stickerAssetFS.ReadFile("sticker_assets/" + item.File)
			if err != nil {
				panic(err)
			}
			config, _, err := image.DecodeConfig(bytes.NewReader(content))
			if err != nil {
				panic(err)
			}
			hash := sha256.Sum256(content)
			asset := map[string]any{"id": item.ID, "name": item.Label, "path": "assets/" + item.File,
				"sha256": hex.EncodeToString(hash[:]), "mime_type": item.MimeType, "file_size": len(content),
				"keywords": []string{}, "width": config.Width, "height": config.Height}
			if item.MimeType == "image/gif" {
				animation, err := gif.DecodeAll(bytes.NewReader(content))
				if err != nil {
					panic(err)
				}
				if len(animation.Image) > 1 {
					asset["animated"] = true
				}
			}
			assets = append(assets, asset)
			pack.TotalSize += len(content)
			pack.assets[item.ID] = item
		}
		// version 是发布流程人工递增的序号，content_sha256 只做内容不可变校验。
		if err := officialEmojiPackReleaseError(pack.ID, pack.Version, group.ContentSHA256, assets); err != nil {
			invalidPacks = append(invalidPacks, err.Error())
		}
		// encoding/json 对 map 键排序，与客户端 canonicalManifestBytes 保持一致。
		pack.manifest, err = json.Marshal(map[string]any{"schema_version": 1, "pack_id": pack.ID,
			"version": pack.Version, "total_size": pack.TotalSize, "assets": assets})
		if err != nil {
			panic(err)
		}
		hash := sha256.Sum256(pack.manifest)
		pack.ManifestSHA256 = hex.EncodeToString(hash[:])
		packs = append(packs, pack)
	}
	if len(invalidPacks) > 0 {
		panic(strings.Join(invalidPacks, "\n"))
	}
	return packs
}

// officialEmojiPackContent 是内容指纹的输入：只含包身份与已发布资源清单，
// 刻意不含 version，否则填摘要时要用摘要来算自己。
func officialEmojiPackContent(packID string, assets []map[string]any) []byte {
	content, err := json.Marshal(map[string]any{"pack_id": packID, "assets": assets})
	if err != nil {
		panic(err)
	}
	return content
}

// officialEmojiPackReleaseError 校验官方包的发布身份。version 是发布序号，
// content_sha256 绑定该版本对应的资源内容；资源变了却没登记新摘要会在这里报错，
// 避免出现「同版本不同内容」——客户端对同版本内容不可修改，会永远拿不到新资源。
func officialEmojiPackReleaseError(packID string, version int, contentSHA256 string, assets []map[string]any) error {
	if version < 1 {
		return fmt.Errorf("官方表情包 %s 缺少发布版本号", packID)
	}
	sum := sha256.Sum256(officialEmojiPackContent(packID, assets))
	digest := hex.EncodeToString(sum[:])
	if !strings.EqualFold(contentSHA256, digest) {
		return fmt.Errorf("官方表情包 %s 内容与 catalog.json 不一致：资源变化要先提升 version，再把 content_sha256 改成 %s", packID, digest)
	}
	return nil
}

func ListEmojiPacks(c *gin.Context) { c.JSON(http.StatusOK, officialEmojiPacks) }

func findOfficialEmojiPack(c *gin.Context) *officialEmojiPack {
	for i := range officialEmojiPacks {
		pack := &officialEmojiPacks[i]
		if pack.ID == c.Param("id") {
			if version := c.Query("version"); version != "" && version != strconv.Itoa(pack.Version) {
				c.Status(http.StatusNotFound)
				return nil
			}
			return pack
		}
	}
	c.Status(http.StatusNotFound)
	return nil
}

func GetEmojiPack(c *gin.Context) {
	if pack := findOfficialEmojiPack(c); pack != nil {
		c.JSON(http.StatusOK, pack)
	}
}

func GetEmojiPackManifest(c *gin.Context) {
	if pack := findOfficialEmojiPack(c); pack != nil {
		c.Header("ETag", `"`+pack.ManifestSHA256+`"`)
		c.Data(http.StatusOK, "application/json; charset=utf-8", pack.manifest)
	}
}

func GetEmojiPackAsset(c *gin.Context) {
	pack := findOfficialEmojiPack(c)
	if pack == nil {
		return
	}
	asset, ok := pack.assets[c.Param("assetId")]
	if !ok {
		c.Status(http.StatusNotFound)
		return
	}
	data, err := stickerAssetFS.ReadFile("sticker_assets/" + asset.File)
	if err != nil {
		c.Status(http.StatusNotFound)
		return
	}
	hash := sha256.Sum256(data)
	c.Header("ETag", `"`+hex.EncodeToString(hash[:])+`"`)
	c.Header("Content-Type", asset.MimeType)
	// ServeContent 提供 Range / If-Range，恢复任务可验证版本后续传。
	http.ServeContent(c.Writer, c.Request, asset.File, time.Time{}, bytes.NewReader(data))
}

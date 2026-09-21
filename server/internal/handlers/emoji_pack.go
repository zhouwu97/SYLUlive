package handlers

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"image"
	"image/gif"
	_ "image/jpeg"
	_ "image/png"
	"net/http"
	"strconv"
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
	for _, group := range groups {
		pack := officialEmojiPack{ID: group.ID, Name: group.Name,
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
		// encoding/json 对 map 键排序，与客户端 canonicalManifestBytes 保持一致。
		pack.Version = officialEmojiPackVersion(pack.ID, assets)
		pack.manifest, err = json.Marshal(map[string]any{"schema_version": 1, "pack_id": pack.ID,
			"version": pack.Version, "total_size": pack.TotalSize, "assets": assets})
		if err != nil {
			panic(err)
		}
		hash := sha256.Sum256(pack.manifest)
		pack.ManifestSHA256 = hex.EncodeToString(hash[:])
		packs = append(packs, pack)
	}
	return packs
}

// 官方包版本完全由发布内容推导：同一批资源在任何构建里得到同一个版本号，
// 资源字节一变版本就变。固定的版本常量会让重新发布的包撞上客户端
// 「同版本内容不可修改」的不可变规则，已安装的用户永远拿不到新内容。
func officialEmojiPackVersion(packID string, assets []map[string]any) int {
	content, err := json.Marshal(map[string]any{"pack_id": packID, "assets": assets})
	if err != nil {
		panic(err)
	}
	digest := sha256.Sum256(content)
	// 取高 47 位并置低 1 位：保持在 JSON 安全整数内，且版本号恒为正。
	return int(binary.BigEndian.Uint64(digest[:8])>>16) | 1
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

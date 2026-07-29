package handlers

import (
	"embed"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

//go:embed sticker_assets/*
var stickerAssetFS embed.FS

type stickerCatalogItem struct {
	ID       string `json:"id"`
	Label    string `json:"label"`
	File     string `json:"file"`
	MimeType string `json:"mime_type"`
}

type stickerCatalogGroup struct {
	ID    string               `json:"id"`
	Name  string               `json:"name"`
	Items []stickerCatalogItem `json:"items"`
}

var stickerAssets = mustLoadStickerAssets()

const stickerFallbackText = "[表情]"

func mustLoadStickerAssets() map[string]stickerCatalogItem {
	data, err := stickerAssetFS.ReadFile("sticker_assets/catalog.json")
	if err != nil {
		panic(fmt.Sprintf("读取表情目录失败: %v", err))
	}
	var groups []stickerCatalogGroup
	if err := json.Unmarshal(data, &groups); err != nil {
		panic(fmt.Sprintf("解析表情目录失败: %v", err))
	}
	assets := make(map[string]stickerCatalogItem)
	for _, group := range groups {
		for _, item := range group.Items {
			if item.ID == "" || item.File == "" || item.MimeType == "" {
				panic("表情目录包含不完整条目")
			}
			if _, exists := assets[item.ID]; exists {
				panic(fmt.Sprintf("表情 ID 重复: %s", item.ID))
			}
			assets[item.ID] = item
		}
	}
	return assets
}

// IsValidStickerID 判断客户端提交的公共表情是否在服务端白名单中。
func IsValidStickerID(stickerID string) bool {
	_, exists := stickerAssets[strings.TrimSpace(stickerID)]
	return exists
}

// ServeSticker 返回内嵌的高清公共表情。文件名由服务端白名单解析，不接收路径。
func ServeSticker(c *gin.Context) {
	stickerID := strings.TrimSpace(c.Param("id"))
	asset, exists := stickerAssets[stickerID]
	if !exists {
		c.Status(http.StatusNotFound)
		return
	}
	data, err := stickerAssetFS.ReadFile("sticker_assets/" + asset.File)
	if err != nil {
		c.Status(http.StatusNotFound)
		return
	}
	c.Header("Cache-Control", "public, max-age=31536000, immutable")
	c.Header("ETag", fmt.Sprintf("\"sticker-%s\"", stickerID))
	c.Data(http.StatusOK, asset.MimeType, data)
}

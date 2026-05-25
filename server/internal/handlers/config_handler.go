package handlers

import (
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	
	"shenliyuan/internal/models"
)

type ConfigHandler struct {
	db              *gorm.DB
	injectJSCache   string
	jsCacheMutex    sync.RWMutex
	lastRefreshTime time.Time
}

func NewConfigHandler(db *gorm.DB) *ConfigHandler {
	return &ConfigHandler{
		db: db,
	}
}

// GetInjectScript 下发拦截脚本给 Flutter 前端
func (h *ConfigHandler) GetInjectScript(c *gin.Context) {
	// 1. 尝试使用读锁从内存中获取缓存 (缓存有效期设为 5 分钟，避免每次查库)
	h.jsCacheMutex.RLock()
	if time.Since(h.lastRefreshTime) < 5*time.Minute && h.injectJSCache != "" {
		cacheStr := h.injectJSCache
		h.jsCacheMutex.RUnlock()
		c.JSON(http.StatusOK, gin.H{"success": true, "script": cacheStr})
		return
	}
	h.jsCacheMutex.RUnlock()

	// 2. 缓存过期或为空，使用写锁去数据库加载最新脚本
	h.jsCacheMutex.Lock()
	defer h.jsCacheMutex.Unlock()

	// 再次检查防止多个协程同时阻塞在 Lock 处时发生重复查库
	if time.Since(h.lastRefreshTime) < 5*time.Minute && h.injectJSCache != "" {
		c.JSON(http.StatusOK, gin.H{"success": true, "script": h.injectJSCache})
		return
	}

	var config models.SystemConfig
	// 假设我们在数据库里存的 key 是 "yuketang_inject_js"
	if err := h.db.Where("config_key = ?", "yuketang_inject_js").First(&config).Error; err != nil {
		// 为了防止前端出错，如果数据库没有，可以在此返回空脚本或报错
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取云端下发脚本失败"})
		return
	}

	// 3. 更新内存缓存
	h.injectJSCache = config.ConfigValue
	h.lastRefreshTime = time.Now()

	// 4. 返回最新脚本
	c.JSON(http.StatusOK, gin.H{"success": true, "script": h.injectJSCache})
}

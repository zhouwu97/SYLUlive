package handlers

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// YunkaoWalletHandler 融智云考助手钱包处理器
type YunkaoWalletHandler struct {
	db *gorm.DB
}

func NewYunkaoWalletHandler(db *gorm.DB) *YunkaoWalletHandler {
	return &YunkaoWalletHandler{db: db}
}

// GetWallet 获取当前用户钱包
func (h *YunkaoWalletHandler) GetWallet(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	var wallet models.YunkaoWallet
	if err := h.db.Where("user_id = ?", uid).First(&wallet).Error; err != nil {
		// 自动创建
		wallet = models.YunkaoWallet{UserID: uid, BalanceCents: 0}
		h.db.Create(&wallet)
	}

	// 同时获取可用模型列表（用于前端展示价格说明）
	var models []models.YunkaoAiModel
	h.db.Where("enabled = ?", true).Order("priority DESC, id ASC").Find(&models)

	c.JSON(http.StatusOK, gin.H{
		"wallet": gin.H{
			"balance_cents":        wallet.BalanceCents,
			"balance_yuan":         float64(wallet.BalanceCents) / 100.0,
			"total_recharged_cents": wallet.TotalRechargedCents,
			"total_spent_cents":    wallet.TotalSpentCents,
		},
		"models": models,
	})
}

// GetWalletLogs 获取钱包使用日志
func (h *YunkaoWalletHandler) GetWalletLogs(c *gin.Context) {
	userID, _ := c.Get("user_id")
	uid := userID.(uint)

	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 50 {
		pageSize = 20
	}

	var total int64
	h.db.Model(&models.YunkaoUsageLog{}).Where("user_id = ?", uid).Count(&total)

	var logs []models.YunkaoUsageLog
	h.db.Where("user_id = ?", uid).
		Order("created_at DESC").
		Offset((page - 1) * pageSize).
		Limit(pageSize).
		Find(&logs)

	// 也获取充值记录
	var orders []models.YunkaoRechargeOrder
	h.db.Where("user_id = ?", uid).
		Order("created_at DESC").
		Limit(10).
		Find(&orders)

	c.JSON(http.StatusOK, gin.H{
		"logs":       logs,
		"orders":     orders,
		"total":      total,
		"page":       page,
		"page_size":  pageSize,
	})
}

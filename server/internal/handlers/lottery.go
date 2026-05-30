package handlers

import (
	"net/http"
	"strconv"

	"shenliyuan/internal/models"
	"shenliyuan/internal/tasks"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

type LotteryHandler struct {
	db *gorm.DB
}

func NewLotteryHandler(db *gorm.DB) *LotteryHandler {
	return &LotteryHandler{db: db}
}

// GetCurrent 获取当前正在进行或最新的抽奖活动
func (h *LotteryHandler) GetCurrent(c *gin.Context) {
	var event models.LotteryEvent
	// 优先找进行中的，如果没有找最近已开奖的
	err := h.db.Order("status ASC, created_at DESC").Preload("Winner").First(&event).Error
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "暂无抽奖活动"})
		return
	}

	var participantCount int64
	h.db.Model(&models.LotteryParticipant{}).Where("lottery_id = ?", event.ID).Count(&participantCount)

	// 如果用户登录了，返回该用户的参与状态和权重
	var joined bool
	var myWeight int
	if userID, exists := c.Get("user_id"); exists {
		var p models.LotteryParticipant
		if err := h.db.Where("lottery_id = ? AND user_id = ?", event.ID, userID).First(&p).Error; err == nil {
			joined = true
			myWeight = p.Weight
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"event":             event,
		"participant_count": participantCount,
		"joined":            joined,
		"my_weight":         myWeight,
	})
}

// Join 参与抽奖
func (h *LotteryHandler) Join(c *gin.Context) {
	userID, _ := c.Get("user_id")
	eventID := c.Param("id")

	var event models.LotteryEvent
	if err := h.db.First(&event, eventID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "抽奖活动不存在"})
		return
	}

	if event.Status != 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该活动已结束或已开奖"})
		return
	}

	// 获取用户当前的经验值以计算权重
	var user models.User
	if err := h.db.Select("id", "exp").First(&user, userID).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "用户不存在"})
		return
	}

	// 计算权重：基础权重1 + (经验值/10)
	weight := 1 + (user.Exp / 10)

	participant := models.LotteryParticipant{
		LotteryID: event.ID,
		UserID:    user.ID,
		Weight:    weight,
	}

	// 尝试插入，依赖联合唯一索引防并发多刷
	if err := h.db.Create(&participant).Error; err != nil {
		// 违反唯一约束
		c.JSON(http.StatusConflict, gin.H{"error": "您已经参与过该抽奖活动了"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message": "参与成功",
		"weight":  weight,
	})
}

// Draw 管理员手动开奖
func (h *LotteryHandler) Draw(c *gin.Context) {
	eventIDStr := c.Param("id")
	eventID, err := strconv.ParseUint(eventIDStr, 10, 32)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的活动ID"})
		return
	}

	err = tasks.ExecuteDraw(h.db, uint(eventID))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "开奖成功"})
}

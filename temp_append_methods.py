import sys

content = open('e:/AI/xynewui/server/internal/handlers/super_admin.go', 'r', encoding='utf-8').read()
if 'GetLotteryParticipants' not in content:
    content += """
// GetLotteryParticipants 获取当前抽奖的参与者
func (h *SuperAdminHandler) GetLotteryParticipants(c *gin.Context) {
	var event models.LotteryEvent
	err := h.db.Order("status ASC, created_at DESC").First(&event).Error
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "暂无抽奖活动"})
		return
	}

	var participants []models.LotteryParticipant
	h.db.Where("lottery_id = ?", event.ID).Preload("User").Find(&participants)
	
	c.JSON(http.StatusOK, gin.H{
		"event": event,
		"participants": participants,
	})
}

// KickLotteryParticipant 踢出参与者
func (h *SuperAdminHandler) KickLotteryParticipant(c *gin.Context) {
	eventIDStr := c.Param("event_id")
	userIDStr := c.Param("user_id")

	eventID, err1 := strconv.ParseUint(eventIDStr, 10, 64)
	userID, err2 := strconv.ParseUint(userIDStr, 10, 64)

	if err1 != nil || err2 != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的参数"})
		return
	}

	result := h.db.Where("lottery_id = ? AND user_id = ?", eventID, userID).Delete(&models.LotteryParticipant{})
	if result.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "踢出失败"})
		return
	}

	if result.RowsAffected == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "该用户未参与该抽奖"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "已成功踢出"})
}
"""
    open('e:/AI/xynewui/server/internal/handlers/super_admin.go', 'w', encoding='utf-8').write(content)
    print("Methods appended successfully")

import sys
content = '''

// AiConfigInput AI 全局配置输入
type AiConfigInput struct {
	BaseURL   string `json:"base_url" binding:"required"`
	APIKey    string `json:"api_key" binding:"required"`
	ModelName string `json:"model_name" binding:"required"`
}

// GetAiConfig 获取全局 AI 配置
func (h *SuperAdminHandler) GetAiConfig(c *gin.Context) {
	configKeys := []string{"ai_base_url", "ai_api_key", "ai_model_name"}
	var configs []models.SystemConfig
	h.db.Where("config_key IN ?", configKeys).Find(&configs)

	configMap := make(map[string]string)
	for _, conf := range configs {
		configMap[conf.ConfigKey] = conf.ConfigValue
	}

	c.JSON(http.StatusOK, gin.H{
		"base_url":   configMap["ai_base_url"],
		"api_key":    configMap["ai_api_key"],
		"model_name": configMap["ai_model_name"],
	})
}

// UpdateAiConfig 更新全局 AI 配置
func (h *SuperAdminHandler) UpdateAiConfig(c *gin.Context) {
	var input AiConfigInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 开启事务更新三个键值对
	err := h.db.Transaction(func(tx *gorm.DB) error {
		configs := []models.SystemConfig{
			{ConfigKey: "ai_base_url", ConfigValue: input.BaseURL},
			{ConfigKey: "ai_api_key", ConfigValue: input.APIKey},
			{ConfigKey: "ai_model_name", ConfigValue: input.ModelName},
		}

		for _, conf := range configs {
			var existing models.SystemConfig
			if err := tx.Where("config_key = ?", conf.ConfigKey).First(&existing).Error; err != nil {
				// 没找到则插入
				if err := tx.Create(&conf).Error; err != nil {
					return err
				}
			} else {
				// 找到则更新
				if err := tx.Model(&existing).Update("config_value", conf.ConfigValue).Error; err != nil {
					return err
				}
			}
		}
		return nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "配置已保存"})
}
'''
with open('e:/AI/xynewui/server/internal/handlers/super_admin.go', 'a', encoding='utf-8') as f:
    f.write(content)
print('Done appending')

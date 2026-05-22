package handlers

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/go-resty/resty/v2"
	"gorm.io/gorm"
)

// ErkeHandler 二课处理器
type ErkeHandler struct {
	db *gorm.DB
}

// NewErkeHandler 创建二课处理器
func NewErkeHandler(db *gorm.DB) *ErkeHandler {
	return &ErkeHandler{db: db}
}

// ErkeQueryInput 二课查询输入
type ErkeQueryInput struct {
	VpnUsername  string `json:"vpn_username" binding:"required"`
	VpnPassword  string `json:"vpn_password" binding:"required"`
	ErkeUsername string `json:"erke_username" binding:"required"`
	ErkePassword string `json:"erke_password" binding:"required"`
}

// GetScores 获取二课成绩 (转发至 Python 爬虫服务)
//
// 超时策略:
//   - Python 爬虫单次抓取正常耗时 2~5 秒，内网拥堵时可能到 10 秒
//   - Go → Python 超时设为 15 秒，超过则熔断，向前端返回"教务系统响应超时"
func (h *ErkeHandler) GetScores(c *gin.Context) {
	var input ErkeQueryInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误: " + err.Error()})
		return
	}

	client := resty.New()
	// 15 秒超时: 正常 3~5s + 内网拥堵余量，避免前端无限等待
	client.SetTimeout(15 * time.Second)

	resp, err := client.R().
		SetHeader("Content-Type", "application/json").
		SetBody(input).
		Post(EduServiceConfig.BaseURL + "/erke/scores")

	if err != nil {
		// 区分超时与其他网络错误
		if strings.Contains(err.Error(), "timeout") ||
			strings.Contains(err.Error(), "Timeout") ||
			strings.Contains(err.Error(), "deadline") {
			c.JSON(http.StatusGatewayTimeout, gin.H{
				"error":   "教务系统响应超时，请稍后重试",
				"timeout": true,
			})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法连接爬虫服务，请检查网络"})
		return
	}

	if resp.StatusCode() != 200 {
		c.JSON(resp.StatusCode(), gin.H{"error": "查询失败，请检查账号密码或重试"})
		return
	}

	// 透传结果
	var result map[string]interface{}
	if err := json.Unmarshal(resp.Body(), &result); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "解析结果失败"})
		return
	}

	c.JSON(http.StatusOK, result)
}

package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/go-resty/resty/v2"
	"golang.org/x/sync/singleflight"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// AiSolveHandler AI答题处理器
type AiSolveHandler struct {
	db              *gorm.DB
	requestGroup    singleflight.Group
	restyClient     *resty.Client
	
	// 默认配置 (兜底)
	defaultAPIKey   string
	defaultBaseURL  string
	
	// 动态配置缓存
	configMutex     sync.RWMutex
	cachedBaseURL   string
	cachedAPIKey    string
	cachedModel     string
	lastConfigFetch time.Time
}

// NewAiSolveHandler 创建AI答题处理器
func NewAiSolveHandler(db *gorm.DB, apiKey, baseURL string) *AiSolveHandler {
	return &AiSolveHandler{
		db:              db,
		restyClient:     resty.New(),
		defaultAPIKey:   apiKey,
		defaultBaseURL:  baseURL,
	}
}

// SolveRequest 请求结构
type SolveRequest struct {
	QuestionType string      `json:"question_type"`
	RawContent   interface{} `json:"raw_content"`  // 原始题目JSON
	ContentText  string      `json:"content_text"` // 提取出来的题干和选项，用于计算hash
}

// cleanText 文本预处理：去除首尾空格、换行符，将连续空格替换为单空格
func cleanText(text string) string {
	text = strings.TrimSpace(text)
	text = strings.ReplaceAll(text, "\n", "")
	text = strings.ReplaceAll(text, "\r", "")

	re := regexp.MustCompile(`\s+`)
	text = re.ReplaceAllString(text, " ")
	return text
}

// generateHash 计算 SHA256
func generateHash(qType, content string) string {
	hash := sha256.New()
	hash.Write([]byte(qType + "|" + content))
	return hex.EncodeToString(hash.Sum(nil))
}

// getAiConfig 获取全局AI配置（带缓存和读写锁）
func (h *AiSolveHandler) getAiConfig() (baseURL, apiKey, modelName string) {
	h.configMutex.RLock()
	if time.Since(h.lastConfigFetch) < 1*time.Minute && h.cachedAPIKey != "" {
		baseURL = h.cachedBaseURL
		apiKey = h.cachedAPIKey
		modelName = h.cachedModel
		h.configMutex.RUnlock()
		return
	}
	h.configMutex.RUnlock()

	h.configMutex.Lock()
	defer h.configMutex.Unlock()

	if time.Since(h.lastConfigFetch) < 1*time.Minute && h.cachedAPIKey != "" {
		return h.cachedBaseURL, h.cachedAPIKey, h.cachedModel
	}

	configKeys := []string{"ai_base_url", "ai_api_key", "ai_model_name"}
	var configs []models.SystemConfig
	h.db.Where("config_key IN ?", configKeys).Find(&configs)

	configMap := make(map[string]string)
	for _, conf := range configs {
		configMap[conf.ConfigKey] = conf.ConfigValue
	}

	h.cachedBaseURL = configMap["ai_base_url"]
	h.cachedAPIKey = configMap["ai_api_key"]
	h.cachedModel = configMap["ai_model_name"]

	// 兜底配置
	if h.cachedBaseURL == "" {
		h.cachedBaseURL = h.defaultBaseURL
	}
	if h.cachedAPIKey == "" {
		h.cachedAPIKey = h.defaultAPIKey
	}
	if h.cachedModel == "" {
		h.cachedModel = "deepseek-v4-flash" // 默认模型更新为v4
	}
	h.lastConfigFetch = time.Now()

	return h.cachedBaseURL, h.cachedAPIKey, h.cachedModel
}

// callAI 直接调用大模型 (兼容 OpenAI API)
func (h *AiSolveHandler) callAI(baseURL, apiKey, modelName, questionType, cleanedText string) (string, error) {
	prompt := fmt.Sprintf(`你是一个专业的大学辅助答题助手。
【重点警告】如果是选择题，千万不要只输出 ABCD 字母（因为系统的选项字母顺序通常会随机打乱）！你必须直接输出正确选项的【完整文字内容】！多道题请按顺序标号输出文本。绝对不要包含任何解析或废话。
题型：%s
题目内容：%s
`, questionType, cleanedText)

	reqBody := map[string]interface{}{
		"model": modelName,
		"messages": []map[string]string{
			{
				"role":    "user",
				"content": prompt,
			},
		},
		"temperature": 0.1,
	}

	endpoint := strings.TrimRight(baseURL, "/") + "/chat/completions"
	resp, err := h.restyClient.R().
		SetHeader("Content-Type", "application/json").
		SetHeader("Authorization", "Bearer "+apiKey).
		SetBody(reqBody).
		Post(endpoint)

	if err != nil {
		return "", err
	}
	if resp.IsError() {
		return "", fmt.Errorf("API 错误: %s", resp.String())
	}

	var result struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}

	if err := json.Unmarshal(resp.Body(), &result); err != nil {
		return "", fmt.Errorf("解析结果失败: %v", err)
	}

	if len(result.Choices) == 0 {
		return "", fmt.Errorf("AI 返回结果为空")
	}

	return strings.TrimSpace(result.Choices[0].Message.Content), nil
}

// Solve 处理答题请求
func (h *AiSolveHandler) Solve(c *gin.Context) {
	// 获取当前登录用户
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未登录"})
		return
	}
	uid := userID.(uint)

	var req SolveRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	// 白名单：特定用户不扣费
	var user models.User
	h.db.First(&user, uid)
	isFreeUser := user.StudentID == "2403060128" || user.Role == "admin" || user.Role == "super_admin"

	// 1. 文本预处理与 Hash 计算
	cleanedText := cleanText(req.ContentText)
	questionHash := generateHash(req.QuestionType, cleanedText)

	// 第一步：扣费
	if !isFreeUser {
		result := h.db.Exec("UPDATE users SET credits = credits - 1 WHERE id = ? AND credits > 0", uid)
		if result.Error != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "扣费失败"})
			return
		}
		if result.RowsAffected == 0 {
			c.JSON(http.StatusForbidden, gin.H{"error": "积分不足"})
			return
		}
	}

	// 第二步：查本地题库 (CachedQuestion)
	var cached models.CachedQuestion
	if err := h.db.Where("question_hash = ?", questionHash).First(&cached).Error; err == nil {
		// 查到答案，直接返回（流程结束，钱已扣）
		c.JSON(http.StatusOK, gin.H{
			"success": true,
			"source":  "cache",
			"answer":  cached.AiAnswer,
		})
		return
	}

	// 第三步：进入并发控制 (singleflight)
	val, err, _ := h.requestGroup.Do(questionHash, func() (interface{}, error) {
		// 在 Do 内部，执行双重检查锁，再查一次本地题库
		var doubleCheck models.CachedQuestion
		if err := h.db.Where("question_hash = ?", questionHash).First(&doubleCheck).Error; err == nil {
			return doubleCheck.AiAnswer, nil
		}

		// 第四步：直连大模型
		baseURL, apiKey, modelName := h.getAiConfig()
		
		answer, err := h.callAI(baseURL, apiKey, modelName, req.QuestionType, cleanedText)
		if err != nil {
			return nil, err
		}

		rawJsonBytes, _ := json.Marshal(req.RawContent)

		// 拿到答案后，写入 cached_questions 表
		newCache := models.CachedQuestion{
			QuestionHash: questionHash,
			QuestionType: req.QuestionType,
			RawContent:   string(rawJsonBytes),
			AiAnswer:     answer,
		}

		if err := h.db.Create(&newCache).Error; err != nil {
			fmt.Printf("写入题库缓存失败: %v\n", err)
		}

		return answer, nil
	})

	if err != nil {
		// 第五步：失败补偿
		if !isFreeUser {
			h.db.Exec("UPDATE users SET credits = credits + 1 WHERE id = ?", uid)
		}

		c.JSON(http.StatusInternalServerError, gin.H{
			"error":  "AI处理失败，积分已退还",
			"detail": err.Error(),
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"success": true,
		"source":  "ai",
		"answer":  val.(string),
	})
}

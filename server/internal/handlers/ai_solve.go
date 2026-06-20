package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/go-resty/resty/v2"
	"golang.org/x/sync/singleflight"
	"golang.org/x/time/rate"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// AiSolveHandler AI答题处理器
type AiSolveHandler struct {
	db           *gorm.DB
	requestGroup singleflight.Group
	restyClient  *resty.Client

	// 默认配置 (兜底)
	defaultAPIKey  string
	defaultBaseURL string

	// 动态配置缓存
	configMutex                 sync.RWMutex
	cachedBaseURL               string
	cachedAPIKey                string
	cachedModel                 string
	cachedInputPricePer1KCents  int
	cachedOutputPricePer1KCents int
	cachedCacheHitPriceCents    int
	cachedMinLivePriceCents     int
	lastConfigFetch             time.Time
}

var aiRateLimiters = sync.Map{}

var (
	reWhitespace  = regexp.MustCompile(`\s+`)
	reImgTag      = regexp.MustCompile(`<img[^>]+(?:src|data-src)=\\?["'](https?://[^"'\\]+)\\?["']`)
	reDirectLink  = regexp.MustCompile(`https?://[^"'\\]+(?:storage\.yuketang\.cn|qn-storage)[^"'\\]+|https?://[^"'\\]+\.(?:png|jpg|jpeg|webp|gif|bmp)(?:\?[^"'\\]*)?`)
	reIndexTarget = regexp.MustCompile(`"__originalIndex":\d+,?`)
)

func getAiRateLimiter(uid uint) *rate.Limiter {
	// 每小时 10 次限制
	limiter, _ := aiRateLimiters.LoadOrStore(uid, rate.NewLimiter(rate.Every(time.Hour/10), 10))
	return limiter.(*rate.Limiter)
}

// NewAiSolveHandler 创建AI答题处理器
func NewAiSolveHandler(db *gorm.DB, apiKey, baseURL string) *AiSolveHandler {
	return &AiSolveHandler{
		db:             db,
		restyClient:    resty.New(),
		defaultAPIKey:  apiKey,
		defaultBaseURL: baseURL,
	}
}

// SolveRequest 请求结构
type SolveRequest struct {
	QuestionType string      `json:"question_type"`
	RawContent   interface{} `json:"raw_content"`   // 原始题目JSON
	ContentText  string      `json:"content_text"`  // 提取出来的题干和选项，用于计算hash
	ForceRefresh bool        `json:"force_refresh"` // true 时跳过缓存直接问 AI
	SaveToCache  *bool       `json:"save_to_cache"` // nil 走默认策略
}

type CacheReviewRequest struct {
	QuestionType string      `json:"question_type" binding:"required"`
	RawContent   interface{} `json:"raw_content" binding:"required"`
	ContentText  string      `json:"content_text" binding:"required"`
	Answer       string      `json:"answer"`
	Reason       string      `json:"reason"`
}

type aiRuntimeConfig struct {
	BaseURL               string
	APIKey                string
	ModelName             string
	InputPricePer1KCents  int
	OutputPricePer1KCents int
	CacheHitPriceCents    int
	MinLivePriceCents     int
}

type aiCallResult struct {
	Answer           string
	PromptTokens     int
	CompletionTokens int
	TotalTokens      int
}

type aiSolveResult struct {
	Answer               string
	PromptTokens         int
	CompletionTokens     int
	TotalTokens          int
	Source               string
	Provider             string
	ModelName            string
	CacheReferenceTokens int
}

// cleanText 文本预处理：去除首尾空格、换行符，将连续空格替换为单空格
func cleanText(text string) string {
	text = strings.TrimSpace(text)
	text = strings.ReplaceAll(text, "\n", "")
	text = strings.ReplaceAll(text, "\r", "")

	text = reWhitespace.ReplaceAllString(text, " ")
	return text
}

// generateHash 计算 SHA256
func generateHash(qType, content string) string {
	hash := sha256.New()
	hash.Write([]byte(qType + "|" + content + "|v2")) // 强制更新缓存
	return hex.EncodeToString(hash.Sum(nil))
}

func buildQuestionHash(req SolveRequest) (string, string) {
	cleanedText := cleanText(req.ContentText)
	hashText := reIndexTarget.ReplaceAllString(cleanedText, "")
	return cleanedText, generateHash(req.QuestionType, hashText)
}

func shouldSaveToCache(req SolveRequest) bool {
	if req.ForceRefresh {
		return req.SaveToCache != nil && *req.SaveToCache
	}
	if req.SaveToCache == nil {
		return true
	}
	return *req.SaveToCache
}

func parseIntConfig(raw string, fallback int) int {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value <= 0 {
		return fallback
	}
	return value
}

func detectProvider(baseURL string) string {
	url := strings.ToLower(baseURL)
	switch {
	case strings.Contains(url, "deepseek"):
		return "deepseek"
	case strings.Contains(url, "moonshot"):
		return "kimi"
	case strings.Contains(url, "bigmodel"):
		return "glm"
	case strings.Contains(url, "dashscope"):
		return "qwen"
	case strings.Contains(url, "xiaomi"), strings.Contains(url, "mimo"):
		return "mimo"
	case strings.Contains(url, "openai"):
		return "openai"
	default:
		return "custom"
	}
}

func estimateTokenCount(text string) int {
	runeCount := len([]rune(strings.TrimSpace(text)))
	if runeCount == 0 {
		return 0
	}
	return int(math.Ceil(float64(runeCount) / 2.2))
}

func estimateCompletionTokens(qCount int) int {
	if qCount <= 1 {
		return 96
	}
	return 80 * qCount
}

func estimateReservedAmountCents(cfg aiRuntimeConfig, cleanedText string, qCount int) int {
	estimatedPrompt := int(math.Ceil(float64(estimateTokenCount(cleanedText))*1.35)) + 60
	estimatedCompletion := int(math.Ceil(float64(estimateCompletionTokens(qCount)) * 1.4))
	estimated := int(math.Ceil(float64(estimatedPrompt*cfg.InputPricePer1KCents)/1000.0 +
		float64(estimatedCompletion*cfg.OutputPricePer1KCents)/1000.0))
	if estimated < cfg.MinLivePriceCents {
		return cfg.MinLivePriceCents
	}
	return estimated
}

func calculateLiveAmountCents(cfg aiRuntimeConfig, promptTokens, completionTokens int) int {
	if promptTokens < 0 {
		promptTokens = 0
	}
	if completionTokens < 0 {
		completionTokens = 0
	}
	total := int(math.Ceil(float64(promptTokens*cfg.InputPricePer1KCents)/1000.0 +
		float64(completionTokens*cfg.OutputPricePer1KCents)/1000.0))
	if total < cfg.MinLivePriceCents {
		return cfg.MinLivePriceCents
	}
	return total
}

func normalizeUsage(promptTokens, completionTokens, totalTokens int, cleanedText, answer string) (int, int, int) {
	if promptTokens <= 0 {
		promptTokens = estimateTokenCount(cleanedText)
	}
	if completionTokens <= 0 {
		completionTokens = estimateTokenCount(answer)
	}
	if totalTokens <= 0 {
		totalTokens = promptTokens + completionTokens
	}
	return promptTokens, completionTokens, totalTokens
}

func (h *AiSolveHandler) recordUsageLog(uid uint, req SolveRequest, questionHash string, result aiSolveResult, billedAmountCents, reservedAmountCents, balanceAfterCents int) {
	entry := models.AiUsageLog{
		UserID:              uid,
		QuestionHash:        questionHash,
		QuestionType:        req.QuestionType,
		Source:              result.Source,
		Provider:            result.Provider,
		ModelName:           result.ModelName,
		PromptTokens:        result.PromptTokens,
		CompletionTokens:    result.CompletionTokens,
		TotalTokens:         result.TotalTokens,
		BilledAmountCents:   billedAmountCents,
		ReservedAmountCents: reservedAmountCents,
		BalanceAfterCents:   balanceAfterCents,
		CacheHit:            result.Source == "cache",
	}
	if err := h.db.Create(&entry).Error; err != nil {
		log.Printf("[AI Solve] 写入 AI usage log 失败: %v", err)
	}
}

// getAiConfig 获取全局AI配置（带缓存和读写锁）
func (h *AiSolveHandler) getAiConfig() aiRuntimeConfig {
	h.configMutex.RLock()
	if time.Since(h.lastConfigFetch) < 1*time.Minute && h.cachedAPIKey != "" {
		cfg := aiRuntimeConfig{
			BaseURL:               h.cachedBaseURL,
			APIKey:                h.cachedAPIKey,
			ModelName:             h.cachedModel,
			InputPricePer1KCents:  h.cachedInputPricePer1KCents,
			OutputPricePer1KCents: h.cachedOutputPricePer1KCents,
			CacheHitPriceCents:    h.cachedCacheHitPriceCents,
			MinLivePriceCents:     h.cachedMinLivePriceCents,
		}
		h.configMutex.RUnlock()
		return cfg
	}
	h.configMutex.RUnlock()

	h.configMutex.Lock()
	defer h.configMutex.Unlock()

	if time.Since(h.lastConfigFetch) < 1*time.Minute && h.cachedAPIKey != "" {
		return aiRuntimeConfig{
			BaseURL:               h.cachedBaseURL,
			APIKey:                h.cachedAPIKey,
			ModelName:             h.cachedModel,
			InputPricePer1KCents:  h.cachedInputPricePer1KCents,
			OutputPricePer1KCents: h.cachedOutputPricePer1KCents,
			CacheHitPriceCents:    h.cachedCacheHitPriceCents,
			MinLivePriceCents:     h.cachedMinLivePriceCents,
		}
	}

	configKeys := []string{
		"ai_base_url",
		"ai_api_key",
		"ai_model_name",
		"ai_input_price_per_1m_cents",
		"ai_output_price_per_1m_cents",
		"ai_input_price_per_1k_cents",
		"ai_output_price_per_1k_cents",
		"ai_cache_hit_price_cents",
		"ai_min_live_price_cents",
	}
	var configs []models.SystemConfig
	if err := h.db.Where("config_key IN ?", configKeys).Find(&configs).Error; err != nil {
		log.Printf("[DB_ERROR] getAiConfig Find failed: %v", err)
	}

	configMap := make(map[string]string)
	for _, conf := range configs {
		configMap[conf.ConfigKey] = conf.ConfigValue
	}

	h.cachedBaseURL = configMap["ai_base_url"]
	h.cachedAPIKey = configMap["ai_api_key"]
	h.cachedModel = configMap["ai_model_name"]
	inputPricePer1K := parseIntConfig(configMap["ai_input_price_per_1k_cents"], 0)
	if inputPricePer1K <= 0 {
		legacyPer1M := parseIntConfig(configMap["ai_input_price_per_1m_cents"], 0)
		if legacyPer1M > 0 {
			inputPricePer1K = int(math.Ceil(float64(legacyPer1M) / 1000.0))
		}
	}
	if inputPricePer1K <= 0 {
		inputPricePer1K = 2
	}

	outputPricePer1K := parseIntConfig(configMap["ai_output_price_per_1k_cents"], 0)
	if outputPricePer1K <= 0 {
		legacyPer1M := parseIntConfig(configMap["ai_output_price_per_1m_cents"], 0)
		if legacyPer1M > 0 {
			outputPricePer1K = int(math.Ceil(float64(legacyPer1M) / 1000.0))
		}
	}
	if outputPricePer1K <= 0 {
		outputPricePer1K = 4
	}

	h.cachedInputPricePer1KCents = inputPricePer1K
	h.cachedOutputPricePer1KCents = outputPricePer1K
	h.cachedCacheHitPriceCents = parseIntConfig(configMap["ai_cache_hit_price_cents"], 1)
	h.cachedMinLivePriceCents = parseIntConfig(configMap["ai_min_live_price_cents"], 2)

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

	return aiRuntimeConfig{
		BaseURL:               h.cachedBaseURL,
		APIKey:                h.cachedAPIKey,
		ModelName:             h.cachedModel,
		InputPricePer1KCents:  h.cachedInputPricePer1KCents,
		OutputPricePer1KCents: h.cachedOutputPricePer1KCents,
		CacheHitPriceCents:    h.cachedCacheHitPriceCents,
		MinLivePriceCents:     h.cachedMinLivePriceCents,
	}
}

// callAI 直接调用大模型 (兼容 OpenAI API)
func (h *AiSolveHandler) callAI(baseURL, apiKey, modelName, questionType, cleanedText string) (aiCallResult, error) {
	prompt := fmt.Sprintf(`你是一个专业的大学辅助答题助手。
【重点警告】如果是选择题，请输出正确选项的字母和【完整文字内容】。如果选项是纯图片，或者你无法用文字描述，请务必输出对应选项的字母（如 A、B、C、D）。
【关键：题号匹配】我传给你的题目 JSON 中可能带有一个 "__originalIndex" 字段。在输出多道题的答案时，你的编号必须严格等于该题目的 "__originalIndex" 的值（例如："17. A 选项文字"，"18. B"），绝对不能自己从 1 开始顺延编号！
绝对不要包含任何解析或废话。
题型：%s
题目内容：%s`, questionType, cleanedText)

	// 提取图片 URL
	matches1 := reImgTag.FindAllStringSubmatch(cleanedText, -1)

	// 提取雨课堂 OSS 图片和独立图片链接
	matches2 := reDirectLink.FindAllString(cleanedText, -1)

	imageUrlSet := make(map[string]bool)
	var imageUrls []string

	for _, m := range matches1 {
		if len(m) > 1 {
			url := m[1]
			if !imageUrlSet[url] {
				imageUrlSet[url] = true
				imageUrls = append(imageUrls, url)
			}
		}
	}
	for _, url := range matches2 {
		url = strings.TrimRight(url, `\.,;"`)
		if !imageUrlSet[url] {
			imageUrlSet[url] = true
			imageUrls = append(imageUrls, url)
		}
	}

	var reqBody map[string]interface{}

	if len(imageUrls) > 0 {
		// 多模态 Vision 格式
		contentArray := []map[string]interface{}{
			{
				"type": "text",
				"text": prompt,
			},
		}
		for _, url := range imageUrls {
			contentArray = append(contentArray, map[string]interface{}{
				"type": "image_url",
				"image_url": map[string]string{
					"url": url,
				},
			})
		}

		reqBody = map[string]interface{}{
			"model": modelName,
			"messages": []map[string]interface{}{
				{
					"role":    "user",
					"content": contentArray,
				},
			},
			"temperature": 0.1,
		}
	} else {
		// 纯文本格式
		reqBody = map[string]interface{}{
			"model": modelName,
			"messages": []map[string]string{
				{
					"role":    "user",
					"content": prompt,
				},
			},
			"temperature": 0.1,
		}
	}

	endpoint := strings.TrimRight(baseURL, "/") + "/chat/completions"
	resp, err := h.restyClient.R().
		SetHeader("Content-Type", "application/json").
		SetHeader("Authorization", "Bearer "+apiKey).
		SetBody(reqBody).
		Post(endpoint)

	if err != nil {
		return aiCallResult{}, err
	}
	if resp.IsError() {
		return aiCallResult{}, fmt.Errorf("API 错误: %s", resp.String())
	}

	var result struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			PromptTokens     int `json:"prompt_tokens"`
			CompletionTokens int `json:"completion_tokens"`
			TotalTokens      int `json:"total_tokens"`
		} `json:"usage"`
	}

	if err := json.Unmarshal(resp.Body(), &result); err != nil {
		return aiCallResult{}, fmt.Errorf("解析结果失败: %v", err)
	}

	if len(result.Choices) == 0 {
		return aiCallResult{}, fmt.Errorf("AI 返回结果为空")
	}

	answer := strings.TrimSpace(result.Choices[0].Message.Content)
	promptTokens, completionTokens, totalTokens := normalizeUsage(
		result.Usage.PromptTokens,
		result.Usage.CompletionTokens,
		result.Usage.TotalTokens,
		cleanedText,
		answer,
	)

	return aiCallResult{
		Answer:           answer,
		PromptTokens:     promptTokens,
		CompletionTokens: completionTokens,
		TotalTokens:      totalTokens,
	}, nil
}

// countQuestions 递归统计 JSON 中的题目数量
func countQuestions(data interface{}) int {
	count := 0
	switch v := data.(type) {
	case []interface{}:
		if len(v) > 0 {
			if obj, ok := v[0].(map[string]interface{}); ok {
				_, hasOptions := obj["options"]
				_, hasProblemID := obj["problem_id"]
				_, hasProblemID2 := obj["problemId"]
				_, hasContent := obj["content"]
				_, hasBody := obj["body"]
				if hasOptions || hasProblemID || hasProblemID2 || hasContent || hasBody {
					return len(v)
				}
			}
		}
		for _, item := range v {
			count += countQuestions(item)
		}
	case map[string]interface{}:
		for _, item := range v {
			count += countQuestions(item)
		}
	}
	return count
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

	// AI 解题速率限制：每人每小时 10 次
	limiter := getAiRateLimiter(uid)
	if !limiter.Allow() {
		c.JSON(http.StatusTooManyRequests, gin.H{"error": "接口调用频率过高，每小时最多允许 10 次调用"})
		return
	}

	var req SolveRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	// 白名单：特定用户不扣费
	var user models.User
	if err := h.db.First(&user, uid).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "无效用户"})
		return
	}
	isFreeUser := user.Role == "admin" || user.Role == "super_admin"

	// 1. 文本预处理与 Hash 计算
	cleanedText, questionHash := buildQuestionHash(req)

	log.Printf("[AI Solve] 收到请求: 用户 %d, 题型: %s, 原始题目长度: %d", uid, req.QuestionType, len(cleanedText))
	log.Printf("[AI Solve] 计算题库 Hash: %s (剔除 originalIndex 后)", questionHash)

	// 题目数量限制
	qCount := countQuestions(req.RawContent)
	if qCount == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "未检测到有效题目"})
		return
	}
	if qCount > 5 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "一次最多只能请求5道题，请分批提交"})
		return
	}
	cfg := h.getAiConfig()
	provider := detectProvider(cfg.BaseURL)

	// 第一步：查本地题库 (CachedQuestion)
	var cached models.CachedQuestion
	if !req.ForceRefresh && h.db.Where("question_hash = ? AND is_disabled = ?", questionHash, false).First(&cached).Error == nil {
		log.Printf("[AI Solve] ⚡ 命中本地缓存！ Hash: %s", questionHash)

		billedAmountCents := 0
		if !isFreeUser && cfg.CacheHitPriceCents > 0 {
			result := h.db.Exec(
				"UPDATE users SET ai_balance_cents = ai_balance_cents - ? WHERE id = ? AND ai_balance_cents >= ?",
				cfg.CacheHitPriceCents, uid, cfg.CacheHitPriceCents,
			)
			if result.Error != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "缓存命中扣费失败"})
				return
			}
			if result.RowsAffected == 0 {
				c.JSON(http.StatusForbidden, gin.H{"error": fmt.Sprintf("余额不足，缓存命中本次需要 ¥%.2f", float64(cfg.CacheHitPriceCents)/100.0)})
				return
			}
			billedAmountCents = cfg.CacheHitPriceCents
			user.AiBalanceCents -= billedAmountCents
		}

		cacheProvider := cached.Provider
		if cacheProvider == "" {
			cacheProvider = provider
		}
		cacheModel := cached.ModelName
		if cacheModel == "" {
			cacheModel = cfg.ModelName
		}

		result := aiSolveResult{
			Answer:               cached.AiAnswer,
			Source:               "cache",
			Provider:             cacheProvider,
			ModelName:            cacheModel,
			CacheReferenceTokens: cached.TotalTokens,
		}
		h.recordUsageLog(uid, req, questionHash, result, billedAmountCents, 0, user.AiBalanceCents)
		c.JSON(http.StatusOK, gin.H{
			"success": true,
			"source":  "cache",
			"answer":  cached.AiAnswer,
			"usage": gin.H{
				"prompt_tokens":          0,
				"completion_tokens":      0,
				"total_tokens":           0,
				"cache_reference_tokens": cached.TotalTokens,
			},
			"billing": gin.H{
				"billed_amount_cents": billedAmountCents,
				"billed_amount_yuan":  float64(billedAmountCents) / 100.0,
				"balance_after_cents": user.AiBalanceCents,
				"balance_after_yuan":  float64(user.AiBalanceCents) / 100.0,
			},
		})
		return
	}
	log.Printf("[AI Solve] ❌ 未命中缓存，准备调用 AI，Hash: %s", questionHash)

	// 第二步：预扣积分，待拿到真实 token 后再结算
	reservedAmountCents := 0
	if !isFreeUser {
		reservedAmountCents = estimateReservedAmountCents(cfg, cleanedText, qCount)
		log.Printf("[AI Solve] 检测到题目数量: %d, 预扣金额(分): %d", qCount, reservedAmountCents)
		result := h.db.Exec(
			"UPDATE users SET ai_balance_cents = ai_balance_cents - ? WHERE id = ? AND ai_balance_cents >= ?",
			reservedAmountCents, uid, reservedAmountCents,
		)
		if result.Error != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "预扣余额失败"})
			return
		}
		if result.RowsAffected == 0 {
			c.JSON(http.StatusForbidden, gin.H{"error": fmt.Sprintf("余额不足，本次请求至少需要 ¥%.2f", float64(reservedAmountCents)/100.0)})
			return
		}
		user.AiBalanceCents -= reservedAmountCents
	}

	// 第三步：进入并发控制 (singleflight)
	val, err, _ := h.requestGroup.Do(questionHash, func() (interface{}, error) {
		// 在 Do 内部，执行双重检查锁，再查一次本地题库
		var doubleCheck models.CachedQuestion
		if !req.ForceRefresh && h.db.Where("question_hash = ? AND is_disabled = ?", questionHash, false).First(&doubleCheck).Error == nil {
			doubleProvider := doubleCheck.Provider
			if doubleProvider == "" {
				doubleProvider = provider
			}
			doubleModel := doubleCheck.ModelName
			if doubleModel == "" {
				doubleModel = cfg.ModelName
			}
			return aiSolveResult{
				Answer:               doubleCheck.AiAnswer,
				Source:               "cache",
				Provider:             doubleProvider,
				ModelName:            doubleModel,
				CacheReferenceTokens: doubleCheck.TotalTokens,
			}, nil
		}

		// 第四步：直连大模型
		callResult, err := h.callAI(cfg.BaseURL, cfg.APIKey, cfg.ModelName, req.QuestionType, cleanedText)
		if err != nil {
			return nil, err
		}

		rawJsonBytes, _ := json.Marshal(req.RawContent)

		if shouldSaveToCache(req) {
			newCache := models.CachedQuestion{
				QuestionHash:     questionHash,
				QuestionType:     req.QuestionType,
				RawContent:       string(rawJsonBytes),
				AiAnswer:         callResult.Answer,
				ModelName:        cfg.ModelName,
				Provider:         provider,
				PromptTokens:     callResult.PromptTokens,
				CompletionTokens: callResult.CompletionTokens,
				TotalTokens:      callResult.TotalTokens,
				IsDisabled:       false,
			}

			var existing models.CachedQuestion
			if err := h.db.Where("question_hash = ?", questionHash).First(&existing).Error; err == nil {
				if err := h.db.Model(&existing).Updates(map[string]interface{}{
					"question_type":     req.QuestionType,
					"raw_content":       string(rawJsonBytes),
					"ai_answer":         callResult.Answer,
					"model_name":        cfg.ModelName,
					"provider":          provider,
					"prompt_tokens":     callResult.PromptTokens,
					"completion_tokens": callResult.CompletionTokens,
					"total_tokens":      callResult.TotalTokens,
					"is_disabled":       false,
					"updated_at":        time.Now(),
				}).Error; err != nil {
					log.Printf("更新题库缓存失败: %v", err)
				}
			} else if err := h.db.Create(&newCache).Error; err != nil {
				log.Printf("写入题库缓存失败: %v", err)
			}
		}

		return aiSolveResult{
			Answer:           callResult.Answer,
			PromptTokens:     callResult.PromptTokens,
			CompletionTokens: callResult.CompletionTokens,
			TotalTokens:      callResult.TotalTokens,
			Source:           "ai",
			Provider:         provider,
			ModelName:        cfg.ModelName,
		}, nil
	})

	if err != nil {
		// 第五步：失败补偿
		if !isFreeUser {
			if err := h.db.Exec("UPDATE users SET ai_balance_cents = ai_balance_cents + ? WHERE id = ?", reservedAmountCents, uid).Error; err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
				return
			}
		}

		c.JSON(http.StatusInternalServerError, gin.H{
			"error":  "AI处理失败，余额已退还",
			"detail": err.Error(),
		})
		return
	}

	result := val.(aiSolveResult)
	billedAmountCents := 0
	if !isFreeUser {
		if result.Source == "cache" {
			billedAmountCents = cfg.CacheHitPriceCents
		} else {
			billedAmountCents = calculateLiveAmountCents(cfg, result.PromptTokens, result.CompletionTokens)
		}

		if billedAmountCents > reservedAmountCents {
			diff := billedAmountCents - reservedAmountCents
			extra := h.db.Exec("UPDATE users SET ai_balance_cents = ai_balance_cents - ? WHERE id = ? AND ai_balance_cents >= ?", diff, uid, diff)
			if extra.Error != nil {
				log.Printf("[AI Solve] 补扣余额失败: %v", extra.Error)
				billedAmountCents = reservedAmountCents
			} else if extra.RowsAffected == 0 {
				log.Printf("[AI Solve] 用户 %d 余额不足以补扣差额 %d 分，按预扣金额结算", uid, diff)
				billedAmountCents = reservedAmountCents
			} else {
				user.AiBalanceCents -= diff
			}
		} else if billedAmountCents < reservedAmountCents {
			refund := reservedAmountCents - billedAmountCents
			if refund > 0 {
				if err := h.db.Exec("UPDATE users SET ai_balance_cents = ai_balance_cents + ? WHERE id = ?", refund, uid).Error; err != nil {
					log.Printf("[AI Solve] 返还余额失败: %v", err)
				} else {
					user.AiBalanceCents += refund
				}
			}
		}
	}

	h.recordUsageLog(uid, req, questionHash, result, billedAmountCents, reservedAmountCents, user.AiBalanceCents)
	c.JSON(http.StatusOK, gin.H{
		"success": true,
		"source":  result.Source,
		"answer":  result.Answer,
		"usage": gin.H{
			"prompt_tokens":          result.PromptTokens,
			"completion_tokens":      result.CompletionTokens,
			"total_tokens":           result.TotalTokens,
			"cache_reference_tokens": result.CacheReferenceTokens,
		},
		"billing": gin.H{
			"billed_amount_cents":   billedAmountCents,
			"billed_amount_yuan":    float64(billedAmountCents) / 100.0,
			"reserved_amount_cents": reservedAmountCents,
			"reserved_amount_yuan":  float64(reservedAmountCents) / 100.0,
			"balance_after_cents":   user.AiBalanceCents,
			"balance_after_yuan":    float64(user.AiBalanceCents) / 100.0,
		},
	})
}

func (h *AiSolveHandler) MarkWrong(c *gin.Context) {
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未登录"})
		return
	}

	var req CacheReviewRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	solveReq := SolveRequest{
		QuestionType: req.QuestionType,
		RawContent:   req.RawContent,
		ContentText:  req.ContentText,
	}
	_, questionHash := buildQuestionHash(solveReq)

	var cached models.CachedQuestion
	if err := h.db.Where("question_hash = ?", questionHash).First(&cached).Error; err != nil {
		if err != gorm.ErrRecordNotFound {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "查询缓存失败"})
			return
		}
		c.JSON(http.StatusOK, gin.H{
			"success":       true,
			"question_hash": questionHash,
			"message":       "当前题目暂无缓存，无需标错",
		})
		return
	}

	if err := h.db.Model(&cached).Updates(map[string]interface{}{
		"is_disabled": true,
		"verified":    false,
		"updated_at":  time.Now(),
	}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "标记错题失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"success":       true,
		"question_hash": questionHash,
		"message":       "已标记为错题，后续将跳过旧缓存",
		"marked_by":     userID.(uint),
	})
}

func (h *AiSolveHandler) ConfirmCache(c *gin.Context) {
	userID, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "未登录"})
		return
	}

	var req CacheReviewRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	req.Answer = strings.TrimSpace(req.Answer)
	if req.Answer == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "答案不能为空"})
		return
	}

	solveReq := SolveRequest{
		QuestionType: req.QuestionType,
		RawContent:   req.RawContent,
		ContentText:  req.ContentText,
	}
	_, questionHash := buildQuestionHash(solveReq)
	rawJSONBytes, _ := json.Marshal(req.RawContent)

	var cached models.CachedQuestion
	err := h.db.Where("question_hash = ?", questionHash).First(&cached).Error
	if err == nil {
		if err := h.db.Model(&cached).Updates(map[string]interface{}{
			"question_type":     req.QuestionType,
			"raw_content":       string(rawJSONBytes),
			"ai_answer":         req.Answer,
			"provider":          "manual_confirmed",
			"model_name":        "user_confirmed",
			"is_disabled":       false,
			"verified":          true,
			"correction_count":  gorm.Expr("correction_count + 1"),
			"last_corrected_by": userID.(uint),
			"updated_at":        time.Now(),
		}).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "更新缓存失败"})
			return
		}
	} else if err == gorm.ErrRecordNotFound {
		newCache := models.CachedQuestion{
			QuestionHash:    questionHash,
			QuestionType:    req.QuestionType,
			RawContent:      string(rawJSONBytes),
			AiAnswer:        req.Answer,
			ModelName:       "user_confirmed",
			Provider:        "manual_confirmed",
			IsDisabled:      false,
			Verified:        true,
			CorrectionCount: 1,
			LastCorrectedBy: userID.(uint),
		}
		if err := h.db.Create(&newCache).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "写入缓存失败"})
			return
		}
	} else {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询缓存失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"success":       true,
		"question_hash": questionHash,
		"answer":        req.Answer,
		"message":       "已确认并写入缓存",
	})
}

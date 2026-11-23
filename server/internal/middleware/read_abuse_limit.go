package middleware

import (
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

const readAbuseLimiterMaxKeys = 10000

type readAbuseLimitEntry struct {
	windowStart time.Time
	count       int
	lastSeen    time.Time
}

// CommunityReadRateLimit 在认证中间件之后执行，只有通过验证的账号才独占额度。
func CommunityReadRateLimit() gin.HandlerFunc {
	return readAbuseRateLimit(240, 600, time.Minute, "/api/posts")
}

// ReadAbuseRateLimitMiddleware 按可信来源和路由族限制公开读取。
func ReadAbuseRateLimitMiddleware(limit int, window time.Duration, prefixes ...string) gin.HandlerFunc {
	return readAbuseRateLimit(limit, 0, window, prefixes...)
}

func readAbuseRateLimit(limit, accountLimit int, window time.Duration, prefixes ...string) gin.HandlerFunc {
	if limit <= 0 {
		limit = 120
	}
	if window <= 0 {
		window = time.Minute
	}
	if len(prefixes) == 0 {
		prefixes = []string{"/api/posts", "/api/search", "/api/topics/search", "/api/topics/recommend"}
	}
	entries := make(map[string]readAbuseLimitEntry)
	var mu sync.Mutex

	return func(c *gin.Context) {
		if c.Request.Method != http.MethodGet && c.Request.Method != http.MethodHead {
			c.Next()
			return
		}
		prefix := readAbuseRoutePrefix(c.Request.URL.Path, prefixes)
		if prefix == "" {
			c.Next()
			return
		}
		clientIP := strings.TrimSpace(c.ClientIP())
		if clientIP == "" {
			clientIP = strings.TrimSpace(c.Request.RemoteAddr)
		}
		key := "ip:" + clientIP + "\n" + prefix
		requestLimit := limit
		if userID := c.GetUint("user_id"); accountLimit > 0 && userID != 0 {
			key = "user:" + strconv.FormatUint(uint64(userID), 10) + "\n" + prefix
			requestLimit = accountLimit
		}
		now := time.Now()

		mu.Lock()
		if _, exists := entries[key]; !exists && len(entries) >= readAbuseLimiterMaxKeys {
			for existingKey, entry := range entries {
				if now.Sub(entry.lastSeen) >= window {
					delete(entries, existingKey)
				}
			}
			if len(entries) >= readAbuseLimiterMaxKeys {
				// 新来源不应因为旧来源占满内存而绕过限流；淘汰最旧的一项，
				// 让内存上限稳定，同时保留最近来源的窗口状态。
				var oldestKey string
				var oldest time.Time
				for existingKey, entry := range entries {
					if oldestKey == "" || entry.lastSeen.Before(oldest) {
						oldestKey, oldest = existingKey, entry.lastSeen
					}
				}
				if oldestKey != "" {
					delete(entries, oldestKey)
				}
			}
		}
		entry := entries[key]
		if entry.windowStart.IsZero() || now.Sub(entry.windowStart) >= window {
			entry = readAbuseLimitEntry{windowStart: now}
		}
		entry.lastSeen = now
		if entry.count >= requestLimit {
			entries[key] = entry
			mu.Unlock()
			c.Header("Retry-After", strconv.Itoa(retryAfterSeconds(window-now.Sub(entry.windowStart))))
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{
				"code":    "read_rate_limited",
				"message": "读取请求过于频繁，请稍后再试",
			})
			return
		}
		entry.count++
		entries[key] = entry
		mu.Unlock()
		c.Next()
	}
}

func readAbuseRoutePrefix(path string, prefixes []string) string {
	for _, prefix := range prefixes {
		prefix = strings.TrimSuffix(strings.TrimSpace(prefix), "/")
		if prefix != "" && (path == prefix || strings.HasPrefix(path, prefix+"/")) {
			return prefix
		}
	}
	return ""
}

func maxDuration(value, minimum time.Duration) time.Duration {
	if value < minimum {
		return minimum
	}
	return value
}

// retryAfterSeconds 必须向上取整，避免客户端在限流窗口尚未结束时提前重试。
func retryAfterSeconds(remaining time.Duration) int {
	remaining = maxDuration(remaining, time.Second)
	seconds := remaining / time.Second
	if remaining%time.Second != 0 {
		seconds++
	}
	if seconds < 1 {
		return 1
	}
	return int(seconds)
}
